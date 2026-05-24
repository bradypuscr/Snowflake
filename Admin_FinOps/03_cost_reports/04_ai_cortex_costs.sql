/*
================================================================================
  FILE: 03_cost_reports/04_ai_cortex_costs.sql
  PURPOSE: AI and Cortex cost tracking — account-level totals, per-user
           attribution for Cortex Code (Snowsight, CLI, and Desktop surfaces),
           and per-user limit management.
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
  KEY VIEWS: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
             SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY
             SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY
             SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY (verify availability)
================================================================================

  BILLING CATEGORIES IN METERING_DAILY_HISTORY:
  ───────────────────────────────────────────────
  SERVICE_TYPE values relevant to AI:
    'AI_SERVICES'          — Cortex function calls (AI_COMPLETE, SENTIMENT, etc.)
    'CORTEX_CODE'          — Cortex Code (CoCo) token consumption
    'CORTEX_AGENT'         — Cortex Agents (if enabled)

  CORTEX CODE SURFACES AND PARAMETERS:
  ──────────────────────────────────────
  Three surfaces, each with an independent daily credit limit parameter:
    CORTEX_CODE_SNOWSIGHT_DAILY_EST_CREDIT_LIMIT_PER_USER  — Snowsight UI
    CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER        — CLI (snow CLI / VS Code)
    CORTEX_CODE_DESKTOP_DAILY_EST_CREDIT_LIMIT_PER_USER    — Desktop application
  Default value: -1 (unlimited). Set to 0 to block access entirely.

  COLUMN NAMING — IMPORTANT:
  ───────────────────────────
  Cortex Code usage views use DIFFERENT column names from other usage views:
    USER_ID      (not USER_NAME — requires joining to USERS to resolve names)
    USAGE_TIME   (not START_TIME)
    TOKEN_CREDITS (not CREDITS_USED)
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 1: AI service totals — last 30 days by service type
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    SERVICE_TYPE,
    ROUND(SUM(CREDITS_USED), 4)   AS credits_30d,
    COUNT(DISTINCT USAGE_DATE)    AS active_days
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE)
  AND SERVICE_TYPE IN ('AI_SERVICES', 'CORTEX_CODE', 'CORTEX_AGENT',
                       'CORTEX_FINE_TUNING')  -- add new service types as they appear
GROUP BY 1
ORDER BY 2 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 2: AI spend trend — weekly last 12 weeks
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    DATE_TRUNC('week', USAGE_DATE)   AS week_start,
    SERVICE_TYPE,
    ROUND(SUM(CREDITS_USED), 4)      AS weekly_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= DATEADD('week', -12, CURRENT_DATE)
  AND SERVICE_TYPE IN ('AI_SERVICES', 'CORTEX_CODE', 'CORTEX_AGENT')
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 3: Cortex Code — Snowsight surface, by user (last 30 days)
-- ─────────────────────────────────────────────────────────────────────────────
-- NOTE: USER_ID is not USER_NAME. Join to ACCOUNT_USAGE.USERS for display name.
-- NOTE: Column names differ from other views: USER_ID, USAGE_TIME, TOKEN_CREDITS.
SELECT
    c.USER_ID,
    u.NAME             AS username,
    u.EMAIL,
    COUNT(*)           AS interaction_count,
    ROUND(SUM(c.TOKEN_CREDITS), 4) AS total_credits,
    -- Daily average — compare against the per-user limit to see who's close to cap
    ROUND(SUM(c.TOKEN_CREDITS)
        / NULLIF(COUNT(DISTINCT DATE(c.USAGE_TIME)), 0), 4) AS avg_credits_per_active_day
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY c
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.NAME = c.USER_ID
WHERE c.USAGE_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3
ORDER BY 5 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 4: Cortex Code — CLI surface, by user (last 30 days)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    c.USER_ID,
    u.NAME             AS username,
    u.EMAIL,
    COUNT(*)           AS interaction_count,
    ROUND(SUM(c.TOKEN_CREDITS), 4) AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY c
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.NAME = c.USER_ID
WHERE c.USAGE_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3
ORDER BY 5 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 5: Cortex Code — Desktop surface, by user (last 30 days)
-- ─────────────────────────────────────────────────────────────────────────────
-- ⚠️ Verify view availability: CORTEX_CODE_DESKTOP_USAGE_HISTORY
-- Run: SHOW VIEWS IN SCHEMA SNOWFLAKE.ACCOUNT_USAGE LIKE 'CORTEX_CODE%';
-- to confirm the view exists in your account version before running this query.
SELECT
    c.USER_ID,
    u.NAME             AS username,
    u.EMAIL,
    COUNT(*)           AS interaction_count,
    ROUND(SUM(c.TOKEN_CREDITS), 4) AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY c
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.NAME = c.USER_ID
WHERE c.USAGE_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3
ORDER BY 5 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 6: Cortex Code — combined across all three surfaces
-- ─────────────────────────────────────────────────────────────────────────────
-- Useful for a consolidated per-user AI coding cost view.
-- ⚠️ Comment out the DESKTOP section if that view is not yet available.
WITH all_surfaces AS (
    SELECT USER_ID, TOKEN_CREDITS, USAGE_TIME, 'Snowsight' AS surface
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY
    WHERE USAGE_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())

    UNION ALL
    SELECT USER_ID, TOKEN_CREDITS, USAGE_TIME, 'CLI'
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY
    WHERE USAGE_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())

    UNION ALL  -- Comment out if DESKTOP view is not available
    SELECT USER_ID, TOKEN_CREDITS, USAGE_TIME, 'Desktop'
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY
    WHERE USAGE_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
)
SELECT
    a.USER_ID,
    u.NAME                           AS username,
    ROUND(SUM(CASE WHEN surface = 'Snowsight' THEN TOKEN_CREDITS ELSE 0 END), 4) AS snowsight_credits,
    ROUND(SUM(CASE WHEN surface = 'CLI'       THEN TOKEN_CREDITS ELSE 0 END), 4) AS cli_credits,
    ROUND(SUM(CASE WHEN surface = 'Desktop'   THEN TOKEN_CREDITS ELSE 0 END), 4) AS desktop_credits,
    ROUND(SUM(TOKEN_CREDITS), 4)     AS total_credits
FROM all_surfaces a
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.NAME = a.USER_ID
GROUP BY 1, 2
ORDER BY total_credits DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION: Per-user credit limits (requires ACCOUNTADMIN or SYSADMIN)
-- ─────────────────────────────────────────────────────────────────────────────

-- View current account-level defaults (all surfaces):
SHOW PARAMETERS LIKE 'CORTEX_CODE%' IN ACCOUNT;

-- View overrides for a specific user:
SHOW PARAMETERS LIKE 'CORTEX_CODE%' IN USER <username>;

-- Set account-level defaults (applies to all users without a user-level override):
-- ALTER ACCOUNT SET CORTEX_CODE_SNOWSIGHT_DAILY_EST_CREDIT_LIMIT_PER_USER = 20;
-- ALTER ACCOUNT SET CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER       = 20;
-- ALTER ACCOUNT SET CORTEX_CODE_DESKTOP_DAILY_EST_CREDIT_LIMIT_PER_USER   = 20;

-- Set or override for a specific user:
-- ALTER USER <power_user>     SET CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER      = 50;
-- ALTER USER <restricted>     SET CORTEX_CODE_SNOWSIGHT_DAILY_EST_CREDIT_LIMIT_PER_USER = 0;
-- ALTER USER <desktop_heavy>  SET CORTEX_CODE_DESKTOP_DAILY_EST_CREDIT_LIMIT_PER_USER  = 30;

-- Reset a user to the account default:
-- ALTER USER <username> UNSET CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER;

-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 7: Users approaching or at their daily limit (last 7 days)
-- ─────────────────────────────────────────────────────────────────────────────
-- Replace 20 with your account-level limit to identify heavy users.
-- This query uses Snowsight surface as an example; repeat for CLI and Desktop.
SELECT
    DATE(c.USAGE_TIME)             AS usage_date,
    c.USER_ID,
    u.NAME                         AS username,
    ROUND(SUM(c.TOKEN_CREDITS), 4) AS daily_credits,
    -- Flag users using >= 80% of the daily limit
    CASE
        WHEN SUM(c.TOKEN_CREDITS) >= 20 * 1.0 THEN 'AT LIMIT'
        WHEN SUM(c.TOKEN_CREDITS) >= 20 * 0.8 THEN 'NEAR LIMIT (>80%)'
        ELSE 'OK'
    END                            AS limit_status
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY c
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS u ON u.NAME = c.USER_ID
WHERE c.USAGE_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3
HAVING daily_credits >= 20 * 0.8  -- show only users at or near the limit
ORDER BY usage_date DESC, daily_credits DESC;
