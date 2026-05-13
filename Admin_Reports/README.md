# Admin Reports

Administrative scripts for generating and sending HTML reports from Snowflake to active users with the `ACCOUNTADMIN` role.

## Contents

| Script | Type | Purpose |
| --- | --- | --- |
| [`send_account_usage_report.sql`](send_account_usage_report.sql) | Procedure | Creates `UTIL_DB.ADMIN.SEND_ACCOUNT_USAGE_REPORT(REPORT_TYPE)` to send weekly or monthly account usage reports. |
| [`weekly_account_usage_report.sql`](weekly_account_usage_report.sql) | Task | Schedules the weekly account usage report every Monday at 7:00 AM Costa Rica time. |
| [`monthly_account_usage_report.sql`](monthly_account_usage_report.sql) | Task | Schedules the monthly account usage report on the 1st day of each month at 7:00 AM Costa Rica time. |
| [`send_accountadmin_db_report.sql`](send_accountadmin_db_report.sql) | Procedure | Creates `UTIL_DB.ADMIN.SEND_ACCOUNTADMIN_DB_REPORT()` to send a monthly database inventory to `ACCOUNTADMIN` users. |
| [`monthly_accountadmin_db_report.sql`](monthly_accountadmin_db_report.sql) | Task | Schedules the monthly database inventory on the 1st day of each month at 7:15 AM Costa Rica time. |

## Account Usage Report

The `SEND_ACCOUNT_USAGE_REPORT` procedure generates a Gmail-compatible HTML email that also works well with corporate mail clients. It accepts two modes:

- `WEEKLY`: the last 7 complete days compared with the previous 7 days. It also includes month-to-date usage.
- `MONTHLY`: the previous full calendar month compared with the month before it.

It includes, among other metrics:

- Credit consumption summary and comparison against the previous period.
- Breakdown by service type.
- AI/Cortex usage.
- Daily credit trend.
- Top users and warehouses by consumption.
- Longest-running queries and disk spill detection.
- Warehouse efficiency, queue time, spill, and resource monitors.
- Security indicators: failed logins, direct `ACCOUNTADMIN` usage, and inactive users.

## Database Inventory

The `SEND_ACCOUNTADMIN_DB_REPORT` procedure generates a monthly HTML database inventory for `ACCOUNTADMIN` users.

It classifies databases into:

- `SYSTEM`: Snowflake or system databases.
- `PROJECT`: databases using the `_DB_ROLE` or `_DB_ROLE_NEW` role convention that do not appear to be personal databases.
- `SYSADMIN`: databases owned by `SYSADMIN`.
- `USER`: personal databases using the `<NAME>_DB` pattern and owned by `<NAME>_DB_ROLE`.
- `OTHER`: databases that do not match the previous rules.

The report highlights inactive databases, relevant storage size, and cleanup or ownership adjustment recommendations.

## Dependencies

The scripts assume these objects or permissions are available:

- Target database and schema: `UTIL_DB.ADMIN`.
- Task warehouse: `ACCOUNTADMIN_WH_XS`.
- Executing role with `ACCOUNTADMIN` privileges.
- Snowpark Python available in Snowflake with runtime `3.11`.
- Notification integration named `MY_EMAIL_INTEGRATION`.
- Permission to execute `SYSTEM$SEND_EMAIL`.
- Access to `SNOWFLAKE.ACCOUNT_USAGE` views, for example:
  - `METERING_DAILY_HISTORY`
  - `QUERY_HISTORY`
  - `WAREHOUSE_METERING_HISTORY`
  - `LOGIN_HISTORY`
  - `USERS`
  - `DATABASES`
  - `DATABASE_STORAGE_USAGE_HISTORY`
- Permission to run `SHOW` commands, including:
  - `SHOW GRANTS OF ROLE ACCOUNTADMIN`
  - `SHOW USERS`
  - `SHOW WAREHOUSES`
  - `SHOW RESOURCE MONITORS`

## Suggested Deployment Order

Run the procedures first, then the tasks:

