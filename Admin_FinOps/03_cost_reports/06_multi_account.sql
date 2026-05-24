/*
================================================================================
  FILE: 03_cost_reports/06_multi_account.sql
  PURPOSE: Cross-account cost visibility using ORGANIZATION_USAGE.
           Requires ORGADMIN role or explicit privilege delegation.
  REQUIRES: ORGADMIN role (or delegation via GRANT)
  KEY VIEW: SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
  LATENCY:  Up to 72 hours (3 days)
  DOCUMENTATION: https://docs.snowflake.com/en/sql-reference/organization-usage
================================================================================

  COMMON SETUP ISSUE:
  ───────────────────
  ORGADMIN is typically held by a central cloud/infrastructure team, not the
  data platform team. Options if you do not have ORGADMIN:

  1. Request privilege delegation from your org admin:
       USE ROLE ORGADMIN;
       GRANT DATABASE ROLE SNOWFLAKE.ORGANIZATION_USAGE_VIEWER
         TO ROLE <your_finops_role>;
     This allows reading ORGANIZATION_USAGE without the full ORGADMIN role.

  2. Request the org admin to run these queries and export results to a shared
     table you can query with a lower-privileged role.

  3. Export USAGE_IN_CURRENCY_DAILY to a table in a shared database that all
     relevant roles can read. Set up a scheduled task under ORGADMIN to refresh it.
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- SETUP: Switch to ORGADMIN (if you have it)
-- ─────────────────────────────────────────────────────────────────────────────
-- USE ROLE ORGADMIN;  -- Uncomment if you have ORGADMIN


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 1: Accounts visible in the organization
-- ─────────────────────────────────────────────────────────────────────────────
SELECT DISTINCT
    ACCOUNT_NAME,
    ACCOUNT_LOCATOR,
    REGION,
    SNOWFLAKE_REGION,
    EDITION
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
ORDER BY ACCOUNT_NAME;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 2: Monthly compute spend by account (current month)
-- ─────────────────────────────────────────────────────────────────────────────
-- USAGE = credits for compute (when RATING_TYPE = 'compute')
-- USAGE_IN_CURRENCY = dollar amount in your contract currency
SELECT
    ACCOUNT_NAME,
    SERVICE_TYPE,
    ROUND(SUM(USAGE), 2)              AS total_usage_credits,
    ROUND(SUM(USAGE_IN_CURRENCY), 2)  AS total_usd,
    MAX(CURRENCY)                     AS currency
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
WHERE USAGE_DATE  >= DATE_TRUNC('month', CURRENT_DATE)
  AND RATING_TYPE  = 'compute'
GROUP BY 1, 2
ORDER BY 1, 4 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 3: All billing categories by account (current month)
-- ─────────────────────────────────────────────────────────────────────────────
-- RATING_TYPE values: 'compute', 'storage', 'data_transfer', 'support', etc.
-- USAGE units depend on RATING_TYPE: credits for compute, TB for storage, etc.
SELECT
    ACCOUNT_NAME,
    RATING_TYPE,
    SERVICE_TYPE,
    ROUND(SUM(USAGE), 2)              AS total_usage,
    ROUND(SUM(USAGE_IN_CURRENCY), 2)  AS total_usd,
    MAX(CURRENCY)                     AS currency
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
WHERE USAGE_DATE >= DATE_TRUNC('month', CURRENT_DATE)
GROUP BY 1, 2, 3
ORDER BY ACCOUNT_NAME, total_usd DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 4: Month-over-month trend by account — last 6 months
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    DATE_TRUNC('month', USAGE_DATE)   AS month,
    ACCOUNT_NAME,
    ROUND(SUM(USAGE_IN_CURRENCY), 2)  AS total_usd,
    MAX(CURRENCY)                     AS currency
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
WHERE USAGE_DATE >= DATEADD('month', -6, DATE_TRUNC('month', CURRENT_DATE))
  AND RATING_TYPE = 'compute'
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 5: Highest-spend accounts — last 30 days (ranking)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    ACCOUNT_NAME,
    ROUND(SUM(USAGE_IN_CURRENCY), 2)                         AS total_usd_30d,
    ROUND(SUM(USAGE_IN_CURRENCY) / SUM(SUM(USAGE_IN_CURRENCY))
        OVER () * 100, 1)                                    AS pct_of_org_total,
    RANK() OVER (ORDER BY SUM(USAGE_IN_CURRENCY) DESC)       AS spend_rank,
    MAX(CURRENCY)                                            AS currency
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
WHERE USAGE_DATE  >= DATEADD('day', -30, CURRENT_DATE)
  AND RATING_TYPE  = 'compute'
GROUP BY 1
ORDER BY 2 DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- PATTERN: Export ORGANIZATION_USAGE to a shared table (for non-ORGADMIN access)
-- ─────────────────────────────────────────────────────────────────────────────
-- Run this as ORGADMIN via a scheduled Task. Other roles can then query
-- FINOPS.REPORTS.ORG_USAGE_DAILY without needing ORGADMIN.

-- ⚠️ Run as ORGADMIN. Requires FINOPS database to already exist (06_automation/01_finops_schema_setup.sql)
CREATE TABLE IF NOT EXISTS FINOPS.REPORTS.ORG_USAGE_DAILY AS
SELECT * FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
WHERE USAGE_DATE >= DATEADD('month', -3, CURRENT_DATE);

-- Refresh pattern (run as a Task under ORGADMIN):
MERGE INTO FINOPS.REPORTS.ORG_USAGE_DAILY AS target
USING (
    SELECT * FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
    WHERE USAGE_DATE >= DATEADD('day', -4, CURRENT_DATE)  -- overlap to catch late-arriving data
) AS source
ON  target.USAGE_DATE    = source.USAGE_DATE
AND target.ACCOUNT_NAME  = source.ACCOUNT_NAME
AND target.SERVICE_TYPE  = source.SERVICE_TYPE
AND target.RATING_TYPE   = source.RATING_TYPE
WHEN MATCHED    THEN UPDATE SET
    USAGE             = source.USAGE,
    USAGE_IN_CURRENCY = source.USAGE_IN_CURRENCY
WHEN NOT MATCHED THEN INSERT VALUES (
    source.USAGE_DATE, source.ACCOUNT_LOCATOR, source.ACCOUNT_NAME,
    source.ORGANIZATION_NAME, source.CURRENCY, source.USAGE_IN_CURRENCY,
    source.USAGE, source.USAGE_TYPE, source.RATING_TYPE, source.SERVICE_TYPE,
    source.BALANCE_SOURCE, source.CONTRACT_NUMBER, source.REGION,
    source.SNOWFLAKE_REGION, source.EDITION
);
