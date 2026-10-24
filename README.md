# Supplier Watch — Senior Data Engineer take-home

Data model and pipeline for a supplier-risk product built on multi-agency regulatory data.

**The submission** (decision log, Parts A–D, assumptions; ~20 pages): [SUBMISSION.pdf](SUBMISSION.pdf), also as [SUBMISSION.docx](SUBMISSION.docx) and [SUBMISSION.md](SUBMISSION.md).
**The appendix** (full data dictionary, full DDL, sample data, query output): [APPENDIX.pdf](APPENDIX.pdf) / [APPENDIX.md](APPENDIX.md).
Both are generated from the part files below by `./build.sh`.

## Contents

| Part | File | What it is |
|---|---|---|
| Decision log | [00_decision_log.md](00_decision_log.md) | Twelve decisions on one page: what, why, rejected alternative |
| A.1 Entity diagram | [01_entity_model.md](01_entity_model.md), [diagrams/entity_model.png](diagrams/entity_model.png) | 12-table model, SCD2 convention, A.3 representations, U1–U6 paths |
| A.1 Data dictionary | [A1_data_dictionary.md](A1_data_dictionary.md) | Column-by-column reference (appendix A) |
| A.2 DDL | [02_ddl_core.sql](02_ddl_core.sql) (five core tables), [02_ddl.sql](02_ddl.sql) (full, 35 statements) | PostgreSQL 15+ schema: keys, constraints, indexes, views, RLS. Executed on PostgreSQL 17 |
| A.4 Queries | [04_queries.sql](04_queries.sql) | U2, U3, U4 with expected results |
| Verification | [05_sample_data.sql](05_sample_data.sql), [06_query_results.txt](06_query_results.txt) | The brief's sample records loaded; actual query output |
| B Model rationale | [07_part_b_model_rationale.md](07_part_b_model_rationale.md) | Stores (OLTP vs OLAP), time, entity resolution, normalisation, rejected alternative |
| C Pipeline architecture | [08_part_c_pipeline_architecture.md](08_part_c_pipeline_architecture.md), [diagrams/pipeline.png](diagrams/pipeline.png) | Diagram, components and triggers, four walkthroughs |
| D Pipeline rationale | [09_part_d_pipeline_rationale.md](09_part_d_pipeline_rationale.md) | Batch/stream split, correctness, reprocessing, DQ, monitoring, 10x, six-week plan |
| Assumptions, AI use, time | [10_assumptions_and_notes.md](10_assumptions_and_notes.md) | |

Diagram sources are Mermaid (`diagrams/*.mmd`), rendered with mermaid-cli.

## The design in four sentences

1. Facts are stored per agency, keyed by the agency's own identifier, as SCD Type 2 versions; corrections and retractions are new versions, never overwrites.
2. A site is our opinion about which identifiers are one physical plant; that opinion lives in a versioned bridge table, so merges and splits change the bridge and never the facts.
3. PostgreSQL is the operational system of record (pages, alerts, merges, event writes); Snowflake, DynamoDB and OpenSearch are purpose-built copies rebuilt from it; S3 holds the untouched originals for replay.
4. Only alerts need minutes, so only S4 and S5 are streamed, through small Lambda consumers that share one entity-resolution library with the batch path.

## Reproducing the verification

```bash
createdb supplier_watch
psql -d supplier_watch -f 02_ddl.sql
psql -d supplier_watch -f 05_sample_data.sql
psql -d supplier_watch -f 04_queries.sql
```
