-- Task: MONTHLY_ACCOUNTADMIN_DB_REPORT
-- Schedule: 1st of each month at 7:15am Costa Rica
-- Calls: UTIL_DB.ADMIN.SEND_ACCOUNTADMIN_DB_REPORT()
--
-- Notes:
--   Scheduled at 7:15am — 15 minutes after the usage report task (7:00am)
--   to avoid warehouse queue contention on the same ACCOUNTADMIN_WH_XS.
--
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

CREATE OR REPLACE TASK UTIL_DB.ADMIN.MONTHLY_ACCOUNTADMIN_DB_REPORT
    WAREHOUSE             = ACCOUNTADMIN_WH_XS
    SCHEDULE              = 'USING CRON 15 7 1 * * America/Costa_Rica'
    USER_TASK_TIMEOUT_MS  = 600000   -- 10 minutes max runtime
    -- ERROR_INTEGRATION  = MY_EMAIL_INTEGRATION
    COMMENT               = 'Monthly database inventory report sent on 1st of each month at 7:15am Costa Rica'
AS
    CALL UTIL_DB.ADMIN.SEND_ACCOUNTADMIN_DB_REPORT();

ALTER TASK UTIL_DB.ADMIN.MONTHLY_ACCOUNTADMIN_DB_REPORT RESUME;
