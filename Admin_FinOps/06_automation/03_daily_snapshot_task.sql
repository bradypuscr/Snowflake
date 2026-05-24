/*
================================================================================
  FILE: 06_automation/03_daily_snapshot_task.sql
  PURPOSE: Snowflake Task DAG for daily cost data collection.
           Runs warehouse catalog refresh, cost snapshot, and idle tracking.
  REQUIRES: FINOPS_ADMIN role with EXECUTE TASK privilege
            FINOPS database must exist (01_finops_schema_setup.sql)
            Procedure must exist (02_warehouse_catalog_proc.sql)
  SCHEDULE: Daily at 07:00 UTC (adjust to your timezone)
================================================================================

  TASK DAG STRUCTURE:
  ────────────────────
  FINOPS_DAILY_ROOT_TASK       ← Root task, triggers on schedule
  ├── FINOPS_WAREHOUSE_CATALOG_TASK  ← After root: refresh warehouse config
  ├── FINOPS_COST_SNAPSHOT_TASK      ← After root: snapshot yesterday's costs
  └── FINOPS_IDLE_CHECK_TASK         ← After root: update idle tracking table

  All child tasks are triggered by the root completing successfully.
  Each child runs independently (no dependency between children).
*/

USE ROLE FINOPS_ADMIN;
USE WAREHOUSE FINOPS_WH;
USE DATABASE FINOPS;


-- ─────────────────────────────────────────────────────────────────────────────
-- PRIVILEGE SETUP (run as ACCOUNTADMIN if FINOPS_ADMIN doesn't have EXECUTE TASK)
-- ─────────────────────────────────────────────────────────────────────────────
-- USE ROLE ACCOUNTADMIN;
-- GRANT EXECUTE TASK ON ACCOUNT TO ROLE FINOPS_ADMIN;
-- GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE FINOPS_ADMIN;
-- USE ROLE FINOPS_ADMIN;


-- ─────────────────────────────────────────────────────────────────────────────
-- ROOT TASK: Trigger on schedule, no SQL payload (orchestrator only)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TASK FINOPS.UTILS.FINOPS_DAILY_ROOT_TASK
    WAREHOUSE   = FINOPS_WH
    SCHEDULE    = 'USING CRON 0 7 * * * UTC'   -- 07:00 UTC daily; adjust as needed
    COMMENT     = 'Root task for daily FinOps data collection DAG. No payload — triggers child tasks.'
AS
    SELECT 'FinOps daily collection started: ' || CURRENT_TIMESTAMP()::STRING;


-- ─────────────────────────────────────────────────────────────────────────────
-- CHILD TASK 1: Refresh warehouse catalog (solve SHOW WAREHOUSES session problem)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TASK FINOPS.UTILS.FINOPS_WAREHOUSE_CATALOG_TASK
    WAREHOUSE   = FINOPS_WH
    AFTER       FINOPS.UTILS.FINOPS_DAILY_ROOT_TASK
    COMMENT     = 'Calls REFRESH_WAREHOUSE_CATALOG procedure to update FINOPS.RAW.WAREHOUSE_CATALOG.'
AS
    CALL FINOPS.UTILS.REFRESH_WAREHOUSE_CATALOG();


-- ─────────────────────────────────────────────────────────────────────────────
-- CHILD TASK 2: Daily cost snapshot
-- ─────────────────────────────────────────────────────────────────────────────
-- Snapshots YESTERDAY's costs (ACCOUNT_USAGE lags up to 3 hours, so pulling
-- yesterday at 07:00 UTC ensures the data is complete).
CREATE OR REPLACE TASK FINOPS.UTILS.FINOPS_COST_SNAPSHOT_TASK
    WAREHOUSE   = FINOPS_WH
    AFTER       FINOPS.UTILS.FINOPS_DAILY_ROOT_TASK
    COMMENT     = 'Snapshots yesterday warehouse costs with tag attribution into FINOPS.RAW.DAILY_COST_SNAPSHOT.'
