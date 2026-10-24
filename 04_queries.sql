-- Part A.4 — Queries for U2, U3, U4 (PostgreSQL)
-- Each query is followed by the expected result against the sample data in the brief.

-- ============================================================================
-- U2  "Which customers must be alerted about IA-66-40-0098?"
-- ============================================================================
-- Path: current version of the action → its FEI → bridge → our site → bridge rows of type
-- WATCH_ID on that site → active watchlist entries → distinct customers.
-- "New or changed" includes a RETRACT: a customer who was told about a recall must also be told
-- it was withdrawn.

WITH action AS (
    SELECT action_id, action_version, operation, fei_number
    FROM   v_enforcement_action_current
    WHERE  action_id = 'IA-66-40-0098'
),
site AS (                                             -- which of OUR factories is this?
    SELECT a.action_id, a.action_version, a.operation, b.site_key
    FROM   action a
    JOIN   dim_site_identifier b
           ON  b.identifier_type  = 'FEI'
           AND b.identifier_value = a.fei_number
           AND b.is_current
),
watchers AS (                                         -- who is watching that factory right now?
    SELECT s.action_id, s.action_version, s.site_key, w.watch_id, w.customer_id
    FROM   site s
    JOIN   dim_site_identifier bw
           ON  bw.site_key        = s.site_key
           AND bw.identifier_type = 'WATCH_ID'
           AND bw.is_current
    JOIN   dim_watchlist_entry w
           ON  w.watch_id   = bw.identifier_value::bigint
           AND w.is_current
           AND w.is_active                            -- a CDC delete flips this, stopping alerts
)
SELECT DISTINCT customer_id
FROM   watchers;

-- Expected (sample data): cust_042  (via watch 9912 → S-001 ← FEI 3004521877)

-- The same CTEs drive the alert fan-out. ON CONFLICT makes a duplicate event a no-op (U2 idempotency):
--
-- INSERT INTO fact_alert (alert_id, customer_id, watch_id, site_key, action_id, action_version)
-- SELECT gen_random_uuid(), customer_id, watch_id, site_key, action_id, action_version
-- FROM   watchers
-- ON CONFLICT (watch_id, action_id, action_version) DO NOTHING;


-- ============================================================================
-- U3  "What was the classification of IN-2041187 as we showed it on 2026-10-08?"
-- ============================================================================
-- Pick the version whose validity window contains the end of that day.
-- Returns no row if we had not shown the inspection yet on that date (correct: we knew nothing).

SELECT inspection_id,
       classification,
       record_status,
       valid_from,
       valid_to,
       batch_id                                       -- → ingest_batch.s3_path: the exact file we showed
FROM   fact_inspection
WHERE  inspection_id = 'IN-2041187'
  AND  valid_from <= '2026-10-08 23:59:59+00'
  AND  valid_to   >  '2026-10-08 23:59:59+00';

-- Expected: classification = 'VAI'  (the 10-05 snapshot version; the OAI correction only became
--           valid on 10-12). Running the same query for 2026-10-13 returns 'OAI'.

-- Companion: which factory did we say it belonged to on that day? Same filter on the bridge.
SELECT b.site_key, s.site_name, b.match_method
FROM   fact_inspection i
JOIN   dim_site_identifier b
       ON  b.identifier_type  = 'FEI'
       AND b.identifier_value = i.fei_number
       AND b.valid_from <= '2026-10-08 23:59:59+00'
       AND b.valid_to   >  '2026-10-08 23:59:59+00'
JOIN   dim_site s ON s.site_key = b.site_key
WHERE  i.inspection_id = 'IN-2041187'
  AND  i.valid_from <= '2026-10-08 23:59:59+00'
  AND  i.valid_to   >  '2026-10-08 23:59:59+00';


-- ============================================================================
-- U4  "OAI rate by country and quarter for the last 3 years,
--      for sites on cust_042's watchlist versus all sites."
-- ============================================================================
-- Analytics uses the CURRENT version of each inspection (what we believe today), not as-of.
-- Retracted inspections are excluded by the view.

WITH insp AS (
    SELECT i.inspection_id,
           i.country_code,
           date_trunc('quarter', i.inspection_end_date)::date AS quarter,
           (i.classification = 'OAI')::int                     AS is_oai,
           b.site_key
    FROM   v_inspection_current i
    JOIN   dim_site_identifier b
           ON  b.identifier_type  = 'FEI'
           AND b.identifier_value = i.fei_number
           AND b.is_current
    WHERE  i.inspection_end_date >= date_trunc('quarter', current_date) - interval '3 years'
),
watched_sites AS (                                    -- factories on cust_042's list today
    SELECT DISTINCT bw.site_key
    FROM   dim_watchlist_entry w
    JOIN   dim_site_identifier bw
           ON  bw.identifier_type  = 'WATCH_ID'
           AND bw.identifier_value = w.watch_id::text
           AND bw.is_current
    WHERE  w.customer_id = 'cust_042'
      AND  w.is_current
      AND  w.is_active
)
SELECT i.country_code,
       i.quarter,
       count(*)                                                        AS inspections_all,
       round(100.0 * avg(i.is_oai), 1)                                 AS oai_rate_all_pct,
       count(*)        FILTER (WHERE ws.site_key IS NOT NULL)          AS inspections_watchlist,
       round(100.0 * avg(i.is_oai) FILTER (WHERE ws.site_key IS NOT NULL), 1)
                                                                       AS oai_rate_watchlist_pct
FROM   insp i
LEFT JOIN watched_sites ws ON ws.site_key = i.site_key
GROUP  BY i.country_code, i.quarter
ORDER  BY i.country_code, i.quarter;

-- Expected shape (sample data, current state after the 10-12 snapshot):
--   country  quarter     inspections_all  oai_rate_all  inspections_watchlist  oai_rate_watchlist
--   IN       2026-07-01  2                50.0          2                      50.0
--   (IN-2041187 = OAI after correction, IN-2039902 = NAI; both on S-001 which cust_042 watches;
--    IN-2040551 is retracted and excluded)
--
-- In production this query runs against the nightly Snowflake star, where site_key, country and
-- quarter are already flattened onto the fact row and the bridge join disappears.
