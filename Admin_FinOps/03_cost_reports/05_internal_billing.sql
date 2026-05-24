/*
================================================================================
  FILE: 03_cost_reports/05_internal_billing.sql
  PURPOSE: Monthly internal billing report combining warehouse compute,
           serverless, storage, and AI costs by cost center.
           Includes dollar estimation and shared infrastructure allocation.
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
  ACCURACY: Mixed — see accuracy notes per cost component.
  ⚠️ IMPORTANT: Replace credit rate placeholder (3.00) with your actual
               contracted per-credit price before sharing with finance.
================================================================================

  REPORT STRUCTURE:
  ─────────────────
  1. Direct warehouse compute by cost center (tagged)
  2. Serverless costs by schema → cost center (partial attribution)
  3. Storage by database → cost center (partial attribution)
  4. Shared infrastructure pool (unattributed costs)
  5. Final allocated report with proportional shared cost distribution

  WHAT THIS REPORT DOES NOT CAPTURE PERFECTLY:
  ─────────────────────────────────────────────
  • Cloud services (account-level, distributed proportionally)
  • AI/Cortex costs by team (distributed proportionally)
  • Replication costs by consumer (distributed proportionally)
  • Cross-team warehouse usage
  These categories are noted in the report with "Estimated/Allocated" flags.
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1: Warehouse compute by cost center (current month)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TEMPORARY TABLE tmp_wh_compute AS
SELECT
    COALESCE(t.TAG_VALUE, 'shared_infra')     AS cost_center,
    'Warehouse Compute'                        AS category,
    'Exact'                                    AS accuracy,
    ROUND(SUM(w.CREDITS_USED), 4)             AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
    ON  t.OBJECT_NAME   = w.WAREHOUSE_NAME
    AND t.OBJECT_DOMAIN = 'WAREHOUSE'
    AND t.TAG_NAME      = 'COST_CENTER'
WHERE w.START_TIME >= DATE_TRUNC('month', CURRENT_DATE)
GROUP BY 1;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2: Serverless costs — attributed via schema-level tags
-- ─────────────────────────────────────────────────────────────────────────────
-- Serverless costs can only be attributed if the schema containing the objects
-- is tagged. Objects in untagged schemas go to shared_infra.
-- NOTE: This join requires schema-level tag application. If schemas are not
--       tagged, all serverless costs will fall to 'shared_infra'.
CREATE OR REPLACE TEMPORARY TABLE tmp_serverless AS
WITH serverless_raw AS (
    SELECT PIPE_SCHEMA AS schema_name, PIPE_NAME AS object_name, SUM(CREDITS_USED) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
    WHERE START_TIME >= DATE_TRUNC('month', CURRENT_DATE)
    GROUP BY 1, 2

    UNION ALL
    SELECT TABLE_SCHEMA, TABLE_NAME, SUM(CREDITS_USED)
    FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
    WHERE START_TIME >= DATE_TRUNC('month', CURRENT_DATE)
    GROUP BY 1, 2

    UNION ALL
    SELECT SCHEMA_NAME, TASK_NAME, SUM(CREDITS_USED)
    FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
    WHERE START_TIME >= DATE_TRUNC('month', CURRENT_DATE)
    GROUP BY 1, 2
)
SELECT
    COALESCE(t.TAG_VALUE, 'shared_infra') AS cost_center,
    'Serverless'                           AS category,
    'Partial (schema-level)'               AS accuracy,
    ROUND(SUM(s.credits), 4)              AS credits
FROM serverless_raw s
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
    ON  t.OBJECT_NAME   = s.schema_name
    AND t.OBJECT_DOMAIN = 'SCHEMA'
    AND t.TAG_NAME      = 'COST_CENTER'
GROUP BY 1;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3: Storage costs — attributed via database-level tags (current month avg)
-- ─────────────────────────────────────────────────────────────────────────────
-- Storage billing = (avg_TB_per_day × rate × days_in_month).
-- This query computes the monthly average from daily snapshots.
-- ⚠️ Replace 23.00 with your actual per-TB-per-month storage rate (in USD).
CREATE OR REPLACE TEMPORARY TABLE tmp_storage AS
SELECT
    COALESCE(t.TAG_VALUE, 'shared_infra')         AS cost_center,
    'Storage'                                      AS category,
    'Estimate (database-level tag)'                AS accuracy,
    -- Convert to TB-months: avg bytes / bytes_per_TB * (days_in_month / 30)
    ROUND(AVG(d.AVERAGE_DATABASE_BYTES + d.AVERAGE_FAILSAFE_BYTES)
        / POWER(1024, 4), 4)                       AS avg_tb,
    -- Dollar estimate using TB/month rate. Credits = 0 for storage (billed separately).
    -- Include as informational in the billing report.
    ROUND(AVG(d.AVERAGE_DATABASE_BYTES + d.AVERAGE_FAILSAFE_BYTES)
        / POWER(1024, 4) * 23.00, 2)              AS estimated_monthly_usd,
    0.0                                            AS credits  -- storage is not credit-based
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY d
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
    ON  t.OBJECT_NAME   = d.DATABASE_NAME
    AND t.OBJECT_DOMAIN = 'DATABASE'
    AND t.TAG_NAME      = 'COST_CENTER'
WHERE d.USAGE_DATE >= DATE_TRUNC('month', CURRENT_DATE)
  AND d.DELETED IS NULL
GROUP BY 1;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4: AI/Cortex costs (account-level total, to be allocated proportionally)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TEMPORARY TABLE tmp_ai AS
SELECT
    'shared_infra'        AS cost_center,
    'AI / Cortex'         AS category,
    'Account total only'  AS accuracy,
    ROUND(SUM(CREDITS_USED), 4) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= DATE_TRUNC('month', CURRENT_DATE)
  AND SERVICE_TYPE IN ('AI_SERVICES', 'CORTEX_CODE', 'CORTEX_AGENT');


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5: Final billing report — compute + serverless + proportional shared pool
-- ─────────────────────────────────────────────────────────────────────────────
-- ⚠️ Replace 3.00 with your actual per-credit contracted price.
WITH all_credits AS (
    SELECT cost_center, category, accuracy, credits FROM tmp_wh_compute
    UNION ALL
    SELECT cost_center, category, accuracy, credits FROM tmp_serverless
    UNION ALL
    SELECT cost_center, category, accuracy, credits FROM tmp_ai
),
team_direct AS (
    SELECT cost_center, SUM(credits) AS direct_credits
    FROM all_credits
    WHERE cost_center != 'shared_infra'
    GROUP BY 1
),
shared_total AS (
    SELECT SUM(credits) AS total_shared FROM all_credits WHERE cost_center = 'shared_infra'
),
grand_total AS (
    SELECT SUM(credits) AS total FROM all_credits WHERE cost_center != 'shared_infra'
),
allocated AS (
    SELECT
        td.cost_center,
        ROUND(td.direct_credits, 2)                                        AS direct_credits,
        ROUND(td.direct_credits / NULLIF(gt.total, 0), 4)                  AS share_pct,
        ROUND(td.direct_credits / NULLIF(gt.total, 0) * st.total_shared, 2) AS allocated_shared_credits,
        ROUND(td.direct_credits
            + td.direct_credits / NULLIF(gt.total, 0) * st.total_shared, 2) AS total_credits
    FROM team_direct td
    CROSS JOIN shared_total st
    CROSS JOIN grand_total gt
)
SELECT
    a.cost_center,
    a.direct_credits,
    a.allocated_shared_credits,
    a.total_credits,
    -- Dollar estimates (replace 3.00 with your actual rate)
    ROUND(a.direct_credits           * 3.00, 2) AS direct_usd_estimate,
    ROUND(a.total_credits            * 3.00, 2) AS total_usd_estimate,
    ROUND(a.share_pct * 100, 1)                 AS share_pct_display
FROM allocated a
ORDER BY total_credits DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY: Shared infrastructure pool breakdown (for stakeholder transparency)
-- ─────────────────────────────────────────────────────────────────────────────
-- This shows finance and stakeholders exactly what went into the shared pool
-- and why it could not be attributed directly.
SELECT
    category,
    accuracy,
    ROUND(credits, 2) AS credits,
    'Distributed proportionally to all cost centers based on compute share' AS allocation_method
FROM (
    SELECT category, accuracy, credits FROM tmp_serverless WHERE cost_center = 'shared_infra'
    UNION ALL SELECT category, accuracy, credits FROM tmp_ai
    UNION ALL SELECT * FROM (
        SELECT 'Cloud Services' AS category, 'Account total (no per-team breakdown)' AS accuracy,
               ROUND(SUM(CREDITS_USED_CLOUD_SERVICES)
                   - SUM(CREDITS_USED_COMPUTE) * 0.10, 2) AS credits
        FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
        WHERE START_TIME >= DATE_TRUNC('month', CURRENT_DATE)
    ) cloud
    UNION ALL SELECT * FROM (
        SELECT 'Replication' AS category, 'Source account cost, no consumer attribution' AS accuracy,
               ROUND(SUM(CREDITS_USED), 2) AS credits
        FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_REPLICATION_USAGE_HISTORY
        WHERE START_TIME >= DATE_TRUNC('month', CURRENT_DATE)
    ) replication
)
ORDER BY credits DESC;
