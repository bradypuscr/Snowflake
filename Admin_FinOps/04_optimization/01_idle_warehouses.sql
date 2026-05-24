/*
================================================================================
  FILE: 04_optimization/01_idle_warehouses.sql
  PURPOSE: Identify warehouses wasting credits: no AUTO_SUSPEND, no recent
           activity, or consistently low query volume relative to uptime.
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
================================================================================

  NOTE ON SHOW WAREHOUSES + TASKS:
  ─────────────────────────────────
  SHOW WAREHOUSES + RESULT_SCAN works in interactive sessions but NOT inside
  Snowflake Tasks (each task step is a new session). For automated checks,
  use the stored procedure approach in 06_automation/02_warehouse_catalog_proc.sql
  which maintains a FINOPS.RAW.WAREHOUSE_CATALOG table you can JOIN against.

  The queries in this file are designed for interactive use. To automate them,
  replace the SHOW WAREHOUSES + TABLE(RESULT_SCAN()) pattern with:
    JOIN FINOPS.RAW.WAREHOUSE_CATALOG wc ON wc.warehouse_name = m.WAREHOUSE_NAME
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 1: Warehouses with AUTO_SUSPEND disabled — most urgent issue
-- ─────────────────────────────────────────────────────────────────────────────
-- AUTO_SUSPEND = 0 means the warehouse never suspends automatically.
-- It will run continuously until someone manually suspends it.
-- Snowflake bills by running time, not by query volume.
SHOW WAREHOUSES;

SELECT
    w."name"                         AS warehouse_name,
    w."size"                         AS warehouse_size,
    w."auto_suspend",
    w."state"                        AS current_state,
    ROUND(SUM(m.CREDITS_USED), 2)    AS credits_last_30_days,
    -- Estimated waste: full credits since there is no auto-suspend
    ROUND(SUM(m.CREDITS_USED), 2)    AS potential_waste_credits,
    'Set AUTO_SUSPEND = 60 or higher' AS recommended_action
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) w
JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
    ON m.WAREHOUSE_NAME = UPPER(w."name")
WHERE w."auto_suspend" = 0
  AND m.START_TIME     >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2, 3, 4
ORDER BY credits_last_30_days DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 2: Warehouses with no queries in the last 90 days
-- ─────────────────────────────────────────────────────────────────────────────
-- These warehouses may have been provisioned for a project that ended,
-- a user who left, or a test that was never cleaned up.
-- A warehouse with no queries but non-zero metering credits may still
-- be accumulating cost from auto-resume events or idle time.
WITH active_warehouses AS (
    SELECT DISTINCT WAREHOUSE_NAME
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE START_TIME >= DATEADD('day', -90, CURRENT_DATE)
),
all_metered AS (
    SELECT
        WAREHOUSE_NAME,
        ROUND(SUM(CREDITS_USED), 4) AS credits_90d
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE START_TIME >= DATEADD('day', -90, CURRENT_DATE)
    GROUP BY 1
)
SELECT
    m.WAREHOUSE_NAME,
    m.credits_90d,
    'No queries in 90 days — consider dropping or suspending' AS recommendation
FROM all_metered m
LEFT JOIN active_warehouses aw ON aw.WAREHOUSE_NAME = m.WAREHOUSE_NAME
WHERE aw.WAREHOUSE_NAME IS NULL
ORDER BY m.credits_90d DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 3: Warehouses with credits billed but very few queries (high idle ratio)
-- ─────────────────────────────────────────────────────────────────────────────
-- A high credits-per-query ratio suggests the warehouse wakes up, runs a query,
-- and then stays running until AUTO_SUSPEND triggers — billing for idle time.
-- AUTO_SUSPEND = 60 seconds typically reduces idle billing by 80-90% vs 600 seconds.
WITH wh_uptime AS (
    SELECT
        WAREHOUSE_NAME,
        ROUND(SUM(CREDITS_USED), 4)    AS credits_30d,
        COUNT(*)                       AS metering_intervals_30d  -- each row ≈ 1 min billed
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
    GROUP BY 1
),
wh_queries AS (
    SELECT
        WAREHOUSE_NAME,
        COUNT(*) AS query_count_30d
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
    GROUP BY 1
)
SELECT
    u.WAREHOUSE_NAME,
    u.credits_30d,
    u.metering_intervals_30d                                    AS billed_minutes_30d,
    COALESCE(q.query_count_30d, 0)                              AS queries_30d,
    ROUND(u.credits_30d / NULLIF(COALESCE(q.query_count_30d, 0), 0), 4) AS credits_per_query,
    ROUND(COALESCE(q.query_count_30d, 0)
        / NULLIF(u.metering_intervals_30d, 0), 2)              AS queries_per_billed_minute,
    CASE
        WHEN COALESCE(q.query_count_30d, 0) = 0
        THEN 'NO QUERIES — candidate for removal'
        WHEN u.credits_30d / NULLIF(COALESCE(q.query_count_30d, 0), 0) > 1
        THEN 'HIGH IDLE RATIO — reduce AUTO_SUSPEND window'
        ELSE 'OK'
    END AS flag
FROM wh_uptime u
LEFT JOIN wh_queries q ON u.WAREHOUSE_NAME = q.WAREHOUSE_NAME
ORDER BY credits_per_query DESC NULLS LAST
LIMIT 30;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 4: Incremental last-access tracking (recommended for automation)
-- ─────────────────────────────────────────────────────────────────────────────
-- The 90-day lookback above is slow on large accounts.
-- This pattern maintains a small table updated daily for fast last-access lookups.
-- Requires FINOPS schema from 06_automation/01_finops_schema_setup.sql.

-- Create the tracking table (one-time setup):
CREATE TABLE IF NOT EXISTS FINOPS.RAW.WAREHOUSE_LAST_ACCESS (
    warehouse_name    STRING,
    last_query_date   DATE,
    last_updated_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Refresh the tracking table (run daily via Task):
MERGE INTO FINOPS.RAW.WAREHOUSE_LAST_ACCESS AS target
USING (
    SELECT
        WAREHOUSE_NAME,
        MAX(DATE(START_TIME)) AS last_query_date
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE START_TIME >= DATEADD('day', -7, CURRENT_DATE)  -- only scan recent data
    GROUP BY 1
) AS source
ON target.warehouse_name = source.WAREHOUSE_NAME
WHEN MATCHED THEN UPDATE SET
    last_query_date = source.last_query_date,
    last_updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (warehouse_name, last_query_date) VALUES (source.WAREHOUSE_NAME, source.last_query_date);

-- Fast idle warehouse query using the tracking table:
SELECT
    la.warehouse_name,
    la.last_query_date,
    DATEDIFF('day', la.last_query_date, CURRENT_DATE) AS days_idle
FROM FINOPS.RAW.WAREHOUSE_LAST_ACCESS la
WHERE la.last_query_date < DATEADD('day', -30, CURRENT_DATE)
ORDER BY days_idle DESC;
