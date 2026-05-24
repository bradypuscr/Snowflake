/*
================================================================================
  FILE: 01_governance/01_resource_monitors.sql
  PURPOSE: Resource monitor templates for warehouse-level credit enforcement.
           Resource monitors are hard stops — the warehouse suspends when the
           quota is reached within the defined time window.
  REQUIRES: ACCOUNTADMIN or a role with CREATE RESOURCE MONITOR privilege
  DOCUMENTATION: https://docs.snowflake.com/en/user-guide/resource-monitors
================================================================================

  KEY CONCEPTS:
  ─────────────
  • CREDIT_QUOTA: Maximum credits allowed in the time window.
  • FREQUENCY: DAILY | WEEKLY | MONTHLY | YEARLY | NEVER
  • TRIGGERS: Actions fired at percentage thresholds (NOTIFY, SUSPEND, SUSPEND_IMMEDIATE)
  • SUSPEND: Blocks new queries; running queries finish.
  • SUSPEND_IMMEDIATE: Kills all running queries immediately.
  • A warehouse can have exactly ONE resource monitor.
  • A resource monitor can cover MULTIPLE warehouses.
  • Resource monitors do NOT cover serverless, Snowpipe, or AI costs.
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- PATTERN 1: Account-level monitor (safety net)
-- ─────────────────────────────────────────────────────────────────────────────
-- Apply this to your entire account as a last-resort ceiling.
-- The quota should be set above your normal peak spend — this is a safety net,
-- not a budget enforcement tool.
--
-- ⚠️ Replace 5000 with your actual monthly credit ceiling.

CREATE OR REPLACE RESOURCE MONITOR account_safety_net
    WITH CREDIT_QUOTA   = 5000           -- total credits allowed this month
    FREQUENCY           = MONTHLY
    START_TIMESTAMP     = IMMEDIATELY
    TRIGGERS
        ON 80  PERCENT DO NOTIFY          -- email alert at 80%
        ON 95  PERCENT DO NOTIFY          -- email alert at 95%
        ON 100 PERCENT DO SUSPEND;        -- suspend all warehouses at 100%

-- Apply to the entire account (covers all warehouses not individually monitored)
ALTER ACCOUNT SET RESOURCE_MONITOR = account_safety_net;


-- ─────────────────────────────────────────────────────────────────────────────
-- PATTERN 2: Team warehouse monitor (weekly budget enforcement)
-- ─────────────────────────────────────────────────────────────────────────────
-- Use for production team warehouses where you have a weekly credit budget.
-- Weekly frequency is common because most teams plan costs in weekly sprints.
--
-- ⚠️ Replace 200 with the team's actual weekly warehouse budget.

CREATE OR REPLACE RESOURCE MONITOR analytics_team_weekly
    WITH CREDIT_QUOTA   = 200            -- credits per week for this team
    FREQUENCY           = WEEKLY
    START_TIMESTAMP     = IMMEDIATELY
    TRIGGERS
        ON 75  PERCENT DO NOTIFY
        ON 90  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;       -- blocks new queries; running ones finish

-- Attach to the team's warehouse.
ALTER WAREHOUSE ANALYTICS_WH SET RESOURCE_MONITOR = analytics_team_weekly;

-- Attach to multiple warehouses that share the same weekly budget:
-- ALTER WAREHOUSE ANALYTICS_WH_2 SET RESOURCE_MONITOR = analytics_team_weekly;


-- ─────────────────────────────────────────────────────────────────────────────
-- PATTERN 3: Dev/sandbox monitor (aggressive hard stop)
-- ─────────────────────────────────────────────────────────────────────────────
-- For development or sandbox warehouses where cost control matters more than
-- query completion. SUSPEND_IMMEDIATE kills running queries at the limit.
-- Appropriate for non-production environments.
--
-- ⚠️ Replace 50 with your dev budget.

CREATE OR REPLACE RESOURCE MONITOR dev_sandbox_daily
    WITH CREDIT_QUOTA   = 50             -- credits per day for all dev warehouses
    FREQUENCY           = DAILY
    START_TIMESTAMP     = IMMEDIATELY
    TRIGGERS
        ON 60  PERCENT DO NOTIFY
        ON 80  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND_IMMEDIATE;  -- kills running queries immediately

ALTER WAREHOUSE DEV_WH SET RESOURCE_MONITOR = dev_sandbox_daily;


-- ─────────────────────────────────────────────────────────────────────────────
-- PATTERN 4: Monthly monitor with multiple notification recipients
-- ─────────────────────────────────────────────────────────────────────────────
-- Resource monitors send notifications to all users who are ACCOUNTADMIN
-- or who have the MONITOR privilege on the account.
-- You cannot specify individual email addresses in the resource monitor itself —
-- notification recipients are controlled by account-level email settings.
--
-- To configure notification recipients:
--   ALTER ACCOUNT SET RESOURCE_MONITOR_NOTIFICATION_EMAILS =
--     ('admin1@company.com', 'admin2@company.com', 'finance@company.com');

ALTER ACCOUNT SET RESOURCE_MONITOR_NOTIFICATION_EMAILS =
    ('snowflake-admin@company.com', 'finops@company.com');

-- ⚠️ This is an account-level setting — it affects ALL resource monitor
--    notifications, not just the ones you create in this file.


-- ─────────────────────────────────────────────────────────────────────────────
-- AUDIT: Review existing resource monitors and their warehouse assignments
-- ─────────────────────────────────────────────────────────────────────────────

-- View all resource monitors in the account
SHOW RESOURCE MONITORS;

-- See which warehouses have monitors attached (and which don't)
SHOW WAREHOUSES;
SELECT
    "name"             AS warehouse_name,
    "size"             AS warehouse_size,
    "resource_monitor" AS monitor_name,
    CASE WHEN "resource_monitor" = 'null' OR "resource_monitor" IS NULL
         THEN 'NO MONITOR — unprotected'
         ELSE 'protected'
    END AS protection_status
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY protection_status, warehouse_name;

-- ⚠️ Any warehouse showing "NO MONITOR — unprotected" is running with no ceiling
--    other than the account-level monitor (if you set one).


-- ─────────────────────────────────────────────────────────────────────────────
-- TROUBLESHOOTING
-- ─────────────────────────────────────────────────────────────────────────────
/*
  ISSUE: Resource monitor not triggering notifications
  FIX:   Verify that RESOURCE_MONITOR_NOTIFICATION_EMAILS is set at account level.
         Also verify that the notification users have valid email addresses in
         their Snowflake user profile: ALTER USER <user> SET EMAIL = '...';

  ISSUE: Warehouse not suspending at 100%
  FIX:   SUSPEND only blocks NEW queries. A query that started before the limit
         was hit will finish. This is by design. Use SUSPEND_IMMEDIATE to kill
         running queries immediately.

  ISSUE: Monitor quota resets at wrong time
  FIX:   The quota window starts from START_TIMESTAMP, not from calendar midnight.
         A WEEKLY monitor created on Wednesday resets the following Wednesday.
         Set START_TIMESTAMP to a specific date/time if you need calendar alignment:
           START_TIMESTAMP = '2025-06-02 00:00:00'  -- start on a Monday

  ISSUE: "Cannot apply monitor — warehouse already has one"
  FIX:   A warehouse can only have one monitor. Remove the existing monitor first:
           ALTER WAREHOUSE <wh_name> SET RESOURCE_MONITOR = null;

  ISSUE: Credits consumed but monitor did not trigger
  FIX:   Resource monitors update credit counts every 10 minutes approximately.
         A burst of consumption in a short window may exceed the threshold between
         updates. The monitor will catch it on the next polling cycle.
*/
