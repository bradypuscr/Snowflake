# Documentation Watch List

This file tracks the specific Snowflake documentation pages relevant to each playbook section. Review each page when you run the quarterly maintenance checklist, or when a new Snowflake release includes changes in that area.

---

## How to use this file

1. Visit each URL in the relevant section
2. Compare against what the playbook currently implements
3. If new views, columns, or parameters appear, add a comment to the relevant SQL file and update the queries
4. Update the "Last reviewed" date in this file after each review

---

## Section 00 — Prerequisites

| Page | URL | What to watch for | Last reviewed |
|---|---|---|---|
| ACCOUNT_USAGE overview | https://docs.snowflake.com/en/sql-reference/account-usage | New views added to the schema | — |
| Enabling ACCOUNT_USAGE for other roles | https://docs.snowflake.com/en/sql-reference/account-usage#enabling-account-usage-for-other-roles | Privilege model changes | — |
| Snowflake database roles | https://docs.snowflake.com/en/sql-reference/snowflake-db-roles | New built-in roles for governance | — |

---

## Section 01 — Governance

| Page | URL | What to watch for | Last reviewed |
|---|---|---|---|
| Resource Monitors | https://docs.snowflake.com/en/user-guide/resource-monitors | New trigger types, new properties | — |
| Budgets | https://docs.snowflake.com/en/user-guide/budgets | Hard-stop capability (not yet available), new object types that can be added | — |
| Object Tagging | https://docs.snowflake.com/en/user-guide/object-tagging | Tag propagation changes, new taggable object types | — |
| Tag policies | https://docs.snowflake.com/en/user-guide/tag-based-masking-policies | Enforcement changes | — |

**Watch especially:** Budget hard-stop capability. As of this writing, budgets are alert-only. If Snowflake adds enforcement capability, update `01_governance/02_budgets.sql` with the new syntax.

---

## Section 02 — Attribution

| Page | URL | What to watch for | Last reviewed |
|---|---|---|---|
| TAG_REFERENCES view | https://docs.snowflake.com/en/sql-reference/account-usage/tag_references | New columns, new DOMAIN values | — |
| QUERY_ATTRIBUTION_HISTORY | https://docs.snowflake.com/en/sql-reference/account-usage/query_attribution_history | New columns (ROLE_NAME if added), latency improvements | — |
| Attributing cost in Snowflake | https://docs.snowflake.com/en/user-guide/cost-attributing | New attribution mechanisms | — |

**Watch especially:** QUERY_ATTRIBUTION_HISTORY column additions. The view currently lacks ROLE_NAME — if Snowflake adds it, remove the join-to-QUERY_HISTORY workaround in `02_attribution/03_user_query_attribution.sql`.

---

## Section 03 — Cost Reports

| Page | URL | What to watch for | Last reviewed |
|---|---|---|---|
| WAREHOUSE_METERING_HISTORY | https://docs.snowflake.com/en/sql-reference/account-usage/warehouse_metering_history | New columns | — |
| METERING_DAILY_HISTORY | https://docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history | New SERVICE_TYPE values (new AI services) | — |
| PIPE_USAGE_HISTORY | https://docs.snowflake.com/en/sql-reference/account-usage/pipe_usage_history | Schema changes | — |
| AUTOMATIC_CLUSTERING_HISTORY | https://docs.snowflake.com/en/sql-reference/account-usage/automatic_clustering_history | Schema changes | — |
| SERVERLESS_TASK_HISTORY | https://docs.snowflake.com/en/sql-reference/account-usage/serverless_task_history | Schema changes | — |
| STORAGE_USAGE | https://docs.snowflake.com/en/sql-reference/account-usage/storage_usage | New storage categories (hybrid tables, etc.) | — |
| TABLE_STORAGE_METRICS | https://docs.snowflake.com/en/sql-reference/account-usage/table_storage_metrics | New columns | — |
| DATABASE_STORAGE_USAGE_HISTORY | https://docs.snowflake.com/en/sql-reference/account-usage/database_storage_usage_history | Schema changes | — |
| CORTEX_CODE_SNOWSIGHT_USAGE_HISTORY | https://docs.snowflake.com/en/sql-reference/account-usage/cortex_code_snowsight_usage_history | New columns, new surfaces | — |
| CORTEX_CODE_CLI_USAGE_HISTORY | https://docs.snowflake.com/en/sql-reference/account-usage/cortex_code_cli_usage_history | New columns | — |
| CORTEX_CODE_DESKTOP_USAGE_HISTORY | https://docs.snowflake.com/en/sql-reference/account-usage/cortex_code_desktop_usage_history | Verify availability in your version | — |
| Cortex Code credit usage | https://docs.snowflake.com/en/user-guide/cortex-code/credit-usage-limit | New per-user parameters, new surfaces | — |
| USAGE_IN_CURRENCY_DAILY | https://docs.snowflake.com/en/sql-reference/organization-usage/usage_in_currency_daily | New RATING_TYPE or SERVICE_TYPE values | — |

**Watch especially:**
- New `SERVICE_TYPE` values in `METERING_DAILY_HISTORY` — each new Snowflake AI feature (Cortex Agents, fine-tuning, etc.) adds a new service type. Update `04_ai_cortex_costs.sql` to include them.
- New `CORTEX_CODE_*_USAGE_HISTORY` views for new surfaces (mobile, embed, etc.)
- New storage types (Hybrid Tables, Iceberg Tables) may add new storage categories to `STORAGE_USAGE`

---

## Section 04 — Optimization

| Page | URL | What to watch for | Last reviewed |
|---|---|---|---|
| QUERY_HISTORY | https://docs.snowflake.com/en/sql-reference/account-usage/query_history | New columns (query acceleration, AI assist) | — |
| Search Optimization Service | https://docs.snowflake.com/en/user-guide/search-optimization-service | New table types supported | — |
| Automatic Clustering | https://docs.snowflake.com/en/user-guide/tables-auto-reclustering | New clustering key types | — |

---

## Section 05 — Anomaly Detection

No specific documentation pages to watch — the z-score logic is based on standard statistics and METERING_DAILY_HISTORY, which is stable. Watch for new SERVICE_TYPEs and add anomaly detection for them as they become significant in your account.

---

## Section 06 — Automation

| Page | URL | What to watch for | Last reviewed |
|---|---|---|---|
| Tasks | https://docs.snowflake.com/en/user-guide/tasks-intro | New task features (error handling, branching DAGs) | — |
| SYSTEM$SEND_EMAIL | https://docs.snowflake.com/en/sql-reference/functions/system_send_email | New parameters, changed behavior | — |
| Stored procedures (JavaScript) | https://docs.snowflake.com/en/developer-guide/stored-procedure/stored-procedures-javascript | API changes | — |

---

## New features to watch industry-wide

These are areas where Snowflake is actively investing and where new FinOps capabilities may appear:

- **Budget hard-stop enforcement** — Snowflake has signaled intent to add enforcement capability to Budgets. When available, it changes the governance model significantly.
- **Hybrid Table storage billing** — Hybrid Tables (HTAP) may add new cost categories.
- **Iceberg Table storage** — Tables stored in external locations have different billing models.
- **Cortex AI function expansion** — New models and functions add new SERVICE_TYPE values.
- **Snowflake Native App Framework costs** — App consumption may add new attribution challenges.
- **Cross-cloud replication** — New cross-cloud scenarios may add new cost categories to ORGANIZATION_USAGE.

---

*Last full playbook review: 2026-05-22*
*Next scheduled review: 2026-08-22*
