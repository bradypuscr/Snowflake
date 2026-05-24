# 00 — Prerequisites

Run these scripts **once**, in order, before anything else in the playbook. They verify that your account has the required features and establish the role structure the playbook depends on.

---

## Execution order

1. `01_edition_and_account_check.sql` — Read-only diagnostics. Run as any role with ACCOUNT_USAGE access. Review the output before proceeding.
2. `02_roles_and_privileges.sql` — Creates roles and grants privileges. **Requires ACCOUNTADMIN.**

---

## What to look for in the edition check

| Check | Why it matters |
|---|---|
| Snowflake edition | Determines which features are available (tag policies, Search Optimization, Materialized Views) |
| ORGANIZATION_USAGE access | Requires ORGADMIN — may need a separate request to your cloud team |
| ACCOUNT_USAGE latency | Most views lag up to 3 hours. QUERY_ATTRIBUTION_HISTORY lags up to 8 hours. Plan task schedules accordingly |
| Current credit consumption | Baseline before you start any FinOps work |

---

## Notes on ORGADMIN

`ORGANIZATION_USAGE` requires the `ORGADMIN` role, which is typically held by a small number of people in a central cloud or infrastructure team — not usually the data platform team. If you do not have ORGADMIN:

- The multi-account section (`03_cost_reports/06_multi_account.sql`) will not work directly
- Request a privilege delegation from your org admin, or ask them to run those queries and share results
- Alternatively, export `USAGE_IN_CURRENCY_DAILY` to a table you can query with a lower-privileged role

---

## Notes on role design

The playbook creates two roles:
- `FINOPS_ADMIN` — can read all cost data, create monitors and budgets, manage tags. Assign to platform engineers and finance partners who need full access.
- `FINOPS_VIEWER` — read-only access to cost reports. Assign to team leads and managers who need to see costs but should not change configuration.

Both roles are granted `IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE`, which is the standard way to grant access to `ACCOUNT_USAGE` views without granting `ACCOUNTADMIN`.
