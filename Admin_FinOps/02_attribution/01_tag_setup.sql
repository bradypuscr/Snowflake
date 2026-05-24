/*
================================================================================
  FILE: 02_attribution/01_tag_setup.sql
  PURPOSE: Reference guide for tag taxonomy design, creation, application,
           and auditing. Companion to 01_governance/03_tag_enforcement.sql.
  REQUIRES: FINOPS_ADMIN role with APPLY TAG privilege
  DOCUMENTATION: https://docs.snowflake.com/en/user-guide/object-tagging
================================================================================

  TAGGING STRATEGY:
  ─────────────────
  Tags work best with a simple, agreed-upon taxonomy. More tags = more
  granularity but also more maintenance. A minimal effective set:

    COST_CENTER  — which team/business unit owns this? (required)
    TEAM_OWNER   — who to contact when costs spike? (required)
    ENVIRONMENT  — prod/dev/staging (required for filtering)
    PROJECT      — optional, for project-level chargebacks

  Apply tags at the highest useful level:
  • WAREHOUSE  → direct compute attribution
  • DATABASE   → propagates to schemas and tables (serverless, storage)
  • SCHEMA     → narrower than database, useful for multi-team databases
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1: Verify existing tags
-- ─────────────────────────────────────────────────────────────────────────────
-- Before creating tags, check what already exists to avoid conflicts.

SHOW TAGS IN ACCOUNT;

-- See all tags currently applied across the account:
SELECT
    OBJECT_DATABASE,
    OBJECT_SCHEMA,
    OBJECT_NAME,
    DOMAIN,
    TAG_DATABASE,
    TAG_SCHEMA,
    TAG_NAME,
    TAG_VALUE
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
ORDER BY DOMAIN, OBJECT_NAME, TAG_NAME;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2: Create tags (if not already done in 01_governance/03_tag_enforcement.sql)
-- ─────────────────────────────────────────────────────────────────────────────

USE SCHEMA GOVERNANCE.TAGS;  -- Use the central tag schema from Section 1 of governance

-- If GOVERNANCE schema does not exist yet, create it:
-- CREATE DATABASE IF NOT EXISTS GOVERNANCE;
-- CREATE SCHEMA IF NOT EXISTS GOVERNANCE.TAGS;

CREATE TAG IF NOT EXISTS COST_CENTER
    ALLOWED_VALUES 'analytics', 'data_engineering', 'ml_platform',
                   'finance', 'shared_infra', 'platform'
    COMMENT = 'Business unit responsible for costs. Required on all warehouses.';

CREATE TAG IF NOT EXISTS TEAM_OWNER
    COMMENT = 'Team contact. Use email alias (e.g., de-team@company.com).';

CREATE TAG IF NOT EXISTS ENVIRONMENT
    ALLOWED_VALUES 'prod', 'staging', 'dev', 'sandbox', 'ci'
    COMMENT = 'Deployment environment.';

CREATE TAG IF NOT EXISTS PROJECT
    COMMENT = 'Project or initiative. Optional. Used for project-level chargebacks.';


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3: Bulk tagging script template
-- ─────────────────────────────────────────────────────────────────────────────
-- Run SHOW WAREHOUSES, export the results, then build ALTER statements.
-- This template shows the pattern — replace with your actual object names.

-- Warehouses
ALTER WAREHOUSE ANALYTICS_WH    SET TAG GOVERNANCE.TAGS.COST_CENTER = 'analytics',
                                         GOVERNANCE.TAGS.TEAM_OWNER  = 'analytics@company.com',
                                         GOVERNANCE.TAGS.ENVIRONMENT = 'prod';

ALTER WAREHOUSE ANALYTICS_DEV_WH SET TAG GOVERNANCE.TAGS.COST_CENTER = 'analytics',
                                          GOVERNANCE.TAGS.TEAM_OWNER  = 'analytics@company.com',
                                          GOVERNANCE.TAGS.ENVIRONMENT = 'dev';

ALTER WAREHOUSE DE_WH            SET TAG GOVERNANCE.TAGS.COST_CENTER = 'data_engineering',
                                         GOVERNANCE.TAGS.TEAM_OWNER  = 'de@company.com',
                                         GOVERNANCE.TAGS.ENVIRONMENT = 'prod';

ALTER WAREHOUSE INGESTION_WH     SET TAG GOVERNANCE.TAGS.COST_CENTER = 'data_engineering',
                                         GOVERNANCE.TAGS.TEAM_OWNER  = 'de@company.com',
                                         GOVERNANCE.TAGS.ENVIRONMENT = 'prod';

ALTER WAREHOUSE ML_WH            SET TAG GOVERNANCE.TAGS.COST_CENTER = 'ml_platform',
                                         GOVERNANCE.TAGS.TEAM_OWNER  = 'ml@company.com',
                                         GOVERNANCE.TAGS.ENVIRONMENT = 'prod';

ALTER WAREHOUSE SHARED_WH        SET TAG GOVERNANCE.TAGS.COST_CENTER = 'shared_infra',
                                         GOVERNANCE.TAGS.TEAM_OWNER  = 'platform@company.com',
                                         GOVERNANCE.TAGS.ENVIRONMENT = 'prod';

-- Databases (tag propagates to all schemas and tables within)
ALTER DATABASE ANALYTICS_DB      SET TAG GOVERNANCE.TAGS.COST_CENTER = 'analytics';
ALTER DATABASE ML_DB             SET TAG GOVERNANCE.TAGS.COST_CENTER = 'ml_platform';
ALTER DATABASE SHARED_DB         SET TAG GOVERNANCE.TAGS.COST_CENTER = 'shared_infra';


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4: Tag inheritance — what propagates and what does not
-- ─────────────────────────────────────────────────────────────────────────────
-- Snowflake tags propagate DOWN the hierarchy:
--   Account → Database → Schema → Table/View
-- They do NOT propagate UP.
--
-- A tag on a DATABASE applies to all schemas and tables within it.
-- A tag on a SCHEMA applies to all tables within that schema.
-- A tag on a TABLE does not affect the schema or database above it.
--
-- TAG_REFERENCES shows DIRECT tag application.
-- SYSTEM$GET_TAG() resolves INHERITED tags (looks up the hierarchy).
--
-- Example: verify that a table inherits its database's cost_center tag:
SELECT SYSTEM$GET_TAG(
    'GOVERNANCE.TAGS.COST_CENTER',
    'ANALYTICS_DB.PUBLIC.MY_TABLE',
    'TABLE'
) AS inherited_cost_center;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5: Untagged object audit
-- ─────────────────────────────────────────────────────────────────────────────

-- Untagged warehouses with non-zero spend in the last 30 days:
SELECT
    w.WAREHOUSE_NAME,
    ROUND(SUM(w.CREDITS_USED), 2) AS credits_30d,
    'MISSING COST_CENTER TAG'      AS action_needed
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
    ON  t.OBJECT_NAME   = w.WAREHOUSE_NAME
    AND t.OBJECT_DOMAIN = 'WAREHOUSE'
    AND t.TAG_NAME      = 'COST_CENTER'
WHERE w.START_TIME >= DATEADD('day', -30, CURRENT_DATE)
  AND t.TAG_VALUE IS NULL
GROUP BY 1
HAVING credits_30d > 0
ORDER BY 2 DESC;

-- Untagged databases (no cost_center at the database level):
SELECT
    db.DATABASE_NAME,
    ROUND(SUM(AVERAGE_DATABASE_BYTES) / POWER(1024, 3), 2) AS avg_active_gb,
    'MISSING COST_CENTER TAG'                               AS action_needed
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY db
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
    ON  t.OBJECT_NAME   = db.DATABASE_NAME
    AND t.OBJECT_DOMAIN = 'DATABASE'
    AND t.TAG_NAME      = 'COST_CENTER'
WHERE db.USAGE_DATE >= DATEADD('day', -7, CURRENT_DATE)
  AND t.TAG_VALUE IS NULL
GROUP BY 1
ORDER BY 2 DESC;
