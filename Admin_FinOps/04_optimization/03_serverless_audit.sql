/*
================================================================================
  FILE: 04_optimization/03_serverless_audit.sql
  PURPOSE: Audit serverless features to find ones that are running
           but no longer earning their cost: Search Optimization on
           unqueried tables, Auto-clustering on stable tables, idle Snowpipes.
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
  NOTE:     Search Optimization queries require Enterprise Edition.
================================================================================
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 1: Search Optimization — tables enabled but not recently queried
-- ─────────────────────────────────────────────────────────────────────────────
-- Search Optimization charges continuously regardless of query activity.
-- A table that has not been queried in 30+ days has no benefit from the index.

-- Step 1: Get all tables with Search Optimization enabled
SHOW TABLES IN ACCOUNT;

WITH so_tables AS (
    SELECT "name" AS table_name, "database_name", "schema_name"
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
    WHERE "search_optimization" = 'ON'
),
recent_queries AS (
    SELECT DISTINCT
        TABLE_NAME,
        DATABASE_NAME,
        SCHEMA_NAME
    FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
         LATERAL FLATTEN(input => BASE_OBJECTS_ACCESSED) obj
    WHERE QUERY_START_TIME >= DATEADD('day', -30, CURRENT_DATE)
      AND obj.value:objectDomain::STRING = 'Table'
)
SELECT
    so.database_name,
    so.schema_name,
    so.table_name,
    CASE
        WHEN rq.TABLE_NAME IS NULL THEN 'NO QUERIES IN 30 DAYS — candidate to disable'
        ELSE 'Active — keep enabled'
    END AS recommendation,
    -- Get recent SO cost (approximate — TABLE_NAME is a system label)
    ROUND(SUM(h.CREDITS_USED), 4) AS credits_30d
FROM so_tables so
LEFT JOIN recent_queries rq
    ON  UPPER(rq.TABLE_NAME)    = UPPER(so.table_name)
    AND UPPER(rq.DATABASE_NAME) = UPPER(so.database_name)
    AND UPPER(rq.SCHEMA_NAME)   = UPPER(so.schema_name)
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY h
    ON  h.START_TIME >= DATEADD('day', -30, CURRENT_DATE)
    -- Can't join by table name directly (SO history uses system labels), so aggregate all
GROUP BY 1, 2, 3, 4
ORDER BY recommendation DESC;

-- To disable Search Optimization on a table:
-- ALTER TABLE <database>.<schema>.<table> DROP SEARCH OPTIMIZATION;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 2: Auto-clustering — tables with declining reclustering activity
-- ─────────────────────────────────────────────────────────────────────────────
-- Auto-clustering is most valuable when a table has active DML that fragments
-- the clustering order. Once a table stabilizes (low DML), reclustering
-- activity and cost should decline naturally. If credits remain high despite
-- low reclustering output, the clustering key may be wrong.
WITH clustering_weekly AS (
    SELECT
        TABLE_NAME,
        TABLE_SCHEMA,
        TABLE_DATABASE,
        DATE_TRUNC('week', START_TIME)   AS week_start,
        SUM(CREDITS_USED)               AS weekly_credits,
        SUM(NUM_BYTES_RECLUSTERED)      AS bytes_reclustered,
        SUM(NUM_ROWS_RECLUSTERED)       AS rows_reclustered
    FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
    WHERE START_TIME >= DATEADD('week', -8, CURRENT_DATE)
    GROUP BY 1, 2, 3, 4
)
SELECT
    TABLE_DATABASE,
    TABLE_SCHEMA,
    TABLE_NAME,
    ROUND(SUM(weekly_credits), 4)                            AS total_credits_8w,
    ROUND(AVG(bytes_reclustered) / POWER(1024, 3), 2)        AS avg_weekly_gb_reclustered,
    -- Compare first 4 weeks vs last 4 weeks: is reclustering declining?
    ROUND(AVG(CASE WHEN week_start >= DATEADD('week', -4, CURRENT_DATE)
                   THEN bytes_reclustered END)
        / NULLIF(AVG(CASE WHEN week_start < DATEADD('week', -4, CURRENT_DATE)
                          THEN bytes_reclustered END), 0), 2) AS recent_vs_prior_ratio,
    CASE
        WHEN AVG(CASE WHEN week_start >= DATEADD('week', -4, CURRENT_DATE)
                      THEN bytes_reclustered END)
             / NULLIF(AVG(CASE WHEN week_start < DATEADD('week', -4, CURRENT_DATE)
                               THEN bytes_reclustered END), 0) < 0.2
        THEN 'DECLINING — table may be stable. Consider pausing clustering.'
        WHEN AVG(CASE WHEN week_start >= DATEADD('week', -4, CURRENT_DATE)
                      THEN bytes_reclustered END)
             / NULLIF(AVG(CASE WHEN week_start < DATEADD('week', -4, CURRENT_DATE)
                               THEN bytes_reclustered END), 0) < 0.5
        THEN 'REDUCING — monitor for another 4 weeks'
        ELSE 'ACTIVE'
    END AS clustering_trend
FROM clustering_weekly
GROUP BY 1, 2, 3
HAVING total_credits_8w > 0.1
ORDER BY clustering_trend DESC, total_credits_8w DESC;

-- To pause auto-clustering on a table:
-- ALTER TABLE <table> SUSPEND RECLUSTER;
-- To resume:
-- ALTER TABLE <table> RESUME RECLUSTER;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 3: Snowpipe — pipes with low throughput relative to cost
-- ─────────────────────────────────────────────────────────────────────────────
-- A pipe that costs a lot but loads few files or bytes may indicate:
-- - Frequent micro-file notifications (many small files, high overhead)
-- - Idle pipes that wake up for tiny loads
-- Consider batching files before staging, or switching to COPY INTO for low-volume loads.
SELECT
    PIPE_NAME,
    PIPE_SCHEMA,
    ROUND(SUM(CREDITS_USED), 4)                                         AS credits_30d,
    SUM(FILES_INSERTED)                                                 AS files_30d,
    ROUND(SUM(BYTES_INSERTED) / POWER(1024, 3), 2)                      AS gb_loaded_30d,
    ROUND(SUM(CREDITS_USED) / NULLIF(SUM(FILES_INSERTED), 0), 6)       AS credits_per_file,
    ROUND(SUM(CREDITS_USED)
        / NULLIF(SUM(BYTES_INSERTED) / POWER(1024, 3), 0), 4)          AS credits_per_gb,
    CASE
        WHEN SUM(FILES_INSERTED) > 0
         AND SUM(CREDITS_USED) / NULLIF(SUM(FILES_INSERTED), 0) > 0.01
        THEN 'HIGH COST PER FILE — consider batching or using COPY INTO'
        WHEN SUM(FILES_INSERTED) = 0
        THEN 'NO FILES LOADED — pipe may be idle or misconfigured'
        ELSE 'OK'
    END AS recommendation
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2
ORDER BY credits_30d DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 4: Serverless tasks — high cost per execution or low success rate
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    TASK_NAME,
    SCHEMA_NAME,
    DATABASE_NAME,
    COUNT(*)                                                            AS executions_30d,
    ROUND(SUM(CREDITS_USED), 6)                                         AS total_credits,
    ROUND(AVG(CREDITS_USED), 6)                                         AS avg_credits_per_run,
    ROUND(MAX(CREDITS_USED), 6)                                         AS max_credits_single_run,
    -- If max >> avg, the task occasionally runs a much heavier workload
    ROUND(MAX(CREDITS_USED) / NULLIF(AVG(CREDITS_USED), 0), 1)         AS max_vs_avg_ratio,
    CASE
        WHEN MAX(CREDITS_USED) / NULLIF(AVG(CREDITS_USED), 0) > 10
        THEN 'REVIEW — occasional very expensive run. Check task logic for unbounded loops.'
        ELSE 'OK'
    END AS flag
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2, 3
HAVING total_credits > 0.001
ORDER BY total_credits DESC
LIMIT 25;
