/*
================================================================================
  FILE: 06_automation/01_finops_schema_setup.sql
  PURPOSE: Create the FINOPS database, schemas, and tables used by all
           automation tasks in this section.
  REQUIRES: SYSADMIN or ACCOUNTADMIN
  RUN ONCE: Re-running is safe (uses IF NOT EXISTS throughout).
================================================================================
*/

USE ROLE SYSADMIN;


-- ─────────────────────────────────────────────────────────────────────────────
-- DATABASE AND SCHEMAS
-- ─────────────────────────────────────────────────────────────────────────────

CREATE DATABASE IF NOT EXISTS FINOPS
    COMMENT = 'FinOps platform database. Stores cost snapshots, warehouse catalog, and alerts.';

-- RAW: tables populated by tasks (warehouse catalog, daily snapshots)
CREATE SCHEMA IF NOT EXISTS FINOPS.RAW
    COMMENT = 'Raw data tables updated by Snowflake Tasks.';

-- REPORTS: pre-aggregated tables for reporting and internal billing
CREATE SCHEMA IF NOT EXISTS FINOPS.REPORTS
    COMMENT = 'Aggregated cost reports for stakeholder consumption.';

-- ALERTS: anomaly detection log and alert history
CREATE SCHEMA IF NOT EXISTS FINOPS.ALERTS
    COMMENT = 'Anomaly detection results and alert history.';

-- UTILS: stored procedures and utility objects
CREATE SCHEMA IF NOT EXISTS FINOPS.UTILS
    COMMENT = 'Stored procedures and helper functions for automation.';


-- ─────────────────────────────────────────────────────────────────────────────
-- WAREHOUSE CATALOG TABLE
-- ─────────────────────────────────────────────────────────────────────────────
-- Populated by 02_warehouse_catalog_proc.sql via a daily Task.
-- Solves the SHOW WAREHOUSES + RESULT_SCAN limitation in Tasks.
-- JOIN this table to WAREHOUSE_METERING_HISTORY instead of running SHOW WAREHOUSES.

CREATE TABLE IF NOT EXISTS FINOPS.RAW.WAREHOUSE_CATALOG (
    warehouse_name    STRING         NOT NULL,
    warehouse_size    STRING,
    auto_suspend      NUMBER,         -- seconds; 0 = never suspends
    warehouse_type    STRING,         -- STANDARD or SNOWPARK-OPTIMIZED
    scaling_policy    STRING,         -- STANDARD or ECONOMY (multi-cluster)
    min_cluster_count NUMBER,
    max_cluster_count NUMBER,
    owner_role        STRING,
    resource_monitor  STRING,         -- name of attached resource monitor, or 'null'
    snapshot_time     TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_warehouse_catalog PRIMARY KEY (warehouse_name)
)
COMMENT = 'Current warehouse configuration. Refreshed daily by FINOPS_WAREHOUSE_CATALOG_TASK.';


-- ─────────────────────────────────────────────────────────────────────────────
-- DAILY COST SNAPSHOT TABLE
-- ─────────────────────────────────────────────────────────────────────────────
-- Stores one row per warehouse per day for fast reporting without hitting
-- ACCOUNT_USAGE directly on every report query.

CREATE TABLE IF NOT EXISTS FINOPS.RAW.DAILY_COST_SNAPSHOT (
    snapshot_date     DATE           NOT NULL,
    warehouse_name    STRING         NOT NULL,
    cost_center       STRING,        -- from TAG_REFERENCES; NULL if untagged
    environment       STRING,        -- from TAG_REFERENCES
    credits_compute   NUMBER(18, 8),
    credits_cloud_svc NUMBER(18, 8),
    credits_total     NUMBER(18, 8),
    query_count       NUMBER,
    created_at        TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_daily_cost_snapshot PRIMARY KEY (snapshot_date, warehouse_name)
)
COMMENT = 'Daily warehouse compute cost per warehouse, tagged with cost center. Refreshed by FINOPS_COST_SNAPSHOT_TASK.';


-- ─────────────────────────────────────────────────────────────────────────────
-- LAST ACCESS TRACKING TABLE
-- ─────────────────────────────────────────────────────────────────────────────
-- Maintained daily to provide fast idle warehouse detection without
-- the 90-day QUERY_HISTORY full scan.

CREATE TABLE IF NOT EXISTS FINOPS.RAW.WAREHOUSE_LAST_ACCESS (
    warehouse_name    STRING         NOT NULL,
    last_query_date   DATE,
    query_count_7d    NUMBER,        -- queries in the last 7 days (rolling)
    last_updated_at   TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_wh_last_access PRIMARY KEY (warehouse_name)
)
COMMENT = 'Last query date per warehouse. Updated daily by FINOPS_IDLE_CHECK_TASK.';


