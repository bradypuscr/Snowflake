/*
================================================================================
  FILE: 02_attribution/04_unattributable_costs.sql
  PURPOSE: Quantify and document what cannot be attributed, and provide
           proportional allocation formulas for shared cost buckets.
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
================================================================================

  WHY THIS FILE EXISTS:
  ─────────────────────
  Not all Snowflake costs can be attributed to a specific team or cost center
  with the current set of ACCOUNT_USAGE views. Presenting approximate numbers
  as exact damages credibility when stakeholders ask hard questions.

  This file does three things:
  1. Quantifies how much spend is in each "unattributable" category
  2. Documents WHY each category cannot be attributed (for stakeholders)
  3. Provides proportional allocation formulas as reasonable approximations

  ACCEPTED UNKNOWNS (as of this playbook version):
  ──────────────────────────────────────────────────
  Category                  | Why it cannot be attributed
  ─────────────────────────────────────────────────────────────────────────────
  Cloud services by user    | Billed at account level; no per-user breakdown
  Replication by consumer   | SOURCE account pays; consumer not identifiable
  AI/Cortex by team         | METERING_DAILY_HISTORY shows account totals only
  Storage failsafe by team  | 7-day failsafe accrues at account level
  Cross-warehouse queries    | A single query can span multiple warehouses
  ─────────────────────────────────────────────────────────────────────────────
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1: Quantify unattributed spend (last full month)
-- ─────────────────────────────────────────────────────────────────────────────

-- Total spend across all categories last month:
WITH last_month AS (
    SELECT DATE_TRUNC('month', DATEADD('month', -1, CURRENT_DATE)) AS month_start,
           DATE_TRUNC('month', CURRENT_DATE)                        AS month_end
),
total_credits AS (
    SELECT
        SERVICE_TYPE,
        ROUND(SUM(CREDITS_USED), 2) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY, last_month
    WHERE USAGE_DATE >= month_start
      AND USAGE_DATE <  month_end
    GROUP BY 1
),
attributed_warehouse AS (
    -- Warehouse credits that are tagged (attributable)
    SELECT ROUND(SUM(w.CREDITS_USED), 2) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
    JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
        ON  t.OBJECT_NAME   = w.WAREHOUSE_NAME
        AND t.OBJECT_DOMAIN = 'WAREHOUSE'
        AND t.TAG_NAME      = 'COST_CENTER'
    CROSS JOIN last_month
    WHERE w.START_TIME >= month_start
      AND w.START_TIME <  month_end
      AND t.TAG_VALUE IS NOT NULL
)
SELECT
    tc.SERVICE_TYPE,
    tc.credits                       AS total_category_credits,
    CASE
        WHEN tc.SERVICE_TYPE = 'WAREHOUSE_METERING'
        THEN tc.credits - COALESCE(aw.credits, 0)
        ELSE tc.credits  -- all other categories are fully unattributed or partial
    END                              AS unattributed_credits,
    CASE
        WHEN tc.SERVICE_TYPE = 'WAREHOUSE_METERING'
        THEN ROUND((tc.credits - COALESCE(aw.credits, 0)) / NULLIF(tc.credits, 0) * 100, 1)
        ELSE 100.0
    END                              AS pct_unattributed
FROM total_credits tc
LEFT JOIN attributed_warehouse aw ON tc.SERVICE_TYPE = 'WAREHOUSE_METERING'
ORDER BY tc.credits DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2: Cloud services — quantify and note the attribution gap
-- ─────────────────────────────────────────────────────────────────────────────
-- Cloud services (query compilation, metadata, authentication) are billed at
-- the account level. There is no per-user or per-team breakdown available.
-- Snowflake covers the first 10% of compute credits as cloud services for free.
-- Charges above that 10% appear on your invoice.

SELECT
    DATE_TRUNC('month', START_TIME)           AS month,
    ROUND(SUM(CREDITS_USED_COMPUTE), 2)       AS compute_credits,
    ROUND(SUM(CREDITS_USED_CLOUD_SERVICES), 2) AS cloud_service_credits,
    -- The 10% free threshold
    ROUND(SUM(CREDITS_USED_COMPUTE) * 0.10, 2) AS free_cloud_threshold,
    -- Billed cloud services = anything above the threshold (approximate)
    GREATEST(0, ROUND(SUM(CREDITS_USED_CLOUD_SERVICES)
        - SUM(CREDITS_USED_COMPUTE) * 0.10, 2)) AS estimated_billed_cloud_services
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('month', -6, DATE_TRUNC('month', CURRENT_DATE))
GROUP BY 1
ORDER BY 1 DESC;

-- ATTRIBUTION GAP NOTE: Cloud services cannot be attributed to individual teams
-- or users. Best practice: include them in the "shared infrastructure" bucket
-- and allocate proportionally (see Section 4 below).


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3: Replication costs — attribution gap
-- ─────────────────────────────────────────────────────────────────────────────
-- The SOURCE account (where data originates) pays for replication.
-- There is no built-in way to attribute replication cost to the consuming
-- account or to a specific team within the consuming account.

SELECT
    DATABASE_NAME,
    ROUND(SUM(CREDITS_USED), 4) AS replication_credits,
    'Attribution: database owner or team — requires manual mapping' AS attribution_note
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_REPLICATION_USAGE_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1
ORDER BY 2 DESC;

-- WORKAROUND: Tag the replicated database with the cost center of the team
-- that owns it. This gives you warehouse-level attribution for the database
-- but does not give you the replication cost directly tied to a consumer.


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4: Proportional allocation formula for shared infrastructure
-- ─────────────────────────────────────────────────────────────────────────────
-- For costs that cannot be attributed directly, allocate them proportionally
-- based on each team's share of total attributed compute spend.
-- This is an approximation, but it is auditable and explainable.

WITH team_compute AS (
    SELECT
        COALESCE(t.TAG_VALUE, 'Untagged') AS cost_center,
        SUM(w.CREDITS_USED)               AS team_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
    LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
        ON  t.OBJECT_NAME   = w.WAREHOUSE_NAME
        AND t.OBJECT_DOMAIN = 'WAREHOUSE'
        AND t.TAG_NAME      = 'COST_CENTER'
    WHERE w.START_TIME >= DATE_TRUNC('month', CURRENT_DATE)
    GROUP BY 1
),
total_compute AS (
    SELECT SUM(team_credits) AS grand_total FROM team_compute
),
-- ⚠️ Replace 150 with the actual shared/unattributable credits for the month.
-- This value comes from Section 1 above (sum of unattributed credits).
shared_credits AS (
    SELECT 150 AS shared_total
)
SELECT
    tc.cost_center,
    ROUND(tc.team_credits, 2)                               AS direct_credits,
    ROUND(tc.team_credits / NULLIF(tot.grand_total, 0), 4)  AS share_pct,
    ROUND(tc.team_credits / NULLIF(tot.grand_total, 0)
        * sc.shared_total, 2)                               AS allocated_shared_credits,
    ROUND(tc.team_credits + (tc.team_credits / NULLIF(tot.grand_total, 0)
        * sc.shared_total), 2)                              AS total_allocated_credits
FROM team_compute tc
CROSS JOIN total_compute tot
CROSS JOIN shared_credits sc
WHERE tc.cost_center != 'Untagged'   -- exclude untagged from receiving shared allocations
ORDER BY total_allocated_credits DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5: Attribution accuracy report (for stakeholder transparency)
-- ─────────────────────────────────────────────────────────────────────────────
-- Run this monthly and share with finance/stakeholders alongside the billing report.
-- Transparency about approximations builds more trust than presenting
-- everything as precise.

SELECT
    'Warehouse compute (tagged)'                    AS category,
    'Exact'                                         AS accuracy,
    'WAREHOUSE_METERING_HISTORY + TAG_REFERENCES'   AS data_source,
    NULL                                            AS known_gap
UNION ALL SELECT
    'Warehouse compute (untagged)',  'Estimated', 'Manual tagging required',
    'Appears as Untagged bucket — investigate with 02_warehouse_attribution.sql'
UNION ALL SELECT
    'Per-user compute',  'Weighted estimate', 'QUERY_ATTRIBUTION_HISTORY',
    'Short queries (<100ms) excluded. 8-hour latency. Shared warehouses use weighted average.'
UNION ALL SELECT
    'Serverless costs by service',  'Exact', 'Per-service ACCOUNT_USAGE views',
    NULL
UNION ALL SELECT
    'Serverless costs by team',  'Partial estimate', 'Schema-level tag join',
    'Only attributable if schemas are tagged. Task and pipe attribution requires schema-level tagging.'
UNION ALL SELECT
    'Storage by database',  'Exact', 'DATABASE_STORAGE_USAGE_HISTORY',
    NULL
UNION ALL SELECT
    'Storage by team',  'Estimate', 'DATABASE_STORAGE_USAGE_HISTORY + tag join',
    'One database can contain multiple teams. TABLE_STORAGE_METRICS provides more granularity.'
UNION ALL SELECT
    'Cloud services',  'Not attributable', 'WAREHOUSE_METERING_HISTORY aggregate',
    'No per-user or per-team breakdown. Allocated proportionally in internal billing.'
UNION ALL SELECT
    'Replication',  'Not attributable by consumer', 'DATABASE_REPLICATION_USAGE_HISTORY',
    'Source account pays. No consumer-level breakdown available.'
UNION ALL SELECT
    'AI/Cortex (total)',  'Exact total only', 'METERING_DAILY_HISTORY',
    'Per-user breakdown for Cortex Code available. Other Cortex features are account-total only.'
ORDER BY category;
