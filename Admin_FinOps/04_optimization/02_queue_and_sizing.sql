/*
================================================================================
  FILE: 04_optimization/02_queue_and_sizing.sql
  PURPOSE: Identify warehouses that are incorrectly sized — either too small
           (causing queuing) or too large (paying for unused capacity).
           Also covers multi-cluster warehouse analysis and spill-to-disk detection.
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
  KEY VIEW: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
================================================================================

  SIZING PRINCIPLE:
  ─────────────────
  Snowflake charges the same per-minute rate regardless of whether a warehouse
  is processing queries or idle. The billing unit is time, not compute utilization.

  An undersized warehouse causes queuing → users wait, warehouse stays busy and
  billing the whole time → you pay for poor performance.

  An oversized warehouse processes queries faster but bills more credits per
  minute. If queries are already fast (< 5 seconds), a larger warehouse is
  usually not worth the cost premium.
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 1: Warehouses with high queue time (undersized)
-- ─────────────────────────────────────────────────────────────────────────────
-- QUEUED_OVERLOAD_TIME: time the query spent waiting because all concurrent
-- slots on the warehouse were occupied.
-- If pct_time_queued is consistently > 20-30%, the warehouse needs more concurrency.
SELECT
    WAREHOUSE_NAME,
    WAREHOUSE_SIZE,
    COUNT(*)                                                                 AS query_count,
    ROUND(AVG(QUEUED_OVERLOAD_TIME / 1000.0), 1)                             AS avg_queue_seconds,
    ROUND(AVG(TOTAL_ELAPSED_TIME   / 1000.0), 1)                             AS avg_elapsed_seconds,
    ROUND(AVG(QUEUED_OVERLOAD_TIME)
        / NULLIF(AVG(TOTAL_ELAPSED_TIME), 0) * 100, 1)                       AS pct_time_queued,
    ROUND(MAX(QUEUED_OVERLOAD_TIME / 1000.0), 1)                             AS max_queue_seconds,
    CASE
        WHEN AVG(QUEUED_OVERLOAD_TIME)
            / NULLIF(AVG(TOTAL_ELAPSED_TIME), 0) > 0.40
        THEN 'CRITICAL — > 40% time in queue. Increase size or enable multi-cluster.'
        WHEN AVG(QUEUED_OVERLOAD_TIME)
            / NULLIF(AVG(TOTAL_ELAPSED_TIME), 0) > 0.20
        THEN 'HIGH — > 20% time in queue. Consider increasing size.'
        WHEN AVG(QUEUED_OVERLOAD_TIME)
            / NULLIF(AVG(TOTAL_ELAPSED_TIME), 0) > 0.05
        THEN 'MODERATE — some queuing. Monitor trend.'
        ELSE 'OK'
    END AS queue_status
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME       >= DATEADD('day', -14, CURRENT_DATE)
  AND WAREHOUSE_NAME    IS NOT NULL
  AND TOTAL_ELAPSED_TIME > 0
GROUP BY 1, 2
HAVING query_count > 20   -- ignore warehouses with very few queries
ORDER BY pct_time_queued DESC
LIMIT 30;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 2: Oversized warehouses (short queries on large warehouses)
-- ─────────────────────────────────────────────────────────────────────────────
-- If avg query time is < 5 seconds on an XL+ warehouse, you are likely paying
-- for capacity that does not meaningfully speed up the workload.
-- Test by downscaling one tier and comparing query times.
SELECT
    WAREHOUSE_NAME,
    WAREHOUSE_SIZE,
    COUNT(*)                                                    AS query_count,
    ROUND(AVG(TOTAL_ELAPSED_TIME / 1000.0), 1)                  AS avg_elapsed_seconds,
    ROUND(MEDIAN(TOTAL_ELAPSED_TIME / 1000.0), 1)               AS median_elapsed_seconds,
    ROUND(MAX(TOTAL_ELAPSED_TIME / 1000.0), 1)                  AS max_elapsed_seconds,
    CASE
        WHEN AVG(TOTAL_ELAPSED_TIME) < 2000
         AND WAREHOUSE_SIZE IN ('X-Large', '2X-Large', '3X-Large', '4X-Large')
        THEN 'LIKELY OVERSIZED — avg < 2s on large warehouse. Test downscaling.'
        WHEN AVG(TOTAL_ELAPSED_TIME) < 5000
         AND WAREHOUSE_SIZE IN ('X-Large', '2X-Large', '3X-Large', '4X-Large')
        THEN 'REVIEW — avg < 5s on large warehouse.'
        ELSE 'OK'
    END AS sizing_flag
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME       >= DATEADD('day', -14, CURRENT_DATE)
  AND WAREHOUSE_NAME    IS NOT NULL
  AND EXECUTION_STATUS  = 'SUCCESS'
  AND TOTAL_ELAPSED_TIME > 0
  AND WAREHOUSE_SIZE    IS NOT NULL
GROUP BY 1, 2
HAVING query_count > 50
ORDER BY avg_elapsed_seconds ASC, WAREHOUSE_SIZE DESC
LIMIT 30;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 3: Spill to disk detection (queries exceeding memory)
-- ─────────────────────────────────────────────────────────────────────────────
-- When a query exceeds the warehouse's available memory, Snowflake spills
-- intermediate data to local disk (fast) or remote storage (slow).
-- High spill rates increase query duration and credit consumption.
-- Typical fix: increase warehouse size or optimize the query.
SELECT
    WAREHOUSE_NAME,
    WAREHOUSE_SIZE,
    COUNT(*)                                                                AS query_count,
    COUNT(CASE WHEN BYTES_SPILLED_TO_LOCAL_STORAGE  > 0 THEN 1 END)       AS queries_with_local_spill,
    COUNT(CASE WHEN BYTES_SPILLED_TO_REMOTE_STORAGE > 0 THEN 1 END)       AS queries_with_remote_spill,
    ROUND(COUNT(CASE WHEN BYTES_SPILLED_TO_REMOTE_STORAGE > 0 THEN 1 END)
        / NULLIF(COUNT(*), 0) * 100, 1)                                   AS pct_remote_spill,
    ROUND(SUM(BYTES_SPILLED_TO_REMOTE_STORAGE) / POWER(1024, 3), 2)       AS total_remote_spill_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -14, CURRENT_DATE)
  AND WAREHOUSE_NAME IS NOT NULL
  AND EXECUTION_STATUS = 'SUCCESS'
GROUP BY 1, 2
HAVING queries_with_remote_spill > 0
ORDER BY pct_remote_spill DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 4: Multi-cluster warehouse utilization
-- ─────────────────────────────────────────────────────────────────────────────
-- For multi-cluster warehouses, check how often clusters are actually scaling up.
-- If a warehouse almost never uses more than 1 cluster, multi-cluster may not
-- justify its higher potential cost.
SELECT
    WAREHOUSE_NAME,
    DATE(START_TIME)                                           AS usage_date,
    MAX(CLUSTER_NUMBER)                                        AS max_clusters_used,
    COUNT(DISTINCT CLUSTER_NUMBER)                             AS distinct_clusters,
    COUNT(*)                                                   AS query_count
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
  AND CLUSTER_NUMBER IS NOT NULL
  AND WAREHOUSE_NAME IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 5: Query compilation time vs execution time (metadata-heavy queries)
-- ─────────────────────────────────────────────────────────────────────────────
-- Queries with very long compilation times relative to execution may indicate
-- overly complex views, deep chains of CTEs, or metadata-heavy operations.
-- High compilation time consumes cloud services credits.
SELECT
    WAREHOUSE_NAME,
    QUERY_TYPE,
    COUNT(*)                                                        AS query_count,
    ROUND(AVG(COMPILATION_TIME    / 1000.0), 2)                     AS avg_compile_seconds,
    ROUND(AVG(EXECUTION_TIME      / 1000.0), 2)                     AS avg_execute_seconds,
    ROUND(AVG(TOTAL_ELAPSED_TIME  / 1000.0), 2)                     AS avg_total_seconds,
    ROUND(AVG(COMPILATION_TIME)
        / NULLIF(AVG(TOTAL_ELAPSED_TIME), 0) * 100, 1)              AS pct_time_compiling
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_DATE)
  AND WAREHOUSE_NAME IS NOT NULL
  AND EXECUTION_STATUS = 'SUCCESS'
  AND TOTAL_ELAPSED_TIME > 1000  -- > 1 second queries
GROUP BY 1, 2
HAVING pct_time_compiling > 20   -- compilation > 20% of total time
ORDER BY pct_time_compiling DESC
LIMIT 20;
