# Part B — Model rationale

## 1. Stores: one record, purpose-built copies

**Decision.** PostgreSQL holds the model (the system of record). S3 holds the raw originals. DynamoDB, OpenSearch and Snowflake are copies, each serving one consumer, each rebuildable from Postgres and S3.

**Why.** The product has two kinds of work and they need different engines:

| Workload | From the brief | Shape | Engine |
|---|---|---|---|
| Operational (OLTP) | Site page (U1), alert within 5 min (U2), watch delete stops alerts now (S5), merge/split (U6), "did we already alert this customer?" | Few rows at a time, thousands of times a day, milliseconds, rules that must hold | PostgreSQL on RDS |
| Analytical (OLAP) | OAI rate by country and quarter over 15 years (U4) | Millions of rows, daily, seconds are fine | Snowflake |

Postgres is the operational database of the product, the same role the customer app's own Postgres plays for that app (S5 is literally that database replicated out). Snowflake is the nightly analytical copy. S3 holds the messy originals and is never queried by the product.

| Store | Holds | Because |
|---|---|---|
| S3 | Every file and event as received, immutable | Replay without re-fetching (brief requirement) |
| PostgreSQL | 12 tables: SCD2 facts, versioned bridge, sites, watchlists, alerts, review queue, lineage | Enforced constraints, per-event writes, point-in-time queries, row-level security, millisecond reads |
| DynamoDB | `site_key → [watch_id, customer_id]` | Alert fan-out in milliseconds at 200 events/s, no DB connection in the hot path |
| OpenSearch | One document per letter with tags and facets | Full-text search (U5) |
| Snowflake | Nightly flattened star | Aggregates (U4) |

**Trade-off.** One more database than a Snowflake-only design (§5). Accepted because the brief ranks a wrong merge as the worst outcome, and "the database refuses the write" beats "a test would have caught it". Engines (Flink, Spark) are a separate question from stores; at today's volumes they add a 24/7 cost without changing the design, so processing is SQL, Python on Fargate, and Lambda. They are the upgrade path at 10x.

## 2. History and time

**Decision.** Two kinds of time, never mixed. Agency time (inspection date, issue date) is stored as published. Platform time (`valid_from` / `valid_to`) records when *we* showed each version.

| Table | Versioning | Why |
|---|---|---|
| S1, S2, S3 facts | SCD2 by snapshot diff: INSERT / CORRECT / RETRACT | Sources give no change flags; we infer them. Retractions keep the row, marked `RETRACTED` |
| S4 enforcement actions | Agency `version` number; current = highest | Order-safe without closing rows; a late v1 is stored but never current |
| Bridge, watchlists | SCD2 | "Which site did we *then* think this was" and "what were you watching when" |
| `dim_site` attributes, all serving copies | Overwritten (Type 1) | Display names changing is not history customers care about; copies are rebuilt |

U3 becomes `WHERE valid_from <= :date AND valid_to > :date`. Verified: IN-2041187 returns VAI for 2026-10-08 and OAI for 2026-10-13.

**Trade-off.** Not fully bitemporal: agency time is a plain column, not a second validity range. No consumer in U1–U6 asks a question that needs more.

## 3. Site identity and entity resolution

**Decision.** An agency's own identifier is authoritative within that agency. Everything across agencies is a scored, explainable, reversible decision made by one Python library used by batch and stream alike.

| Step | What happens | The sample case |
|---|---|---|
| Normalise | lowercase, strip punctuation, `pvt→private`, `unit ii→unit 2`, transliterate, ISO country, tokenise address | "Acme Pharma Pvt. Ltd." and "ACME PHARMACEUTICALS PRIVATE LIMITED - UNIT II" become comparable |
| Block | same country **and** (postcode **or** address token **or** city) | FDA says Hyderabad, EU says Sangareddy; the shared token `pashamylaram` / `plot 14` brings them together. City alone would miss it |
| Score | address-token overlap + core-name similarity + postcode; **unit designator mismatch caps the score at 0.6** | Keeps Unit I (Visakhapatnam) and Unit II (Hyderabad) apart despite near-identical names |
| Decide | same agency ID → link · ≥ 0.95 → auto-link · 0.75–0.95 → review queue · < 0.75 → new site | The warning letter (no FEI, address matches the EU record) scores 0.91 → a steward confirms it |

Every bridge row records method, score, evidence and the rules version, so a steward can see *why*, and a new rules version can run in shadow and be compared before promotion. A customer confirming a pending watch match is recorded as a steward decision for that watch.

**When a match is wrong.** A steward SPLITs: close the wrong bridge rows, open correct ones, all stamped with one `decision_group_id`. Facts: untouched. History: intact (point-in-time queries still show what we showed). Copies: re-published for both sites. Alerts: already-sent rows stay as history; affected customers get a correction notice and the newly separated site's watchers get a catch-up alert, both as new idempotent `fact_alert` rows.

**Trade-off.** More items reach humans than an aggressive matcher would send. That is the point: the brief says a wrong merge is worse than a delay.

## 4. Normalisation vs denormalisation

**Rule.** Normalise where **decisions** live; denormalise where **evidence** lives.

| Normalised | Why |
|---|---|
| `dim_site` ← bridge ← facts (the one snowflake) | Identity changes; a small SCD2 table makes merges cheap and historical |
| `dim_customer`, `fact_letter_tag` | Standard 1:N; tags keep every model version |

| Denormalised | Why |
|---|---|
| Facts keep the agency's firm name and address verbatim (no `dim_firm`) | The text *is* the evidence; a firm dimension is a second entity-resolution problem no consumer asked for |
| `dim_site` carries a copy of name/address | Fast profile header and matching candidates; recomputed on reprocess |
| `fact_alert` carries `customer_id` and `site_key` | Row-level security needs the tenant on the row; the site must be the one *at alert time*, which a later split must not rewrite |

Who pays for the snowflake: U1 (one extra join, hidden behind a view). Who never sees it: U2, U4, U5, whose copies are flattened at publish time. Who it exists for: U6.

## 5. Alternative considered and rejected

**Snowflake as the sole system of record**: S3 → Snowpipe → staging → dbt snapshots for SCD2 → marts, with DynamoDB for watchers and alerts. All on the stated stack, one database fewer. Rejected because (1) the one-identifier-one-site rule and the primary keys are declared but not enforced in a warehouse, so a bad matching run corrupts the bridge silently; (2) the customer app reads the model for U1, and a warehouse serving sub-second reads must stay running; (3) S4/S5 are thousands of small per-event writes, which a columnar engine handles poorly. I would revisit it if the app stopped reading the model directly and the stream path wrote only to DynamoDB; the DDL is the same, constraints become tests.
