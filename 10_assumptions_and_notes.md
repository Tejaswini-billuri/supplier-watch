# Assumptions, AI usage, time spent

## Assumptions

Where the brief was silent or ambiguous, I assumed the following.

1. **S1 dates** parse as ISO first, otherwise `MM/DD/YYYY`; `08/02/2026` is 2 August 2026. The original string is kept so the rule can change without re-fetching.
2. **S1/S2 snapshots are complete**: a row missing from the new snapshot is a retraction. A retraction rate above 2% is treated as a bad file and quarantined instead.
3. **S2 `WITHDRAWN`** is a correction (new version), not a retraction: the document still exists. In-file duplicates are identical copies and are dropped before diffing.
4. **S4 `version`** is monotonically increasing per `action_id` and is the authoritative order. A RETRACT for an action never seen is stored as a tombstone and queued for review, not alerted (it carries no FEI). An unknown `schema_version` goes to a dead-letter queue rather than being parsed on a best-effort basis.
5. **S5 CDC** is produced by the customer-app team (Debezium on their PostgreSQL); we consume a topic and never connect to their database.
6. **Within one agency the agency's ID is authoritative**: same FEI = same site. Cross-agency matching auto-links at ≥ 0.95, sends 0.75–0.95 to a human, creates a new site below 0.75. Thresholds are a starting point to be tuned on steward decisions. At least one part-time steward is available.
7. **"New or changed" enforcement action includes a RETRACT**: customers told about an action are told when it is withdrawn.
8. **The customer app reads site profiles from the model** via an API, which is why the model needs an OLTP store (Part B §5 states when that would change).
9. **15-year historical snapshots can be obtained** for S1 and S2. If only current state is available, history starts at go-live, flagged as such.
10. **Infrastructure is AWS**, one region, our account separate from the customer app's.

## How AI tools were used

I used Claude Code (Anthropic) as a design partner throughout, in one working session.

- **Mine:** reading the brief; the core modelling idea (facts keep agency identifiers, a versioned bridge maps them to our sites, merges change the bridge and never the facts); choosing PostgreSQL as the operational system of record over Snowflake after weighing both; deciding where to go deep (identity, history, S4 handling) and where to stay shallow; removing tables I could not justify (a separate decision log, a raw-event table, a source dimension); pushing until every table could be explained in plain language.
- **Claude's:** turning those decisions into DDL, diagrams and written sections; drafting Parts B, C and D for me to edit; generating the sample-data SQL from the brief; running the DDL, sample data and the U2/U3/U4 queries on a local PostgreSQL 17 and capturing the output; catching my misunderstandings (source vs store, engine vs store) and correcting its own (an overstated claim about Snowflake transactions, fixed in Part B).
Every design choice in this document is one I can explain and defend without the tool.

## Time spent

About **3.5 to 4 hours**: reading the brief about 30 minutes, data model and DDL 1 to 1.5 hours (including the queries and running them on PostgreSQL), pipeline architecture and rationale about 1.5 hours, assembling the document the remainder.
