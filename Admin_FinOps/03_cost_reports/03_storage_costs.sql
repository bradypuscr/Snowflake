/*
================================================================================
  FILE: 03_cost_reports/03_storage_costs.sql
  PURPOSE: Storage cost analysis across databases, schemas, and tables.
           Covers active data, time travel, failsafe, and stage storage.
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
  KEY VIEWS: SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
             SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
             SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
             SNOWFLAKE.ACCOUNT_USAGE.STAGE_STORAGE_USAGE_HISTORY
  ACCURACY: Exact (daily snapshots)
  LATENCY:  Up to 3 hours for most views; TABLE_STORAGE_METRICS refreshes daily.
================================================================================

  STORAGE BILLING COMPONENTS:
  ────────────────────────────
  ACTIVE_BYTES        — Current live data in tables. Billed at standard TB/month rate.
  TIME_TRAVEL_BYTES   — Copies maintained for time travel window (0–90 days).
                        Billed at the same rate as active data.
  FAILSAFE_BYTES      — 7-day disaster recovery window Snowflake maintains automatically.
                        Billed at approximately 1/4 the rate of active data.
                        Cannot be disabled. Accumulates heavily on tables with
                        frequent DELETE/UPDATE operations.
  RETAINED_FOR_CLONE_BYTES — Data retained for clones sharing the same storage.

  DOLLAR ESTIMATION:
  ─────────────────
  Snowflake storage pricing varies by region and contract.
  Common on-demand rate: ~$23 per TB per month (check your contract).
  ⚠️ Replace the rate placeholder in dollar estimate queries with your actual rate.
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 1: Account-level storage trend — last 90 days
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    USAGE_DATE,
    ROUND(STORAGE_BYTES  / POWER(1024, 4), 4)  AS tables_tb,
    ROUND(STAGE_BYTES    / POWER(1024, 4), 4)  AS stages_tb,
    ROUND(FAILSAFE_BYTES / POWER(1024, 4), 4)  AS failsafe_tb,
    ROUND((STORAGE_BYTES + STAGE_BYTES + FAILSAFE_BYTES) / POWER(1024, 4), 4) AS total_tb,
    -- Day-over-day growth in GB
    ROUND((STORAGE_BYTES - LAG(STORAGE_BYTES) OVER (ORDER BY USAGE_DATE))
        / POWER(1024, 3), 2)                   AS table_storage_day_over_day_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
WHERE USAGE_DATE >= DATEADD('day', -90, CURRENT_DATE)
ORDER BY USAGE_DATE DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 2: Storage by database — most recent snapshot
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    DATABASE_NAME,
    ROUND(AVERAGE_DATABASE_BYTES / POWER(1024, 3), 2) AS avg_active_gb,
    ROUND(AVERAGE_FAILSAFE_BYTES / POWER(1024, 3), 2) AS avg_failsafe_gb,
    ROUND((AVERAGE_DATABASE_BYTES + AVERAGE_FAILSAFE_BYTES) / POWER(1024, 3), 2) AS total_billed_gb,
    -- Estimated monthly cost (replace 0.023 with your per-GB rate if known,
    -- or use per-TB rate divided by 1024)
    ROUND((AVERAGE_DATABASE_BYTES + AVERAGE_FAILSAFE_BYTES)
        / POWER(1024, 4) * 23.00, 4) AS estimated_monthly_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
WHERE USAGE_DATE = CURRENT_DATE - 1   -- most recent complete day
  AND DELETED IS NULL                  -- exclude dropped databases
ORDER BY total_billed_gb DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 3: Storage growth by database — month-over-month (last 6 months)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    DATE_TRUNC('month', USAGE_DATE)              AS month,
    DATABASE_NAME,
    ROUND(AVG(AVERAGE_DATABASE_BYTES) / POWER(1024, 3), 2) AS avg_active_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
WHERE USAGE_DATE >= DATEADD('month', -6, DATE_TRUNC('month', CURRENT_DATE))
  AND DELETED IS NULL
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 4: Top 50 tables by active storage
-- ─────────────────────────────────────────────────────────────────────────────
-- TABLE_STORAGE_METRICS is updated once per day.
-- Use this to identify tables that are driving storage costs.
SELECT
    TABLE_CATALOG  || '.' || TABLE_SCHEMA || '.' || TABLE_NAME AS full_table_name,
    IS_TRANSIENT,
    ROUND(ACTIVE_BYTES          / POWER(1024, 3), 4) AS active_gb,
    ROUND(TIME_TRAVEL_BYTES     / POWER(1024, 3), 4) AS time_travel_gb,
    ROUND(FAILSAFE_BYTES        / POWER(1024, 3), 4) AS failsafe_gb,
    ROUND(RETAINED_FOR_CLONE_BYTES / POWER(1024, 3), 4) AS clone_retained_gb,
    ROUND((ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES)
        / POWER(1024, 3), 4)                         AS total_billed_gb,
    -- Failsafe ratio — high ratios on tables with frequent writes indicate churn
    ROUND(FAILSAFE_BYTES / NULLIF(ACTIVE_BYTES, 0) * 100, 1) AS failsafe_pct_of_active
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE ACTIVE_BYTES > 0
ORDER BY total_billed_gb DESC
LIMIT 50;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 5: Tables with disproportionate failsafe storage (churn detection)
-- ─────────────────────────────────────────────────────────────────────────────
-- Failsafe accumulates when rows are frequently deleted or updated.
-- Tables with failsafe > 200% of active storage have high churn.
-- Common causes: streaming upserts, frequent batch deletes, poor partitioning.
-- Fix: reduce time travel window (DATA_RETENTION_TIME_IN_DAYS) on high-churn
-- tables, or use TRANSIENT tables if time travel is not needed.
SELECT
    TABLE_CATALOG || '.' || TABLE_SCHEMA || '.' || TABLE_NAME AS full_table_name,
    ROUND(ACTIVE_BYTES      / POWER(1024, 3), 2) AS active_gb,
    ROUND(FAILSAFE_BYTES    / POWER(1024, 3), 2) AS failsafe_gb,
    ROUND(FAILSAFE_BYTES / NULLIF(ACTIVE_BYTES, 0) * 100, 1) AS failsafe_pct,
    -- Actionable recommendation
    CASE
        WHEN FAILSAFE_BYTES / NULLIF(ACTIVE_BYTES, 0) > 5.0
        THEN 'REVIEW — failsafe > 500% of active. Consider TRANSIENT table or reduce DATA_RETENTION.'
        WHEN FAILSAFE_BYTES / NULLIF(ACTIVE_BYTES, 0) > 2.0
        THEN 'MONITOR — failsafe > 200% of active. High churn detected.'
        ELSE 'OK'
    END AS recommendation
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE ACTIVE_BYTES > 1073741824  -- > 1 GB active to filter noise
  AND FAILSAFE_BYTES > ACTIVE_BYTES  -- failsafe exceeds active data
ORDER BY failsafe_gb DESC
LIMIT 30;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 6: Stage storage (internal stages)
-- ─────────────────────────────────────────────────────────────────────────────
-- Internal stages (user stages, table stages, named stages) consume storage.
-- Files in stages that are never loaded or purged after loading accumulate costs.
SELECT
    USAGE_DATE,
    ROUND(AVERAGE_STAGE_BYTES / POWER(1024, 3), 2) AS avg_stage_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.STAGE_STORAGE_USAGE_HISTORY
WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE)
ORDER BY USAGE_DATE DESC;

-- To find stage files that have not been loaded:
-- Check COPY_HISTORY for files in your named stages and compare against
-- what is currently staged. Files in a stage for > 7 days without a COPY INTO
-- are candidates for cleanup.


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 7: Storage attribution by cost center (via database tags)
-- ─────────────────────────────────────────────────────────────────────────────
-- This is an estimate — one database may belong to multiple teams,
-- and table-level tagging would give better granularity.
-- See README in this section for attribution accuracy notes.
SELECT
    COALESCE(t.TAG_VALUE, 'Untagged')            AS cost_center,
    ROUND(SUM(d.AVERAGE_DATABASE_BYTES)
        / POWER(1024, 3), 2)                      AS avg_active_gb,
    ROUND(SUM(d.AVERAGE_FAILSAFE_BYTES)
        / POWER(1024, 3), 2)                      AS avg_failsafe_gb,
    ROUND(SUM(d.AVERAGE_DATABASE_BYTES
        + d.AVERAGE_FAILSAFE_BYTES)
        / POWER(1024, 3), 2)                      AS total_billed_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY d
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
    ON  t.OBJECT_NAME   = d.DATABASE_NAME
    AND t.OBJECT_DOMAIN = 'DATABASE'
    AND t.TAG_NAME      = 'COST_CENTER'
WHERE d.USAGE_DATE = CURRENT_DATE - 1
  AND d.DELETED IS NULL
GROUP BY 1
ORDER BY 4 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- TROUBLESHOOTING
-- ─────────────────────────────────────────────────────────────────────────────
/*
  ISSUE: Storage in ACCOUNT_USAGE does not match invoice
  FIX:   STORAGE_USAGE shows compressed bytes used. Snowflake bills based on
         the average daily storage across the billing month (not a single snapshot).
         The invoice figure is the average of all daily readings × rate × days.
         Use the monthly average from DATABASE_STORAGE_USAGE_HISTORY for a
         closer match to your invoice line item.

  ISSUE: Failsafe bytes for a dropped table still accumulating
  FIX:   When a table is dropped, its failsafe window (7 days) continues to
         accumulate until the failsafe period expires. This is expected behavior.
         TABLE_STORAGE_METRICS includes dropped tables (check the DELETED column
         or filter ACTIVE_BYTES > 0 to exclude them from capacity reports).

  ISSUE: Time travel bytes growing faster than expected
  FIX:   Time travel is proportional to the amount of data changed, not total size.
         A 1 GB table with daily full refreshes (DELETE + INSERT) generates
         1 GB of time travel data per day. Reduce DATA_RETENTION_TIME_IN_DAYS
         or use TRANSIENT tables for staging/temporary data.

  ISSUE: Stage storage high but no active pipes
  FIX:   Staged files persist until explicitly removed or until a PURGE = TRUE
         COPY INTO runs. Use LIST @<stage_name> to see what is in the stage
         and REMOVE @<stage_name> to clean up files that are no longer needed.
*/
