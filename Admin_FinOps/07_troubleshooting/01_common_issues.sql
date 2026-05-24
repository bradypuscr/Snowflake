/*
================================================================================
  FILE: 07_troubleshooting/01_common_issues.sql
  PURPOSE: Diagnostic queries for the most common FinOps system issues.
           Run the relevant section when something is not working as expected.
  REQUIRES: FINOPS_ADMIN role (some checks need ACCOUNTADMIN)
================================================================================
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- ISSUE 1: RESULT_SCAN returns empty inside a Task
-- ─────────────────────────────────────────────────────────────────────────────
-- Symptoms: Task runs without error but WAREHOUSE_CATALOG table stays empty.
-- Cause:    Each Task step runs in a new session. LAST_QUERY_ID() returns the
--           Task framework's internal query ID, not your SHOW WAREHOUSES.
-- Fix:      Use FINOPS.UTILS.REFRESH_WAREHOUSE_CATALOG() stored procedure instead.

-- Verify the procedure exists and works:
CALL FINOPS.UTILS.REFRESH_WAREHOUSE_CATALOG();
SELECT COUNT(*) AS rows_in_catalog FROM FINOPS.RAW.WAREHOUSE_CATALOG;

-- If the stored procedure itself returns empty, verify it runs correctly in your session:
SHOW WAREHOUSES;
SELECT COUNT(*) AS rows_from_show_warehouses FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
-- If this returns 0, your current role may not have MONITOR USAGE. Check grants.


-- ─────────────────────────────────────────────────────────────────────────────
-- ISSUE 2: TAG_REFERENCES not showing recently applied tags
-- ─────────────────────────────────────────────────────────────────────────────
-- Symptoms: You applied a tag but it does not appear in attribution queries.
-- Cause:    TAG_REFERENCES lags up to 3 hours.
-- Fix:      Use SYSTEM$GET_TAG() for immediate verification of the applied tag.

-- Verify a tag was applied immediately (no latency):
SELECT SYSTEM$GET_TAG(
    'GOVERNANCE.TAGS.COST_CENTER',
    'ANALYTICS_WH',
    'WAREHOUSE'
) AS current_cost_center_value;
-- Returns NULL if tag is not applied. Returns the value if it is.

-- Check when TAG_REFERENCES last refreshed:
SELECT MAX(TAG_VALUE), COUNT(*)
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE TAG_NAME = 'COST_CENTER'
  AND DOMAIN   = 'WAREHOUSE';
-- If this returns 0 rows, TAG_REFERENCES may still be initializing
-- or your role lacks IMPORTED PRIVILEGES on SNOWFLAKE.


-- ─────────────────────────────────────────────────────────────────────────────
-- ISSUE 3: ACCOUNT_USAGE data appears stale or missing recent activity
-- ─────────────────────────────────────────────────────────────────────────────
-- Symptoms: Queries you ran today do not appear in QUERY_HISTORY.
-- Cause:    ACCOUNT_USAGE latency (3 hours for most views, 8 hours for QUERY_ATTRIBUTION_HISTORY).
-- Fix:      Use INFORMATION_SCHEMA for near-real-time data (7-day window only).

-- Check the current lag for key views:
SELECT
    'WAREHOUSE_METERING_HISTORY'  AS view_name,
    MAX(START_TIME)               AS latest_record,
    DATEDIFF('minute', MAX(START_TIME), CURRENT_TIMESTAMP()) AS lag_minutes
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
UNION ALL
SELECT
    'QUERY_HISTORY',
    MAX(START_TIME),
    DATEDIFF('minute', MAX(START_TIME), CURRENT_TIMESTAMP())
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
UNION ALL
SELECT
    'QUERY_ATTRIBUTION_HISTORY',
    MAX(START_TIME),
    DATEDIFF('minute', MAX(START_TIME), CURRENT_TIMESTAMP())
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY;

-- Expected: WAREHOUSE_METERING < 180 min, QUERY_ATTRIBUTION < 480 min.
-- If lag is much higher, check Snowflake status page or open a support ticket.

-- For near-real-time query data (last 7 days, no latency):
SELECT *
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(
    RESULT_LIMIT => 100
))
ORDER BY START_TIME DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- ISSUE 4: Report totals don't match Snowflake invoice
-- ─────────────────────────────────────────────────────────────────────────────
-- Symptoms: Your ACCOUNT_USAGE sum differs from the invoice amount.
-- Cause:    Invoice includes contract adjustments, capacity commitments,
--           and rounding not visible in ACCOUNT_USAGE.
-- Fix:      Use ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY as the authoritative source.

-- Compare ACCOUNT_USAGE credit sum vs ORGANIZATION_USAGE dollar amount:
-- (Run the ACCOUNT_USAGE side first, then compare to ORGANIZATION_USAGE)
SELECT
    DATE_TRUNC('month', START_TIME)        AS month,
    ROUND(SUM(CREDITS_USED), 4)            AS account_usage_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('month', -1, DATE_TRUNC('month', CURRENT_DATE))
  AND START_TIME <  DATE_TRUNC('month', CURRENT_DATE)
GROUP BY 1;

-- Then check ORGANIZATION_USAGE (requires ORGADMIN):
-- SELECT ROUND(SUM(USAGE_IN_CURRENCY), 4) AS org_usage_total_usd
-- FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
-- WHERE DATE_TRUNC('month', USAGE_DATE) = DATE_TRUNC('month', DATEADD('month', -1, CURRENT_DATE))
--   AND ACCOUNT_NAME = CURRENT_ACCOUNT()
--   AND RATING_TYPE = 'compute';

-- If the dollar amounts differ significantly:
-- 1. Check if your account uses commitment-based pricing (prepaid capacity)
-- 2. Check if there are credits or adjustments on the invoice
-- 3. Verify your per-credit rate — USAGE_IN_CURRENCY / USAGE = rate per credit


-- ─────────────────────────────────────────────────────────────────────────────
-- ISSUE 5: Attribution query total does not match total spend
-- ─────────────────────────────────────────────────────────────────────────────
-- Symptoms: Sum of all cost centers does not equal total WAREHOUSE_METERING_HISTORY sum.
-- Cause:    INNER JOIN to TAG_REFERENCES is dropping untagged rows.
-- Fix:      Always use LEFT JOIN. The difference = your untagged spend.

-- Verify the discrepancy:
WITH total AS (
    SELECT ROUND(SUM(CREDITS_USED), 4) AS all_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE START_TIME >= DATE_TRUNC('month', CURRENT_DATE)
),
attributed AS (
    SELECT ROUND(SUM(w.CREDITS_USED), 4) AS attributed_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
    INNER JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t  -- ← this is the problem pattern
        ON t.OBJECT_NAME = w.WAREHOUSE_NAME
        AND t.OBJECT_DOMAIN = 'WAREHOUSE'
        AND t.TAG_NAME = 'COST_CENTER'
    WHERE w.START_TIME >= DATE_TRUNC('month', CURRENT_DATE)
)
SELECT
    t.all_credits,
    a.attributed_credits,
    ROUND(t.all_credits - a.attributed_credits, 4) AS untagged_credits_hidden_by_inner_join
FROM total t, attributed a;


-- ─────────────────────────────────────────────────────────────────────────────
-- ISSUE 6: QUERY_ATTRIBUTION_HISTORY missing many queries
-- ─────────────────────────────────────────────────────────────────────────────
-- Symptoms: QUERY_ATTRIBUTION_HISTORY has far fewer rows than QUERY_HISTORY.
-- Cause:    QUERY_ATTRIBUTION_HISTORY excludes queries <= ~100ms (too short
--           to meaningfully attribute). This is expected behavior.
-- Diagnosis:

SELECT
    'QUERY_HISTORY'         AS source,
    COUNT(*)                AS row_count,
    MIN(TOTAL_ELAPSED_TIME) AS min_elapsed_ms,
    AVG(TOTAL_ELAPSED_TIME) AS avg_elapsed_ms
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_DATE)
UNION ALL
SELECT
    'QUERY_ATTRIBUTION_HISTORY',
    COUNT(*),
    NULL,
    NULL
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_DATE);

-- The gap between the two counts is expected — short queries are excluded.
-- For very short query workloads (BI tools pinging metadata, small selects),
-- QUERY_ATTRIBUTION_HISTORY will have significantly fewer rows than QUERY_HISTORY.


-- ─────────────────────────────────────────────────────────────────────────────
-- ISSUE 7: Task not running on schedule
-- ─────────────────────────────────────────────────────────────────────────────
-- Symptoms: FINOPS task has SCHEDULED state but never completes.
-- Cause:    Several possibilities — warehouse not auto-resuming, role privilege
--           missing, or task was suspended.

-- Check task status:
SHOW TASKS IN SCHEMA FINOPS.UTILS;

-- Check recent task run history:
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_CODE, ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('day', -3, CURRENT_TIMESTAMP())
))
WHERE NAME LIKE 'FINOPS_%'
ORDER BY SCHEDULED_TIME DESC;

-- If STATE = 'FAILED', check ERROR_MESSAGE for the specific cause.
-- Common error messages and fixes:
--   "Warehouse FINOPS_WH does not exist" → Create the warehouse (01_finops_schema_setup.sql)
--   "Insufficient privileges" → Grant EXECUTE TASK to FINOPS_ADMIN
--   "Object FINOPS.RAW.X does not exist" → Run 01_finops_schema_setup.sql
--   "Cannot create tasks — account limit reached" → Check Snowflake task limits for your edition


-- ─────────────────────────────────────────────────────────────────────────────
-- ISSUE 8: Storage in reports differs from invoice storage line item
-- ─────────────────────────────────────────────────────────────────────────────
-- Cause: Invoice bills the AVERAGE daily storage for the month (TB × days × rate).
--        STORAGE_USAGE shows individual daily snapshots.
-- Fix:   Average the daily snapshots across the billing month.

SELECT
    DATE_TRUNC('month', USAGE_DATE)                                    AS billing_month,
    ROUND(AVG(STORAGE_BYTES + FAILSAFE_BYTES) / POWER(1024, 4), 6)    AS avg_monthly_tb,
    -- Estimated monthly charge (replace 23.00 with your per-TB rate):
    ROUND(AVG(STORAGE_BYTES + FAILSAFE_BYTES) / POWER(1024, 4) * 23.00, 2) AS estimated_monthly_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
WHERE USAGE_DATE >= DATEADD('month', -3, DATE_TRUNC('month', CURRENT_DATE))
GROUP BY 1
ORDER BY 1 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- ISSUE 9: Cortex Code view queries failing (wrong column names)
-- ─────────────────────────────────────────────────────────────────────────────
-- Symptoms: "Column not found" errors when querying CORTEX_CODE_*_USAGE_HISTORY.
-- Cause:    These views use USER_ID, USAGE_TIME, TOKEN_CREDITS —
--           NOT USER_NAME, START_TIME, CREDITS_USED.

-- Verify the actual column names in your version:
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'ACCOUNT_USAGE'
  AND TABLE_NAME   LIKE 'CORTEX_CODE%'
ORDER BY TABLE_NAME, ORDINAL_POSITION;

-- Verify that the DESKTOP view exists in your account version:
SHOW VIEWS IN SCHEMA SNOWFLAKE.ACCOUNT_USAGE LIKE 'CORTEX_CODE%';
