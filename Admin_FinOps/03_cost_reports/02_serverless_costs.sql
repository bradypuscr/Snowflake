/*
================================================================================
  FILE: 03_cost_reports/02_serverless_costs.sql
  PURPOSE: Serverless compute cost reports across all ACCOUNT_USAGE views.
           Snowpipe, Automatic Clustering, Search Optimization, Materialized
           Views, Serverless Tasks, and Database Replication.
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
  NOTE:     Search Optimization and Materialized Views require Enterprise Edition.
            Queries for those views will error on Standard Edition — skip them.
  ACCURACY: Exact by service type. Attribution by team is partial (schema-level).
================================================================================
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 1: All serverless costs — last 30 days (UNION overview)
-- ─────────────────────────────────────────────────────────────────────────────
WITH serverless_costs AS (

    SELECT 'Snowpipe'            AS service,
           PIPE_NAME             AS object_name,
           SUM(CREDITS_USED)     AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
    WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
    GROUP BY 2

    UNION ALL

    SELECT 'Auto Clustering',    TABLE_NAME,    SUM(CREDITS_USED)
    FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
    WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
    GROUP BY 2

    UNION ALL

    -- Enterprise Edition only. Comment out if on Standard Edition.
    SELECT 'Search Optimization', TABLE_NAME,   SUM(CREDITS_USED)
    FROM SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY
    WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
    GROUP BY 2

    UNION ALL

    -- Enterprise Edition only. Comment out if on Standard Edition.
    SELECT 'Materialized Views',  TABLE_NAME,   SUM(CREDITS_USED)
    FROM SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY
    WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
    GROUP BY 2

    UNION ALL

    SELECT 'Serverless Tasks',    TASK_NAME,    SUM(CREDITS_USED)
    FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
    WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
    GROUP BY 2

    UNION ALL

    SELECT 'Replication',         DATABASE_NAME, SUM(CREDITS_USED)
    FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_REPLICATION_USAGE_HISTORY
    WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
    GROUP BY 2
)
SELECT
    service,
    ROUND(SUM(credits), 4) AS total_credits,
    COUNT(DISTINCT object_name) AS object_count
FROM serverless_costs
GROUP BY 1
ORDER BY 2 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 2: Snowpipe — top pipes by cost (last 30 days)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    PIPE_NAME,
    PIPE_SCHEMA,
    ROUND(SUM(CREDITS_USED), 4)           AS credits_used,
    SUM(FILES_INSERTED)                   AS files_inserted,
    SUM(BYTES_INSERTED)                   AS bytes_inserted,
    -- Cost per GB loaded — useful for evaluating whether Snowpipe is efficient
    ROUND(SUM(CREDITS_USED)
        / NULLIF(SUM(BYTES_INSERTED) / POWER(1024, 3), 0), 4) AS credits_per_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2
ORDER BY 3 DESC
LIMIT 20;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 3: Automatic Clustering — cost vs reclustering activity
-- ─────────────────────────────────────────────────────────────────────────────
-- Tables with high clustering credits but declining reclustering activity
-- may be over-clustered or clustered on the wrong key.
SELECT
    TABLE_NAME,
    TABLE_SCHEMA,
    TABLE_DATABASE,
    ROUND(SUM(CREDITS_USED), 4)        AS clustering_credits,
    SUM(NUM_BYTES_RECLUSTERED)         AS bytes_reclustered,
    SUM(NUM_ROWS_RECLUSTERED)          AS rows_reclustered,
    -- If bytes_reclustered is declining while credits are stable, the table
    -- may have stabilized or the clustering key may need revisiting.
    MIN(DATE(START_TIME))              AS first_day,
    MAX(DATE(START_TIME))              AS last_day
FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2, 3
ORDER BY 4 DESC
LIMIT 20;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 4: Search Optimization — tables with active spend (Enterprise only)
-- ─────────────────────────────────────────────────────────────────────────────
-- NOTE: TABLE_NAME in this view is a system-generated label such as
-- "SEARCH OPTIMIZATION ON TABLE_ID: 1234". It is not the actual table name.
-- Use the SHOW TABLES approach below to resolve IDs to actual names.

-- Step 1: Find tables with Search Optimization enabled
SHOW TABLES IN ACCOUNT;
SELECT
    "name"           AS table_name,
    "database_name",
    "schema_name",
    "search_optimization"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "search_optimization" = 'ON';

-- Step 2: Check their recent credit consumption
SELECT
    TABLE_NAME AS system_label,  -- system-generated, not the real table name
    ROUND(SUM(CREDITS_USED), 4) AS credits_30d
FROM SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1
ORDER BY 2 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 5: Serverless tasks — cost per task and execution frequency
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    TASK_NAME,
    SCHEMA_NAME,
    DATABASE_NAME,
    ROUND(SUM(CREDITS_USED), 6)          AS total_credits,
    COUNT(*)                             AS execution_count,
    -- Average cost per execution — anomalies here suggest task logic changes
    ROUND(AVG(CREDITS_USED), 6)          AS avg_credits_per_run,
    MAX(CREDITS_USED)                    AS max_credits_single_run
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
WHERE START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2, 3
ORDER BY 4 DESC
LIMIT 25;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 6: Weekly serverless spend trend — last 12 weeks
-- ─────────────────────────────────────────────────────────────────────────────
WITH weekly_serverless AS (
    SELECT DATE_TRUNC('week', START_TIME) AS week_start, 'Snowpipe' AS service, SUM(CREDITS_USED) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
    WHERE START_TIME >= DATEADD('week', -12, CURRENT_DATE) GROUP BY 1

    UNION ALL
    SELECT DATE_TRUNC('week', START_TIME), 'Auto Clustering', SUM(CREDITS_USED)
    FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
    WHERE START_TIME >= DATEADD('week', -12, CURRENT_DATE) GROUP BY 1

    UNION ALL
    SELECT DATE_TRUNC('week', START_TIME), 'Serverless Tasks', SUM(CREDITS_USED)
    FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
    WHERE START_TIME >= DATEADD('week', -12, CURRENT_DATE) GROUP BY 1
)
SELECT
    week_start,
    service,
    ROUND(SUM(credits), 2) AS weekly_credits
FROM weekly_serverless
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;