```sql
-- 1. Create procedures
-- Run send_account_usage_report.sql
-- Run send_accountadmin_db_report.sql

-- 2. Create and resume tasks
-- Run weekly_account_usage_report.sql
-- Run monthly_account_usage_report.sql
-- Run monthly_accountadmin_db_report.sql
```

## Manual Execution

```sql
-- Weekly account usage report
CALL UTIL_DB.ADMIN.SEND_ACCOUNT_USAGE_REPORT('WEEKLY');

-- Monthly account usage report
CALL UTIL_DB.ADMIN.SEND_ACCOUNT_USAGE_REPORT('MONTHLY');

-- Monthly database inventory
CALL UTIL_DB.ADMIN.SEND_ACCOUNTADMIN_DB_REPORT();
```

## Schedule

| Task | Cron | Time |
| --- | --- | --- |
| `UTIL_DB.ADMIN.WEEKLY_ACCOUNT_USAGE_REPORT` | `0 7 * * 1 America/Costa_Rica` | Mondays at 7:00 AM |
| `UTIL_DB.ADMIN.MONTHLY_ACCOUNT_USAGE_REPORT` | `0 7 1 * * America/Costa_Rica` | 1st day of the month at 7:00 AM |
| `UTIL_DB.ADMIN.MONTHLY_ACCOUNTADMIN_DB_REPORT` | `15 7 1 * * America/Costa_Rica` | 1st day of the month at 7:15 AM |

The monthly database report runs 15 minutes after the monthly account usage report to reduce contention on `ACCOUNTADMIN_WH_XS`.

## Email Configuration

The procedures use `MY_EMAIL_INTEGRATION`. If the integration does not exist, create an email notification integration and adjust `ALLOWED_RECIPIENTS` as needed:

```sql
CREATE NOTIFICATION INTEGRATION MY_EMAIL_INTEGRATION
  TYPE = EMAIL
  ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('dba@acme.com');
```

If a different integration name is used, update the procedures before deployment.

## Operations and Validation

Useful queries:

```sql
SHOW TASKS LIKE '%ACCOUNT%';

SELECT *
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
  SCHEDULED_TIME_RANGE_START => DATEADD('day', -7, CURRENT_TIMESTAMP())
))
WHERE NAME IN (
  'WEEKLY_ACCOUNT_USAGE_REPORT',
  'MONTHLY_ACCOUNT_USAGE_REPORT',
  'MONTHLY_ACCOUNTADMIN_DB_REPORT'
)
ORDER BY SCHEDULED_TIME DESC;
```

To suspend tasks:

```sql
ALTER TASK UTIL_DB.ADMIN.WEEKLY_ACCOUNT_USAGE_REPORT SUSPEND;
ALTER TASK UTIL_DB.ADMIN.MONTHLY_ACCOUNT_USAGE_REPORT SUSPEND;
ALTER TASK UTIL_DB.ADMIN.MONTHLY_ACCOUNTADMIN_DB_REPORT SUSPEND;
```

To resume them:

```sql
ALTER TASK UTIL_DB.ADMIN.WEEKLY_ACCOUNT_USAGE_REPORT RESUME;
ALTER TASK UTIL_DB.ADMIN.MONTHLY_ACCOUNT_USAGE_REPORT RESUME;
ALTER TASK UTIL_DB.ADMIN.MONTHLY_ACCOUNTADMIN_DB_REPORT RESUME;
```

## Considerations

- `ACCOUNT_USAGE` can have ingestion latency; some recent data may not appear immediately.
- Recipients are detected with `SHOW GRANTS OF ROLE ACCOUNTADMIN` and `SHOW USERS` to avoid `ACCOUNT_USAGE` view latency.
- The tasks use `USER_TASK_TIMEOUT_MS = 600000`, equivalent to 10 minutes.
- `ERROR_INTEGRATION` is commented out in the tasks. It can be enabled if a failure notification integration exists.
- The procedures use `EXECUTE AS CALLER`; the executing role must have the required privileges.
