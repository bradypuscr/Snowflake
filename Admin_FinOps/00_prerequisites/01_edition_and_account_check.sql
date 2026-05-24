/*
================================================================================
  FILE: 00_prerequisites/01_edition_and_account_check.sql
  PURPOSE: Verify account identity, edition features, and ACCOUNT_USAGE access
           before running any other playbook scripts.
  REQUIRES: Any role with IMPORTED PRIVILEGES on SNOWFLAKE database,
            or ACCOUNTADMIN for full output.
  SAFE TO RUN: Yes — read-only queries only.
================================================================================
*/

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1: Account identity
-- ─────────────────────────────────────────────────────────────────────────────

-- Basic account info. Record these values — you will need them when opening
-- support tickets or when referencing accounts in ORGANIZATION_USAGE queries.
SELECT
    CURRENT_ACCOUNT()          AS account_locator,
    CURRENT_ORGANIZATION_NAME() AS organization_name,
    CURRENT_REGION()           AS region,
    CURRENT_VERSION()          AS snowflake_version,
    CURRENT_USER()             AS current_user,
    CURRENT_ROLE()             AS current_role,
    CURRENT_WAREHOUSE()        AS current_warehouse;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2: Edition detection
-- ─────────────────────────────────────────────────────────────────────────────

-- Snowflake does not expose the account edition in a simple SELECT.
-- The most reliable method is to attempt to query an Enterprise-only view.
-- If this returns a result, you are on Enterprise or higher.
-- If it raises "Object does not exist", you are on Standard.

-- NOTE: Run each block separately and observe whether it succeeds or errors.

-- Test 1: Search Optimization History (Enterprise+ only)
SELECT 'SEARCH_OPTIMIZATION_HISTORY accessible — Enterprise or higher' AS edition_signal
FROM SNOWFLAKE.ACCOUNT_USAGE.SEARCH_OPTIMIZATION_HISTORY
LIMIT 1;

-- Test 2: Materialized View Refresh History (Enterprise+ only)
SELECT 'MATERIALIZED_VIEW_REFRESH_HISTORY accessible — Enterprise or higher' AS edition_signal
FROM SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY
LIMIT 1;

-- If both tests fail, your account is Standard edition.
-- Document your edition here for team reference:
--   Account edition: [ Standard | Enterprise | Business Critical ]


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3: ACCOUNT_USAGE access check
-- ─────────────────────────────────────────────────────────────────────────────

-- Verify that your current role can read ACCOUNT_USAGE views.
-- If this errors, run 02_roles_and_privileges.sql as ACCOUNTADMIN first.

SELECT
    COUNT(*)                  AS rows_in_last_7_days,
    MIN(START_TIME)           AS earliest_record,
    MAX(START_TIME)           AS latest_record,
    DATEDIFF('hour', MAX(START_TIME), CURRENT_TIMESTAMP()) AS approx_lag_hours
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_DATE);

-- Expected: lag_hours should be < 3 for WAREHOUSE_METERING_HISTORY.
-- If lag is much higher, ACCOUNT_USAGE may be initializing (can take 12-24 hours
-- on a newly created account before historical data is populated).


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4: ORGANIZATION_USAGE access check
-- ─────────────────────────────────────────────────────────────────────────────

-- This requires the ORGADMIN role. Switch to it if you have it,
-- then run this block. If you do not have ORGADMIN, skip this section
-- and coordinate with your cloud team.

-- USE ROLE ORGADMIN;  -- Uncomment if you have ORGADMIN

SELECT
    COUNT(DISTINCT ACCOUNT_NAME) AS accounts_visible,
    MIN(USAGE_DATE)              AS earliest_date,
    MAX(USAGE_DATE)              AS latest_date,
    DATEDIFF('hour', MAX(USAGE_DATE), CURRENT_DATE) AS approx_lag_days
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY;

-- Expected: Multiple accounts visible if you are in a multi-account org.
-- Lag for ORGANIZATION_USAGE is typically up to 72 hours (3 days).


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5: Current credit baseline
-- ─────────────────────────────────────────────────────────────────────────────

-- Record current monthly spend as your baseline before making any changes.
-- Compare against this after implementing governance controls.

SELECT
    DATE_TRUNC('month', USAGE_DATE)     AS month,
    SERVICE_TYPE,
    ROUND(SUM(CREDITS_USED), 2)         AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= DATEADD('month', -3, DATE_TRUNC('month', CURRENT_DATE))
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;

-- Save this output. It is your FinOps starting point.


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 6: Existing resource monitors and budgets
-- ─────────────────────────────────────────────────────────────────────────────

-- Check whether any resource monitors already exist before creating new ones.
-- Creating a monitor with the same name will fail or overwrite unexpectedly.
SHOW RESOURCE MONITORS;

-- Check existing budgets (requires SNOWFLAKE.CORE privilege).
-- If this errors, run the privilege grants in 02_roles_and_privileges.sql first.
SHOW BUDGETS IN ACCOUNT;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 7: ACCOUNT_USAGE view inventory
-- ─────────────────────────────────────────────────────────────────────────────

-- List all views available in ACCOUNT_USAGE.
-- Useful for discovering new views added in recent Snowflake releases
-- that may not yet be in this playbook.
SHOW VIEWS IN SCHEMA SNOWFLAKE.ACCOUNT_USAGE;

-- After running, compare the view list against 08_maintenance/DOCUMENTATION_WATCH.md
-- to identify any new views worth adding to the playbook.
