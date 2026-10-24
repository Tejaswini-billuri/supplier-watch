# Part D — Pipeline rationale

## 1. Batch and streaming: split by source, unified by store

**Decision.** S1, S2, S3 are batch. S4, S5 are streamed. Both paths write the same Postgres tables through the same entity-resolution library.

**Why.** Only U2 needs minutes. The streaming consumer therefore does four things and no more: dedupe, apply a version, look up watchers, enqueue an alert. It never parses CSVs or diffs snapshots. A consumer that small can be read in one sitting at 3 a.m.

**What this is not.** Not Kappa: snapshots are sets, not events; detecting a vanished row means comparing two complete files, and forcing a CSV through a stream adds machinery and removes nothing. Not Lambda architecture: the two paths handle *different* sources and never compute the same result twice, so there is no reconciliation and no duplicated logic. What it is: a layered store (raw S3 → cleaned Postgres → purpose-built copies), a hub-and-link identity model (Data Vault style), Kimball stars in the marts, idempotent consumers, and a transactional outbox for publishing copies.

## 2. Correctness under duplicates, disorder, late data, schema change

| Hazard | Mechanism | Where |
|---|---|---|
| Duplicate S4 event | `INSERT … ON CONFLICT DO NOTHING` on PK `(action_id, version)`; same on `fact_alert (watch, action, version)` | Database, not consumer memory, so retries are safe |
| Out-of-order versions | Current = highest `version`; a late v1 is stored, never served. Kinesis partitioned by `action_id` | Model + stream config |
| RETRACT for an unseen action | Stored as a tombstone; a later lower version cannot become current. No FEI → no alert, review item opened | `s4-apply` |
| Late S1 correction (2024 row fixed in 2026) | Diff is set-based; it appears as a CORRECT with `valid_from = 2026`. U3 for 2025 still returns the old value | Snapshot diff |
| Duplicates inside one S2 file | De-duplicated on `(doc_ref, content hash)` before the diff | Parse step |
| Out-of-order S5 CDC | `ts_ms` guard: older events ignored | `s5-apply` |
| S4 schema v1 → v2 | Parser keyed on `schema_version`; unknown version → DLQ + alarm, never best-effort | `s4-apply` |
| Ambiguous dates | Per-source rule; raw string kept, so a rule change is a re-parse, not a re-fetch | Parse step |

## 3. Reprocessing and backfill

**15-year history.** Load the historical snapshots oldest → newest through the same diff pipeline, with `valid_from` set to each snapshot's original date. This reconstructs the version history as if we had always been running, which is the only way U3 can answer questions about dates before go-live. Source order: S1 first (FEI is the most reliable identifier, so sites are born from it), then S2, then S3. Same code as the weekly job, bigger Fargate tasks.

**Entity-resolution rule change.** Never rewrite the bridge in place. Run the new rules into a shadow table with its own `matching_rules_version`; diff against current (which identifiers move, which sites merge or split); review the diff (every change below a size threshold, sampled above it); promote in one transaction under one `decision_group_id`. Old rows stay as history; if the new rules are worse, a split by that group ID reverses them. Facts are never touched.

**Parser change.** Re-run parse + diff from S3 into staging, compare, promote the same way. `ingest_batch.parser_version` tells the reprocess apart from the original load.

## 4. Data quality

| Layer | Checks | On failure |
|---|---|---|
| Raw | File present, non-empty, parseable, expected columns | Batch `FAILED`; page on-call; nothing downstream runs |
| Parse | Date-parse failures < 0.5%; country mapping failures = 0; duplicate keys; null-FEI rate vs baseline | `QUARANTINED`; last good load stays live; rejects written to a side table |
| Diff | Row count ±20% of last snapshot; **retraction rate < 2%**; classification mix vs baseline | `QUARANTINED`. A 30% retraction rate is a truncated file, not 75k real retractions. The single most important check |
| ER | New-site rate, auto-link rate, review-queue growth vs rolling baseline | Warn; large shifts usually mean a normalisation bug |
| Stream | Unknown schema; event with neither FEI nor known action; Lambda error rate | DLQ + alarm; the stream keeps flowing |
| Serving | Hourly: DynamoDB watcher count = active watch bridge rows | Rebuild from Postgres; alarm on repeat |

**Rule.** A batch loads completely or not at all. "Not at all" leaves last week's data live, which is always better than half a snapshot.

## 5. Monitoring: the first five signals

1. **Alert latency** p95 (`delivered_at − event_time`) against the 5-minute SLO.
2. **Undelivered alerts** older than 5 minutes. Catches a dead notifier when everything upstream is green.
3. **Snapshot diff profile** per S1/S2 run (inserts, corrections, retractions, row count) against an 8-week baseline. **This is how you know the S1 job "succeeded" but loaded bad data**: zero corrections for three weeks, or 12k retractions in one, is wrong even when every step exits 0. Plotted, so a human sees the shape.
4. **Stream health**: Kinesis iterator age (falling behind?) and DLQ depth (dropping silently?).
5. **Review-queue size and age**: growth faster than stewards clear it means thresholds or normalisation have drifted, and facts are sitting on no profile page.

Plus a nightly reconciliation: current facts per site in Postgres vs documents per site in OpenSearch and Snowflake.

## 6. What breaks first at 10x

| Pressure | Breaks | Change |
|---|---|---|
| 25 agencies, each a different format | One hand-written parser per source | Parser plugin interface (`fetch / parse / natural_key / dates`) and a `dim_agency` table with parser config. **First thing I would change**, before any infrastructure |
| 1M sites | Trigram candidate search over all of `dim_site` | Candidate generation in OpenSearch (already running); batch ER on Spark with Splink for backfills |
| 2k events/s bursts | Per-event Postgres writes from Lambda | Micro-batching (already 100/invocation), RDS Proxy; then Flink doing dedupe and version compare before Postgres |
| 400 customers, 250k watches | Fan-out per event | DynamoDB handles it; batch notifications per customer per minute |
| Nightly full export | Gets long | Incremental export on `valid_from > last run` |

## 7. Six weeks with this team

| Weeks | Build | Reason |
|---|---|---|
| 1–2 | Raw landing for all five sources; Postgres model; S1 parse + diff + SCD2; FEI-based sites | Landing is append-only and cheap, and history starts accumulating from day one |
| 3–4 | S4 stream apply, DynamoDB watchers, alerts end to end; S5 apply with immediate delete; basic U1 profile | Alerts are what customers pay for |
| 5–6 | ER library with the three bands and a bare review table; S3 letters into Postgres and OpenSearch; quarantine + the five monitors | Quality tooling improves a product that already exists |

**Deliberately deferred:** S2 (monthly; week 7 loses nothing), NLP tagging (search works without it), Snowflake marts (U4 can be served from Postgres for 40 customers), a steward UI (a table and two SQL functions suffice for one steward), geocoding, the 15-year backfill (needs a stable pipeline; raw landing from day one means we lose nothing by waiting).
