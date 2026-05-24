/*
================================================================================
  FILE: 03_cost_reports/01_warehouse_compute.sql
  PURPOSE: Warehouse compute cost reports at multiple time granularities.
           Starting point for any FinOps investigation.
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
  KEY VIEW: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  ACCURACY: Exact
  LATENCY:  Up to 3 hours
================================================================================
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 1: Last 30 days by warehouse (with activity pattern)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    WAREHOUSE_NAME,
    ROUND(SUM(CREDITS_USED), 4)                                         AS total_credits,
    ROUND(SUM(CREDITS_USED_COMPUTE), 4)                                 AS compute_credits,
    ROUND(SUM(CREDITS_USED_CLOUD_SERVICES), 4)                          AS cloud_svc_credits,
    COUNT(DISTINCT DATE(START_TIME))                                     AS active_days,
    ROUND(SUM(CREDITS_USED)
        / NULLIF(COUNT(DISTINCT DATE(START_TIME)), 0), 4)               AS avg_credits_per_active_day,
    -- Cloud services % — consistently > 10% may indicate metadata-heavy workloads
    ROUND(SUM(CREDITS_USED_CLOUD_SERVICES)
        / NULLIF(SUM(CREDITS_USED_COMPUTE), 0) * 100, 1)                AS cloud_svc_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1
ORDER BY 2 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 2: Weekly summary — last 12 weeks (trend visibility)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    DATE_TRUNC('week', START_TIME)                AS week_start,
    WAREHOUSE_NAME,
    ROUND(SUM(CREDITS_USED), 2)                   AS weekly_credits,
    -- Week-over-week change for this specific warehouse
    LAG(ROUND(SUM(CREDITS_USED), 2)) OVER (
        PARTITION BY WAREHOUSE_NAME
        ORDER BY DATE_TRUNC('week', START_TIME)
    )                                              AS prev_week_credits,
    ROUND(
        (SUM(CREDITS_USED) - LAG(SUM(CREDITS_USED)) OVER (
            PARTITION BY WAREHOUSE_NAME
            ORDER BY DATE_TRUNC('week', START_TIME)
        )) / NULLIF(LAG(SUM(CREDITS_USED)) OVER (
            PARTITION BY WAREHOUSE_NAME
            ORDER BY DATE_TRUNC('week', START_TIME)
        ), 0) * 100, 1
    )                                              AS wow_pct_change
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('week', -12, DATE_TRUNC('week', CURRENT_DATE))
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 3: Monthly total by warehouse — last 6 months
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    DATE_TRUNC('month', START_TIME)  AS month,
    WAREHOUSE_NAME,
    ROUND(SUM(CREDITS_USED), 2)      AS monthly_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('month', -6, DATE_TRUNC('month', CURRENT_DATE))
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 4: Hourly activity heatmap — last 30 days
-- ─────────────────────────────────────────────────────────────────────────────
-- Identifies off-hours activity and peak usage windows.
-- Useful for scheduling batch jobs and sizing auto-suspend windows.
SELECT
    WAREHOUSE_NAME,
    DAYOFWEEKISO(START_TIME)           AS iso_day_of_week,  -- 1=Mon, 7=Sun
    TO_CHAR(START_TIME, 'DY')          AS day_name,
    HOUR(START_TIME)                   AS hour_of_day,
    ROUND(SUM(CREDITS_USED), 4)        AS credits,
    COUNT(*)                           AS billing_intervals    -- each row = 1 minute interval
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 4;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 5: Top 10 most expensive days (last 90 days) — spike investigation
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    DATE(START_TIME)              AS usage_date,
    ROUND(SUM(CREDITS_USED), 2)   AS daily_credits,
    -- Rank to quickly surface the most anomalous days
    RANK() OVER (ORDER BY SUM(CREDITS_USED) DESC) AS rank
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -90, CURRENT_DATE)
GROUP BY 1
ORDER BY 2 DESC
LIMIT 10;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 6: Warehouse uptime (minutes billed) vs queries executed
-- ─────────────────────────────────────────────────────────────────────────────
-- A high minutes-billed with a low query count suggests the warehouse was
-- running idle for long periods. This is the key efficiency metric.
-- Cross-join with QUERY_HISTORY to get query counts.
WITH wh_uptime AS (
    SELECT
        WAREHOUSE_NAME,
        ROUND(SUM(CREDITS_USED), 4)     AS credits_used,
        COUNT(*)                        AS billed_intervals_minutes
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
    GROUP BY 1
),
wh_queries AS (
    SELECT
        WAREHOUSE_NAME,
        COUNT(*) AS query_count
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
      AND EXECUTION_STATUS = 'SUCCESS'
    GROUP BY 1
)
SELECT
    u.WAREHOUSE_NAME,
    u.credits_used,
    u.billed_intervals_minutes,
    COALESCE(q.query_count, 0)               AS query_count,
    -- Credits per query — high values may indicate idle billing or very heavy queries
    ROUND(u.credits_used / NULLIF(COALESCE(q.query_count, 0), 0), 4) AS credits_per_query
FROM wh_uptime u
LEFT JOIN wh_queries q ON u.WAREHOUSE_NAME = q.WAREHOUSE_NAME
ORDER BY u.credits_used DESC;