AS
    MERGE INTO FINOPS.RAW.DAILY_COST_SNAPSHOT AS target
    USING (
        SELECT
            DATE(w.START_TIME)                            AS snapshot_date,
            w.WAREHOUSE_NAME,
            t_cc.TAG_VALUE                                AS cost_center,
            t_env.TAG_VALUE                               AS environment,
            ROUND(SUM(w.CREDITS_USED_COMPUTE), 8)         AS credits_compute,
            ROUND(SUM(w.CREDITS_USED_CLOUD_SERVICES), 8)  AS credits_cloud_svc,
            ROUND(SUM(w.CREDITS_USED), 8)                 AS credits_total
        FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
        LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t_cc
            ON  t_cc.OBJECT_NAME   = w.WAREHOUSE_NAME
            AND t_cc.OBJECT_DOMAIN = 'WAREHOUSE'
            AND t_cc.TAG_NAME      = 'COST_CENTER'
        LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t_env
            ON  t_env.OBJECT_NAME   = w.WAREHOUSE_NAME
            AND t_env.OBJECT_DOMAIN = 'WAREHOUSE'
            AND t_env.TAG_NAME      = 'ENVIRONMENT'
        WHERE DATE(w.START_TIME) = CURRENT_DATE - 1   -- yesterday only
        GROUP BY 1, 2, 3, 4
    ) AS source
    ON  target.snapshot_date    = source.snapshot_date
    AND target.warehouse_name   = source.WAREHOUSE_NAME
    WHEN MATCHED THEN UPDATE SET
        cost_center     = source.cost_center,
        environment     = source.environment,
        credits_compute = source.credits_compute,
        credits_cloud_svc = source.credits_cloud_svc,
        credits_total   = source.credits_total,
        created_at      = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        snapshot_date, warehouse_name, cost_center, environment,
        credits_compute, credits_cloud_svc, credits_total, created_at
    ) VALUES (
        source.snapshot_date, source.WAREHOUSE_NAME, source.cost_center, source.environment,
        source.credits_compute, source.credits_cloud_svc, source.credits_total, CURRENT_TIMESTAMP()
    );


-- ─────────────────────────────────────────────────────────────────────────────
-- CHILD TASK 3: Update idle warehouse tracking
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TASK FINOPS.UTILS.FINOPS_IDLE_CHECK_TASK
    WAREHOUSE   = FINOPS_WH
    AFTER       FINOPS.UTILS.FINOPS_DAILY_ROOT_TASK
    COMMENT     = 'Updates FINOPS.RAW.WAREHOUSE_LAST_ACCESS with query activity from the last 7 days.'
AS
    MERGE INTO FINOPS.RAW.WAREHOUSE_LAST_ACCESS AS target
    USING (
        SELECT
            WAREHOUSE_NAME,
            MAX(DATE(START_TIME))   AS last_query_date,
            COUNT(*)                AS query_count_7d
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE START_TIME >= DATEADD('day', -7, CURRENT_DATE)
          AND WAREHOUSE_NAME IS NOT NULL
        GROUP BY 1
    ) AS source
    ON UPPER(target.warehouse_name) = UPPER(source.WAREHOUSE_NAME)
    WHEN MATCHED THEN UPDATE SET
        last_query_date = source.last_query_date,
        query_count_7d  = source.query_count_7d,
        last_updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (warehouse_name, last_query_date, query_count_7d)
    VALUES (source.WAREHOUSE_NAME, source.last_query_date, source.query_count_7d);


-- ─────────────────────────────────────────────────────────────────────────────
-- ENABLE ALL TASKS
-- ─────────────────────────────────────────────────────────────────────────────
-- Tasks are created in SUSPENDED state. Enable child tasks first, then root.
ALTER TASK FINOPS.UTILS.FINOPS_WAREHOUSE_CATALOG_TASK RESUME;
ALTER TASK FINOPS.UTILS.FINOPS_COST_SNAPSHOT_TASK     RESUME;
ALTER TASK FINOPS.UTILS.FINOPS_IDLE_CHECK_TASK        RESUME;
ALTER TASK FINOPS.UTILS.FINOPS_DAILY_ROOT_TASK        RESUME;   -- enable root last


-- ─────────────────────────────────────────────────────────────────────────────
-- MONITOR TASK RUNS
-- ─────────────────────────────────────────────────────────────────────────────

-- View recent task run history (TASK_HISTORY has up to 7 days of data):
SELECT
    NAME,
    STATE,
    SCHEDULED_TIME,
    COMPLETED_TIME,
    ERROR_CODE,
    ERROR_MESSAGE,
    RETURN_VALUE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('day', -3, CURRENT_TIMESTAMP()),
    TASK_NAME => 'FINOPS_DAILY_ROOT_TASK'
))
ORDER BY SCHEDULED_TIME DESC;

-- Check if any child tasks have errors:
SELECT NAME, STATE, ERROR_MESSAGE, COMPLETED_TIME
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('day', -3, CURRENT_TIMESTAMP())
))
WHERE NAME LIKE 'FINOPS_%'
  AND STATE = 'FAILED'
ORDER BY COMPLETED_TIME DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- DISABLE ALL TASKS (run when maintenance or troubleshooting)
-- ─────────────────────────────────────────────────────────────────────────────
-- Suspend root first to stop the schedule, then children.
/*
ALTER TASK FINOPS.UTILS.FINOPS_DAILY_ROOT_TASK        SUSPEND;
ALTER TASK FINOPS.UTILS.FINOPS_WAREHOUSE_CATALOG_TASK SUSPEND;
ALTER TASK FINOPS.UTILS.FINOPS_COST_SNAPSHOT_TASK     SUSPEND;
ALTER TASK FINOPS.UTILS.FINOPS_IDLE_CHECK_TASK        SUSPEND;
*/
