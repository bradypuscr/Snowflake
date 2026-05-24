/*
================================================================================
  FILE: 02_attribution/03_user_query_attribution.sql
  PURPOSE: Attribute compute costs at the user and query level.
           Two complementary approaches: QUERY_ATTRIBUTION_HISTORY (preferred)
           and QUERY_HISTORY estimation (fallback/supplement).
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
  KEY VIEWS: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
             SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
================================================================================

  ACCURACY NOTES:
  ───────────────
  QUERY_ATTRIBUTION_HISTORY (preferred):
  • Uses weighted average across concurrent queries — more accurate than elapsed time
  • Excludes queries <= ~100ms (too short to attribute meaningfully)
  • Latency: up to 8 hours
  • Does NOT include ROLE_NAME — join to QUERY_HISTORY on QUERY_ID for role info
  • Generally available since August 2024

  QUERY_HISTORY estimation (fallback):
  • Uses (elapsed_time / 3600) * credits_per_hour_for_size
  • Overestimates when warehouse is idle or shared by concurrent queries
  • Available immediately with no significant latency
  • Includes ROLE_NAME, QUERY_TEXT, and more context fields
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 1: Top users by attributed compute — last 30 days (preferred method)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    a.USER_NAME,
    a.WAREHOUSE_NAME,
    ROUND(SUM(a.CREDITS_ATTRIBUTED_COMPUTE), 4)    AS attributed_credits,
    COUNT(*)                                        AS query_count,
    -- Average cost per query — useful for identifying expensive query patterns
    ROUND(AVG(a.CREDITS_ATTRIBUTED_COMPUTE), 6)    AS avg_credits_per_query
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY a
WHERE a.START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2
ORDER BY 3 DESC
LIMIT 50;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 2: User attribution WITH role — join to QUERY_HISTORY
-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY_ATTRIBUTION_HISTORY has no ROLE_NAME column.
-- To add role-level breakdown, join on QUERY_ID.
-- Note: this join can be slow for large datasets. Apply date filters on both sides.
SELECT
    a.USER_NAME,
    q.ROLE_NAME,
    a.WAREHOUSE_NAME,
    ROUND(SUM(a.CREDITS_ATTRIBUTED_COMPUTE), 4)   AS attributed_credits,
    COUNT(*)                                       AS query_count
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY a
JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
    ON  a.QUERY_ID   = q.QUERY_ID
    AND q.START_TIME >= DATEADD('day', -30, CURRENT_DATE)  -- push filter to QUERY_HISTORY
WHERE a.START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2, 3
ORDER BY 4 DESC
LIMIT 100;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 3: Most expensive individual queries (last 7 days)
-- ─────────────────────────────────────────────────────────────────────────────
-- Useful for finding runaway queries or identifying optimization candidates.
SELECT
    a.QUERY_ID,
    a.USER_NAME,
    a.WAREHOUSE_NAME,
    ROUND(a.CREDITS_ATTRIBUTED_COMPUTE, 6)   AS query_credits,
    -- Join to QUERY_HISTORY for query text and duration
    q.QUERY_TEXT,
    q.TOTAL_ELAPSED_TIME / 1000              AS elapsed_seconds,
    q.BYTES_SCANNED / POWER(1024, 3)         AS gb_scanned,
    q.PARTITIONS_SCANNED,
    q.PARTITIONS_TOTAL,
    -- Partition pruning ratio — low values mean inefficient filtering
    ROUND(q.PARTITIONS_SCANNED / NULLIF(q.PARTITIONS_TOTAL, 0) * 100, 1) AS pct_partitions_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY a
JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
    ON  a.QUERY_ID   = q.QUERY_ID
    AND q.START_TIME >= DATEADD('day', -7, CURRENT_DATE)
WHERE a.START_TIME >= DATEADD('day', -7, CURRENT_DATE)
  AND a.CREDITS_ATTRIBUTED_COMPUTE > 0.01   -- filter out trivially cheap queries
ORDER BY 4 DESC
LIMIT 25;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 4: Credit estimation from QUERY_HISTORY (fallback method)
-- ─────────────────────────────────────────────────────────────────────────────
-- Use when QUERY_ATTRIBUTION_HISTORY latency is too high, or for historical
-- data predating the view's general availability (August 2024).
-- This is an approximation — treat outputs as estimates, not exact figures.
WITH wh_credit_rates AS (
    -- Standard Snowflake on-demand credit rates by warehouse size.
    -- ⚠️ These may differ from your contracted rate.
    --    Adjust the credits_per_hour values to match your actual contract.
    SELECT col1 AS warehouse_size, col2 AS credits_per_hour FROM (VALUES
        ('X-Small', 1), ('Small', 2),  ('Medium', 4),   ('Large', 8),
        ('X-Large', 16), ('2X-Large', 32), ('3X-Large', 64), ('4X-Large', 128)
    ) AS rates(col1, col2)
)
SELECT
    q.USER_NAME,
    q.ROLE_NAME,
    q.WAREHOUSE_NAME,
    q.WAREHOUSE_SIZE,
    COUNT(*)                                                              AS query_count,
    ROUND(SUM(q.TOTAL_ELAPSED_TIME / 1000.0 / 3600.0
        * COALESCE(r.credits_per_hour, 1)), 4)                            AS estimated_credits,
    -- Flag: if a single user's estimated credits is very high, investigate further
    CASE WHEN SUM(q.TOTAL_ELAPSED_TIME / 1000.0 / 3600.0
        * COALESCE(r.credits_per_hour, 1)) > 10
         THEN 'REVIEW — high estimated spend'
         ELSE 'OK'
    END AS flag
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
LEFT JOIN wh_credit_rates r ON r.warehouse_size = q.WAREHOUSE_SIZE
WHERE q.START_TIME      >= DATEADD('day', -30, CURRENT_DATE)
  AND q.EXECUTION_STATUS = 'SUCCESS'
  AND q.WAREHOUSE_SIZE   IS NOT NULL
  AND q.WAREHOUSE_NAME   IS NOT NULL
GROUP BY 1, 2, 3, 4
ORDER BY 6 DESC
LIMIT 100;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 5: Users with no activity in 90 days (license optimization)
-- ─────────────────────────────────────────────────────────────────────────────
-- Beyond cost attribution, this query helps identify inactive users who may
-- not need Snowflake access at all — relevant if you pay per-user licensing.
SELECT
    u.NAME            AS username,
    u.EMAIL,
    u.CREATED_ON,
    u.LAST_SUCCESS_LOGIN,
    DATEDIFF('day', u.LAST_SUCCESS_LOGIN, CURRENT_DATE) AS days_since_login,
    COALESCE(q.query_count, 0)                          AS queries_last_90d
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS u
LEFT JOIN (
    SELECT USER_NAME, COUNT(*) AS query_count
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE START_TIME >= DATEADD('day', -90, CURRENT_DATE)
    GROUP BY 1
) q ON q.USER_NAME = u.NAME
WHERE u.DELETED_ON IS NULL
  AND COALESCE(q.query_count, 0) = 0
  AND u.LAST_SUCCESS_LOGIN < DATEADD('day', -90, CURRENT_DATE)
ORDER BY days_since_login DESC;
