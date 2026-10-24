# Part C — Pipeline architecture

## Diagram

Read left to right: **originals → three processing lanes → system of record → serving copies → consumers.** Orange is the 5-minute alert path; green is the system of record.

## Components and triggers

| Stage | Component | Trigger | Why this choice |
|---|---|---|---|
| Raw landing | Amazon S3, versioned, one object per arrival, lifecycle to Glacier after a year | Batch files land directly; stream events via Kinesis Firehose | Immutable originals for replay, same answer for batch and stream |
| Batch fetch (S1, S2) | Step Functions state machine per source running Fargate Python tasks | EventBridge Scheduler: Monday 06:00 (S1), 1st of month (S2) | Pay-per-run; no 24/7 Airflow to host for a 4-person team |
| Parse + normalise | Fargate task → parquet in `s3://staged/` → `COPY` into a Postgres staging schema | Next step in the state machine | Parsing is where the quirks live (dates, country codes, duplicates); isolating it makes it replayable on its own |
| Snapshot diff | SQL in Postgres, one transaction per batch | Next step | A set comparison of staging vs current is a few hundred lines of testable SQL |
| Entity resolution | Python library (`supplierwatch.er`); candidate search via Postgres `pg_trgm` | Called by batch tasks and by the stream Lambdas | One code path, one set of thresholds, one evidence format |
| Letters (S3) | S3 `ObjectCreated` → SQS → Lambda "letter"; Lambda "nlp" on its own queue with reserved concurrency 5, retry with backoff, DLQ after 5 attempts | Event-driven | Letter searchable in minutes; the slow, rate-limited, flaky NLP API is fully decoupled |
| Enforcement stream (S4) | Kinesis Data Stream (partition key `action_id`) → Lambda "s4-apply" (batch 100, bisect on error) | Stream | One action's events stay in order on one shard; Lambda scales with bursts and costs nothing idle |
| Watchlist CDC (S5) | Debezium (app team) → MSK → Lambda "s5-apply" | Stream | Deletes must stop alerts immediately, so S5 cannot be batch |
| Hot lookup | DynamoDB `site_watchers` (PK `site_key`, SK `watch_id`, attr `customer_id`) | Written by the publish Lambda from a Postgres outbox, and directly by "s5-apply" | Millisecond fan-out without a Postgres connection in the hot path |
| Alerting | SQS → Lambda "notify" → `fact_alert` (`ON CONFLICT DO NOTHING`) → email / webhook | Queue | Idempotent at the database; retries are safe |
| Search | Amazon OpenSearch, smallest production domain | Updated by "letter", "nlp" and the publish Lambda | The only 24/7 component besides Postgres; justified by U5 |
| Analytics | Nightly Fargate task: Postgres → parquet → Snowflake `COPY`; marts rebuilt | EventBridge 02:00 | Daily is the stated freshness; a full rebuild is simplest |
| Stewardship | Small internal app (or admin SQL to start) over the review queue and the bridge | On demand | Every write stamps `decision_group_id`, `decided_by`, `decision_reason` |
| Monitoring | CloudWatch alarms on every queue, DLQ and Lambda error rate; batch DQ results stored on `ingest_batch` | Always | See Part D §5 |

## Walkthroughs

### a. The S1 weekly snapshot (corrections and retractions)

1. Monday 06:00: the S1 state machine downloads the CSV to `s3://raw/s1/received_date=2026-10-12/`. An `ingest_batch` row is created (`RECEIVED`).
2. Parse: dates normalised per the S1 rule (original kept), country names → ISO-2, in-file duplicates dropped. Rows `COPY`'d into staging. Data-quality checks run (row count vs last week, parse failures, null FEI rate, duplicate keys, retraction rate). Any failure → `QUARANTINED`, nothing loaded, on-call paged, last week's data stays live.
3. Diff, one transaction:
   - in staging, not in current → **INSERT** version (`valid_from = received_at`)
   - in both, business columns differ → close current, **CORRECT** version. IN-2041187 goes VAI → OAI here
   - in current, missing from staging → close current, **RETRACTED** version. IN-2040551 goes here
4. ER: each FEI not yet in the bridge gets a new site and an `EXACT_ID` row. Known FEIs are untouched.
5. Outbox rows for changed sites → publish Lambda refreshes OpenSearch, DynamoDB, marts. Batch `LOADED`.

### b. The four S4 events, in arrival order

| # | Event | What "s4-apply" does |
|---|---|---|
| 1 | `e-88f1` v1 UPSERT (schema v1) | v1 parser maps `firm` → `firm_name`. Insert `(IA-66-40-0098, 1)`. Current = v1. FEI 3004521877 → DynamoDB → watch 9912 (cust_042) → alert enqueued |
| 2 | `e-91c3` v2 UPSERT (schema v2) | v2 parser. Insert `(IA-66-40-0098, 2)`. Current = v2, differs from v1 → "changed action" alert to the same watchers |
| 3 | `e-88f1` again | Insert hits PK `(IA-66-40-0098, 1)` → no-op. No alert; even if enqueued, `fact_alert`'s unique key would drop it |
| 4 | `e-93aa` v3 RETRACT for `RC-2026-1187` | Insert `(RC-2026-1187, 3, RETRACT)`. Never seen v1/v2: the row is a tombstone, so a late v1 is stored but never current. No FEI → no site → no alert; a review item is opened |

Any other arrival order gives the same end state: current is always the highest version and the PK rejects repeats.

### c. A new S3 warning letter

1. `WL-320-26-118.json` + text land in S3. `ObjectCreated` → SQS → Lambda "letter".
2. Metadata → `fact_warning_letter` (`nlp_status = PENDING`, `fei_number` null); body → `s3://raw/s3/…/WL-320-26-118.txt`.
3. ER on recipient name + address: tokens `plot 14`, `pashamylaram` block against S-001; address similarity 0.93, name 0.85, no unit mismatch → 0.91 → **review band**. Review item opened. The letter is indexed in OpenSearch immediately with `site_key = null`, so it is already findable by text (U5 met).
4. Message to the NLP queue. Lambda "nlp" (≤ 5 concurrent → ≤ 5 rps) calls the API; on the 2% failure, backoff and retry up to 5 times, then DLQ + metric. On success: `fact_letter_tag` rows, `nlp_status = DONE`, OpenSearch document patched with tags.
5. A steward confirms S-001 (the EU record has the same plot). Bridge row `LETTER_ID → S-001` (`STEWARD`, `decision_group_id`). Outbox → publish: the document gets `site_key`; the profile page shows the letter.

### d. An S5 watchlist delete

1. The customer removes SUP-0071. Debezium emits `{"op":"d", "before": {"watch_id": 9912, "customer_id": "cust_042", …}, "ts_ms": …}`.
2. Lambda "s5-apply": if `ts_ms` is older than the applied `cdc_timestamp`, ignore. Otherwise close the current version and open one with `is_active = false`.
3. **Same invocation:** `DeleteItem` on DynamoDB `site_watchers (S-001, 9912)`. From this moment any S4 event for S-001 finds no watcher for cust_042. This is the "immediately" in the brief: it does not wait for the outbox.
4. The bridge row `WATCH_ID 9912 → S-001` is closed (`valid_to = now`) so history shows when the customer stopped watching. Public data is untouched.
