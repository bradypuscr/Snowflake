# 06 — Automation

This section builds the infrastructure that makes the rest of the playbook self-running: a dedicated schema for snapshots, a stored procedure to work around the SHOW WAREHOUSES session limitation, and Snowflake Tasks for daily snapshots and anomaly alerting.

---

## Execution order — strict

Run these scripts in order. Later scripts depend on objects created by earlier ones.

1. `01_finops_schema_setup.sql` — Create FINOPS database, schemas, and tables.
2. `02_warehouse_catalog_proc.sql` — Create the stored procedure for warehouse config capture.
3. `03_daily_snapshot_task.sql` — Create the task DAG for daily cost snapshots.
4. `04_anomaly_alert_task.sql` — Create the task for weekly anomaly alerting.

---

## The SHOW WAREHOUSES session problem

`SHOW WAREHOUSES` followed by `RESULT_SCAN(LAST_QUERY_ID())` works in interactive sessions. Inside a Snowflake Task, each statement runs in an isolated session — `LAST_QUERY_ID()` returns the task infrastructure's own last query, not your `SHOW WAREHOUSES`.

**The solution:** A JavaScript stored procedure runs both calls within a single session context, then upserts results into `FINOPS.RAW.WAREHOUSE_CATALOG`. Tasks call the procedure rather than the SHOW command directly. This gives you a queryable table of current warehouse configuration that joins cleanly to `WAREHOUSE_METERING_HISTORY`.

---

## Task structure

```
FINOPS_DAILY_ROOT_TASK (schedule: daily at 07:00 UTC)
├── FINOPS_WAREHOUSE_CATALOG_TASK    (refresh warehouse config)
├── FINOPS_COST_SNAPSHOT_TASK        (snapshot yesterday's costs)
└── FINOPS_IDLE_CHECK_TASK           (update last-access tracking table)

FINOPS_ANOMALY_TASK (schedule: weekly, Monday 08:00 UTC)
└── Runs z-score query → sends email if z_score >= 2.0
```

---

## Required privileges for tasks

Tasks run as the role that created them (CALLER) by default, or as OWNER. The tasks in this section are created under `FINOPS_ADMIN`. Make sure `FINOPS_ADMIN` has:
- EXECUTE TASK on account
- All privileges granted in `00_prerequisites/02_roles_and_privileges.sql`
- USAGE on the warehouse specified in each task definition

---

## Email alerts

The anomaly alert task uses `SYSTEM$SEND_EMAIL()`, which requires:
1. Email integration to be enabled on the account (contact Snowflake support or check Admin console)
2. Notification integration created (see `04_anomaly_alert_task.sql`)
3. The email address(es) verified in Snowflake's email notification settings

If `SYSTEM$SEND_EMAIL()` is not available on your account, the task still runs the z-score query and writes to `FINOPS.ALERTS.ANOMALY_LOG` — you can query that table manually or connect it to an external alerting system.
