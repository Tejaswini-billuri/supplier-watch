# Part A.1 — Data model

## The idea in three sentences

1. **Facts are what agencies told us.** One `fact_` table per source. Rows are never overwritten:
   every correction is a new SCD2 version, every retraction is a row marked `RETRACTED`.
2. **A site is our opinion.** `dim_site` is just a label for "one physical plant". The agencies
   don't know our site IDs, so facts carry the *agency's* identifier (FEI, site_ref, ...).
3. **The bridge connects them.** `dim_site_identifier` maps each agency identifier to our site,
   as SCD2. Merging or splitting sites only changes bridge rows, never facts, and the old
   mapping is kept as history.

Everything a customer sees is a join: `fact → dim_site_identifier → dim_site`.

## Star or snowflake?

- **Core model (Postgres, system of record):** a star with one deliberate snowflake. Facts
  don't carry `site_key`; they carry the agency identifier, and the bridge resolves it.
  Reason: identity decisions change (merges, splits, better matching rules). Updating a few
  hundred bridge rows is cheap and keeps history; rewriting millions of fact rows is neither.
- **Analytics marts (Snowflake warehouse, U4):** a pure star. The nightly load flattens
  through the bridge and puts `site_key`, `country_code`, `quarter` directly on the fact.

## SCD2 convention used everywhere

| Column | Meaning |
|---|---|
| `valid_from` | When **our platform** started showing this version. Not the agency's date. |
| `valid_to` | When this version was replaced. `9999-12-31` while current. |
| `is_current` | `true` on the newest version. Same information as `valid_to`, kept for easy filtering. |

"What did we show on 2026-10-08?" = `WHERE valid_from <= '2026-10-08' AND valid_to > '2026-10-08'`.

## The 12 tables, one line each

| Table | Grain | Keyed by | History |
|---|---|---|---|
| `fact_inspection` | one FDA inspection result (S1) | `inspection_id` | SCD2 by snapshot diff |
| `fact_gmp_document` | one EU certificate or non-compliance report (S2) | `doc_ref` | SCD2 by snapshot diff |
| `fact_warning_letter` | one FDA warning letter (S3); text stays in S3 | `letter_id` | SCD2 |
| `fact_letter_tag` | one NLP tag on one letter, per model version | `letter_id, model, tag` | append-only |
| `fact_enforcement_action` | one version of one import alert / recall / debarment (S4) | `action_id, version` | current = highest version |
| `dim_site` | one physical plant, our own `site_key` | `site_key` | Type 1 |
| `dim_site_identifier` | **the bridge**: one agency identifier → one site, from/to | `type, value, valid_from` | SCD2 |
| `dim_customer` | one paying customer | `customer_id` | Type 1 |
| `dim_watchlist_entry` | one supplier a customer watches (S5) | `watch_id` | SCD2; `is_active` false on delete |
| `fact_alert` | one notification to one customer about one action version | unique `(watch, action, version)` | append-only |
| `match_review_queue` | one identifier a human must place | `review_id` | status changes |
| `ingest_batch` | one file received, with its S3 path and DQ results | `batch_id` | append-only |

Full column-by-column dictionary: appendix A. DDL for the five core tables: A.2 below; full DDL (35 statements, executed on PostgreSQL 17): appendix B.

## How each consumer is served (A.3 and U1–U6)

| Consumer | Path through the model |
|---|---|
| **U1** Site profile | `dim_site` → `dim_site_identifier` (current) → each fact table (current). Each row shows its agency ID and `batch_id`, so it is traceable to the file. |
| **U2** Alerts | new `fact_enforcement_action` version → `fei_number` → bridge → `site_key` → bridge rows of type `WATCH_ID` → `dim_watchlist_entry` (active) → distinct customers. Insert into `fact_alert`; the unique key blocks duplicates. |
| **U3** Audit | `fact_inspection WHERE valid_from <= :date AND valid_to > :date`. Same filter on the bridge gives "which site we *then* thought it belonged to". |
| **U4** Analytics | `fact_inspection` (current) → bridge → `site_key`; LEFT JOIN sites on cust_042's watchlist; GROUP BY country, quarter, on_watchlist. Flattened into a star in the warehouse nightly. |
| **U5** Search | `fact_warning_letter` + body from S3 + `fact_letter_tag` + site and country via bridge → one Elasticsearch document per letter. ES is a copy; rebuildable from here. |
| **U6** Stewardship | `match_review_queue` → human decision → close/insert bridge rows (all stamped with one `decision_group_id`, `decided_by`, `decision_reason`) → `dim_site.is_active`. Facts untouched; the alert lookup is rebuilt from the bridge so alerts follow. |

### A.3 a–d in one place

- **a. Canonical site and S1–S4 links.** `S-001` has bridge rows `FEI 3004521877`, `EU_SITE_REF LOC-118842`,
  `LETTER_ID WL-320-26-118`, `WATCH_ID 9912`. The two FDA inspections and the import alert reach it via the
  FEI; the EU report via the site_ref; the letter via its own letter_id. `FEI 3009876543` (Unit I, Visakhapatnam)
  is a separate `S-002`.
- **b. Corrected and retracted.** See the IN-2041187 and IN-2040551 tables above.
- **c. Merge with history.** Merge S-002 into S-001 = close S-002's bridge rows (`valid_to = now`), insert the same
  identifiers pointing at S-001, all stamped with one `decision_group_id` and the steward's ID and reason; set
  `S-002.is_active = false`. No fact row changes. "As of" queries before the merge still see S-002. A split finds
  every row carrying that `decision_group_id` and reverses it.
- **d. Tenant-private watchlists.** `customer_id` is on `dim_watchlist_entry` and `fact_alert` only, enforced
  by row-level security. Public tables carry no `customer_id`. A watch reaches a site through its own
  `WATCH_ID` bridge row; nothing public points back at a customer.