-- ─────────────────────────────────────────────────────────────────────────────
-- ANOMALY LOG TABLE
-- ─────────────────────────────────────────────────────────────────────────────
-- Records anomaly detection results. Useful for tracking false-positive rates
-- and understanding alert frequency over time.

CREATE TABLE IF NOT EXISTS FINOPS.ALERTS.ANOMALY_LOG (
    log_id            NUMBER AUTOINCREMENT PRIMARY KEY,
    detected_at       TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP(),
    period_type       STRING,        -- 'weekly', 'daily'
    period_start      DATE,
    scope             STRING,        -- 'account', warehouse name, or service type
    metric            STRING,        -- 'warehouse_compute', 'serverless', 'storage'
    observed_value    NUMBER(18, 4),
    baseline_avg      NUMBER(18, 4),
    z_score           NUMBER(8, 4),
    alert_sent        BOOLEAN        DEFAULT FALSE,
    notes             STRING
)
COMMENT = 'Log of all anomaly detections, whether or not an alert was sent.';


-- ─────────────────────────────────────────────────────────────────────────────
-- ORGANIZATION USAGE CACHE (optional — for non-ORGADMIN access to org data)
-- ─────────────────────────────────────────────────────────────────────────────
-- Populated by a Task running under ORGADMIN. Other roles can query this table.
-- See 03_cost_reports/06_multi_account.sql for the refresh pattern.

CREATE TABLE IF NOT EXISTS FINOPS.REPORTS.ORG_USAGE_DAILY (
    USAGE_DATE          DATE,
    ACCOUNT_LOCATOR     STRING,
    ACCOUNT_NAME        STRING,
    ORGANIZATION_NAME   STRING,
    CURRENCY            STRING,
    USAGE_IN_CURRENCY   NUMBER(18, 6),
    USAGE               NUMBER(18, 6),
    USAGE_TYPE          STRING,
    RATING_TYPE         STRING,
    SERVICE_TYPE        STRING,
    BALANCE_SOURCE      STRING,
    CONTRACT_NUMBER     STRING,
    REGION              STRING,
    SNOWFLAKE_REGION    STRING,
    EDITION             STRING,
    loaded_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Cache of ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY for non-ORGADMIN access. Refresh requires ORGADMIN Task.';


-- ─────────────────────────────────────────────────────────────────────────────
-- DEDICATED WAREHOUSE FOR FINOPS TASKS
-- ─────────────────────────────────────────────────────────────────────────────
-- Tasks need a warehouse. Use an XS warehouse — FinOps queries are metadata-heavy
-- and do not benefit from a large warehouse. Auto-suspend at 60 seconds.

CREATE WAREHOUSE IF NOT EXISTS FINOPS_WH
    WAREHOUSE_SIZE  = 'X-Small'
    AUTO_SUSPEND    = 60
    AUTO_RESUME     = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Dedicated warehouse for FinOps tasks and reporting queries.'
;

-- Apply tags to the FinOps warehouse itself (it should appear in your own reports)
-- ALTER WAREHOUSE FINOPS_WH SET TAG GOVERNANCE.TAGS.COST_CENTER = 'platform',
--                                    GOVERNANCE.TAGS.ENVIRONMENT = 'prod';


-- ─────────────────────────────────────────────────────────────────────────────
-- GRANT ACCESS TO FINOPS ROLES (from 00_prerequisites/02_roles_and_privileges.sql)
-- ─────────────────────────────────────────────────────────────────────────────
GRANT USAGE  ON DATABASE FINOPS TO ROLE FINOPS_ADMIN;
GRANT USAGE  ON DATABASE FINOPS TO ROLE FINOPS_VIEWER;
GRANT USAGE  ON ALL SCHEMAS IN DATABASE FINOPS TO ROLE FINOPS_ADMIN;
GRANT USAGE  ON ALL SCHEMAS IN DATABASE FINOPS TO ROLE FINOPS_VIEWER;
GRANT SELECT ON ALL TABLES IN DATABASE FINOPS TO ROLE FINOPS_ADMIN;
GRANT SELECT ON ALL TABLES IN DATABASE FINOPS TO ROLE FINOPS_VIEWER;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN DATABASE FINOPS TO ROLE FINOPS_ADMIN;

-- Future objects
GRANT SELECT ON FUTURE TABLES IN DATABASE FINOPS TO ROLE FINOPS_VIEWER;
GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN DATABASE FINOPS TO ROLE FINOPS_ADMIN;

-- Warehouse access for tasks
GRANT USAGE ON WAREHOUSE FINOPS_WH TO ROLE FINOPS_ADMIN;
