-- Task: WEEKLY_ACCOUNT_USAGE_REPORT
-- Schedule: Every Monday at 7:00am Costa Rica
-- Calls: UTIL_DB.ADMIN.SEND_ACCOUNT_USAGE_REPORT('WEEKLY')
--
-- Notes:
--   USER_TASK_TIMEOUT_MS : Hard-kills the task after 10 minutes so a hung
--                          email integration or slow ACCOUNT_USAGE query
--                          does not hold the warehouse indefinitely.
--   ERROR_INTEGRATION    : Uncomment and set to a valid notification
--                          integration to receive alerts on task failure.
--                          Create one with:
--                            CREATE NOTIFICATION INTEGRATION <name>
--                              TYPE = EMAIL
--                              ENABLED = TRUE
--                              ALLOWED_RECIPIENTS = ('dba@acme.com');

CREATE OR REPLACE TASK UTIL_DB.ADMIN.WEEKLY_ACCOUNT_USAGE_REPORT
    WAREHOUSE             = ACCOUNTADMIN_WH_XS
    SCHEDULE              = 'USING CRON 0 7 * * 1 America/Costa_Rica'
    USER_TASK_TIMEOUT_MS  = 600000   -- 10 minutes max runtime
    -- ERROR_INTEGRATION  = MY_EMAIL_INTEGRATION
    COMMENT               = 'Weekly account usage report sent every Monday at 7:00am Costa Rica'
AS
    CALL UTIL_DB.ADMIN.SEND_ACCOUNT_USAGE_REPORT('WEEKLY');

ALTER TASK UTIL_DB.ADMIN.WEEKLY_ACCOUNT_USAGE_REPORT RESUME;
