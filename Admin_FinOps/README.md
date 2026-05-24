# Snowflake FinOps Playbook

A practical, self-contained reference for Snowflake administrators who want to move from cost visibility to cost accountability. This playbook is the operational companion to the Medium article *"Snowflake FinOps in Practice: From Weekly Monitoring to Cost Accountability"* — it takes the article's queries and expands them into a full, maintainable system.

---

## What this playbook covers

| Directory | What you will find |
|---|---|
| `00_prerequisites/` | Edition check, role setup, privilege grants |
| `01_governance/` | Resource monitors, budgets, tag enforcement policies |
| `02_attribution/` | Tag taxonomy, warehouse/user/query attribution, unattributable cost handling |
| `03_cost_reports/` | Warehouse compute, serverless, storage, AI/Cortex, internal billing, multi-account |
| `04_optimization/` | Idle warehouses, queue analysis, serverless audits |
| `05_anomaly_detection/` | Rolling baseline, z-score alerts |
| `06_automation/` | Schema setup, stored procedures, task DAGs |
| `07_troubleshooting/` | Common issues, debugging queries |
| `08_maintenance/` | How to keep the playbook current over time |

---

## Prerequisites

Before running anything in this playbook, complete the following in order:

1. **Verify your Snowflake edition.** Several features (tag enforcement policies, Materialized Views, Search Optimization) require Enterprise Edition. Run `00_prerequisites/01_edition_and_account_check.sql`.
2. **Set up roles and privileges.** The playbook uses a dedicated `FINOPS_ADMIN` role. Run `00_prerequisites/02_roles_and_privileges.sql` as `ACCOUNTADMIN`.
3. **Create the FinOps schema.** The automation section requires a dedicated database and schema for snapshots. Run `06_automation/01_finops_schema_setup.sql`.

---

## Quick start (minimal setup, maximum visibility)

If you want results immediately without building the full automation layer:

```sql
-- Step 1: Verify you can access ACCOUNT_USAGE
SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('day', -7, CURRENT_DATE);

-- Step 2: Run the attribution report (requires cost_center tag already applied)
-- → 02_attribution/02_warehouse_attribution.sql

-- Step 3: Check serverless blind spots
-- → 03_cost_reports/02_serverless_costs.sql

-- Step 4: Find idle warehouses
-- → 04_optimization/01_idle_warehouses.sql
```

The automation tasks (Section 06) are optional but recommended for ongoing monitoring.

---

## Key design decisions

**Dedicated FINOPS schema.** All snapshot tables and procedures live in a `FINOPS` database. This separates observability infrastructure from production data and makes privilege management cleaner.

**Stored procedure for SHOW WAREHOUSES.** Snowflake Tasks run in isolated sessions, so `SHOW WAREHOUSES` followed by `RESULT_SCAN(LAST_QUERY_ID())` does not work across task steps. The playbook solves this with a JavaScript stored procedure that runs both calls within the same session. See `06_automation/02_warehouse_catalog_proc.sql`.

**LEFT JOINs for tag attribution.** Every query that joins `TAG_REFERENCES` uses a LEFT JOIN. An INNER JOIN silently drops untagged spend from results, making your totals incorrect. All queries in this playbook follow this convention.

**Approximate vs. exact costs.** Several cost calculations in this playbook are estimates. Each query is clearly annotated with whether its output is exact or approximate. See `02_attribution/04_unattributable_costs.sql` for a full breakdown of what cannot be attributed.

**Credit rates.** Queries that estimate dollar values use a placeholder of `$3.00` per credit. Replace this with your actual contracted rate. Your rate appears on your Snowflake invoice and in `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY` (requires ORGADMIN).

---

## Edition requirements summary

| Feature | Standard | Enterprise | Business Critical |
|---|---|---|---|
| ACCOUNT_USAGE views | ✅ | ✅ | ✅ |
| Resource Monitors | ✅ | ✅ | ✅ |
| Budgets | ✅ | ✅ | ✅ |
| Object Tags | ✅ | ✅ | ✅ |
| Tag Policies (enforcement) | ❌ | ✅ | ✅ |
| Search Optimization | ❌ | ✅ | ✅ |
| Materialized Views | ❌ | ✅ | ✅ |
| ORGANIZATION_USAGE | Requires ORGADMIN regardless of edition |

---

## Customization checklist

Before running this playbook in your account, update these values:

- [ ] Replace `3.00` with your actual per-credit price in all billing queries
- [ ] Replace `'analytics'`, `'data_engineering'`, etc. with your actual cost center names in tag definitions
- [ ] Replace email addresses in alert configurations with real distribution lists
- [ ] Adjust z-score threshold (default: 2.0) in anomaly detection if your account has high natural variance
- [ ] Adjust the `CREDIT_QUOTA` and `SPENDING_LIMIT` values in governance files to match your actual budgets
- [ ] Review ACCOUNT_USAGE latency before scheduling tasks (most views: up to 3 hours; `QUERY_ATTRIBUTION_HISTORY`: up to 8 hours; `ORGANIZATION_USAGE`: up to 72 hours)

---

## How to keep this playbook current

Snowflake releases new features on a continuous basis. See `08_maintenance/DOCUMENTATION_WATCH.md` for a structured process to review release notes, identify new ACCOUNT_USAGE views, and add them to the playbook without breaking existing queries.

---

## File naming convention

Files are prefixed with a two-digit number to enforce execution order. `README.md` files in each directory explain the section's purpose, prerequisites, and any important caveats before you run the SQL.

---

## Contributing

If you identify a gap, an incorrect query, or a better approach for your account configuration, the preferred workflow is:

1. Open an issue describing the gap or problem
2. Add the fix to the relevant section file with a comment explaining the change
3. Update the `08_maintenance/DOCUMENTATION_WATCH.md` if the change was triggered by a new Snowflake release note
