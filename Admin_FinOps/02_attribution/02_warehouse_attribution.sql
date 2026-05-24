/*
================================================================================
  FILE: 02_attribution/02_warehouse_attribution.sql
  PURPOSE: Attribute warehouse compute costs by cost center, team, environment,
           and time period. Foundation for internal billing reports.
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
  KEY VIEW: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
            SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
================================================================================

  ACCURACY: Exact when tags are consistently applied.
  LATENCY:  WAREHOUSE_METERING_HISTORY: up to 3 hours.
            TAG_REFERENCES: up to 3 hours.
  NOTE:     Always use LEFT JOIN to TAG_REFERENCES. INNER JOIN silently drops
            untagged spend, making totals incorrect.
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 1: Monthly credits by cost center (current month)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    COALESCE(t.TAG_VALUE, 'Untagged')            AS cost_center,
    ROUND(SUM(w.CREDITS_USED), 2)                 AS total_credits,
    ROUND(SUM(w.CREDITS_USED_COMPUTE), 2)         AS compute_credits,
    ROUND(SUM(w.CREDITS_USED_CLOUD_SERVICES), 2)  AS cloud_service_credits,
    -- Cloud services as % of compute (anything consistently > 10% is unusual)
    ROUND(SUM(w.CREDITS_USED_CLOUD_SERVICES)
        / NULLIF(SUM(w.CREDITS_USED_COMPUTE), 0) * 100, 1) AS cloud_pct_of_compute
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
    ON  t.OBJECT_NAME   = w.WAREHOUSE_NAME
    AND t.OBJECT_DOMAIN = 'WAREHOUSE'
    AND t.TAG_NAME      = 'COST_CENTER'
WHERE w.START_TIME >= DATE_TRUNC('month', CURRENT_DATE)
GROUP BY 1
ORDER BY 2 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 2: Month-over-month trend by cost center (last 6 months)
-- ─────────────────────────────────────────────────────────────────────────────
-- Useful for showing teams whether their spend is growing, stable, or declining.
SELECT
    DATE_TRUNC('month', w.START_TIME)            AS month,
    COALESCE(t.TAG_VALUE, 'Untagged')            AS cost_center,
    ROUND(SUM(w.CREDITS_USED), 2)                 AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
    ON  t.OBJECT_NAME   = w.WAREHOUSE_NAME
    AND t.OBJECT_DOMAIN = 'WAREHOUSE'
    AND t.TAG_NAME      = 'COST_CENTER'
WHERE w.START_TIME >= DATEADD('month', -6, DATE_TRUNC('month', CURRENT_DATE))
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 3: Daily credits by warehouse (last 30 days)
-- ─────────────────────────────────────────────────────────────────────────────
-- For identifying specific days with anomalous spend.
-- Feed this into the anomaly detection script for automated alerting.
SELECT
    DATE(w.START_TIME)                            AS usage_date,
    w.WAREHOUSE_NAME,
    COALESCE(t.TAG_VALUE, 'Untagged')             AS cost_center,
    ROUND(SUM(w.CREDITS_USED), 4)                 AS daily_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
    ON  t.OBJECT_NAME   = w.WAREHOUSE_NAME
    AND t.OBJECT_DOMAIN = 'WAREHOUSE'
    AND t.TAG_NAME      = 'COST_CENTER'
WHERE w.START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 4 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 4: Prod vs dev split by cost center
-- ─────────────────────────────────────────────────────────────────────────────
-- If dev spend consistently exceeds a threshold of total spend for a team,
-- it may indicate dev workloads are running on over-provisioned warehouses.
-- Common target: dev should be < 20% of total for mature teams.
SELECT
    COALESCE(cc.TAG_VALUE, 'Untagged')     AS cost_center,
    COALESCE(env.TAG_VALUE, 'Untagged')    AS environment,
    ROUND(SUM(w.CREDITS_USED), 2)           AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES cc
    ON  cc.OBJECT_NAME   = w.WAREHOUSE_NAME
    AND cc.OBJECT_DOMAIN = 'WAREHOUSE'
    AND cc.TAG_NAME      = 'COST_CENTER'
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES env
    ON  env.OBJECT_NAME   = w.WAREHOUSE_NAME
    AND env.OBJECT_DOMAIN = 'WAREHOUSE'
    AND env.TAG_NAME      = 'ENVIRONMENT'
WHERE w.START_TIME >= DATE_TRUNC('month', CURRENT_DATE)
GROUP BY 1, 2
ORDER BY 1, 3 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 5: Credits by hour of day (usage pattern analysis)
-- ─────────────────────────────────────────────────────────────────────────────
-- Useful for identifying off-hours activity (nights, weekends) that may
-- indicate batch jobs running at unexpected times, or warehouses not suspending.
SELECT
    DAYOFWEEK(w.START_TIME)                   AS day_of_week,  -- 0=Sun, 6=Sat
    HOUR(w.START_TIME)                         AS hour_of_day,
    w.WAREHOUSE_NAME,
    ROUND(SUM(w.CREDITS_USED), 4)              AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
WHERE w.START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2, 3
ORDER BY 4 DESC
LIMIT 100;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 6: Shared warehouse attribution problem
-- ─────────────────────────────────────────────────────────────────────────────
-- When multiple teams use the same warehouse, tagging the warehouse to one team
-- attributes all its cost to that team. This query identifies shared warehouses
-- (multiple users from different teams) so you can decide how to handle them.
SELECT
    q.WAREHOUSE_NAME,
    COUNT(DISTINCT q.USER_NAME)                AS distinct_users,
    COUNT(DISTINCT q.ROLE_NAME)                AS distinct_roles,
    -- If users from more than one role use a warehouse, it may be shared.
    LISTAGG(DISTINCT q.ROLE_NAME, ', ')
        WITHIN GROUP (ORDER BY q.ROLE_NAME)    AS roles_using_warehouse,
    COUNT(*)                                   AS query_count,
    ROUND(SUM(q.TOTAL_ELAPSED_TIME) / 1000.0 / 3600.0, 2) AS total_elapsed_hours
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
WHERE q.START_TIME >= DATEADD('day', -30, CURRENT_DATE)
  AND q.WAREHOUSE_NAME IS NOT NULL
  AND q.EXECUTION_STATUS = 'SUCCESS'
GROUP BY 1
HAVING distinct_roles > 2  -- adjust threshold as needed
ORDER BY distinct_users DESC;

-- For truly shared warehouses (used by many teams), the best approach is to
-- tag them as 'shared_infra' and allocate their cost proportionally in the
-- internal billing report (see 03_cost_reports/05_internal_billing.sql).
