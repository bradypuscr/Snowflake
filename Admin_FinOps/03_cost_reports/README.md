# 03 — Cost Reports

This section contains the core reporting queries organized by billing category. Each file is self-contained and can be run independently after the prerequisites and attribution setup are complete.

---

## Files and what they answer

| File | Question answered |
|---|---|
| `01_warehouse_compute.sql` | How much did each warehouse spend? By day, week, month? |
| `02_serverless_costs.sql` | What did Snowpipe, clustering, tasks, and other serverless services cost? |
| `03_storage_costs.sql` | How much data are we storing? Which databases/tables are growing fastest? |
| `04_ai_cortex_costs.sql` | Who is using Cortex Code? How much? What are the AI service totals? |
| `05_internal_billing.sql` | How do I generate a monthly cost report by team with estimated dollar amounts? |
| `06_multi_account.sql` | How does spend compare across accounts in the organization? |

---

## Rounding and precision

All credit values in these reports are rounded to 2 or 4 decimal places for readability. Snowflake's billing system uses higher precision internally. When summing rounded values across reports, small discrepancies are expected — this is a display artifact, not a data quality issue.

For exact billing figures, always verify against your Snowflake invoice or `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`.

---

## Suggested reporting cadence

| Report | Cadence | Audience |
|---|---|---|
| Warehouse compute by cost center | Weekly | Team leads, platform team |
| Serverless costs by service | Weekly | Platform team |
| Storage growth | Monthly | Platform team, finance |
| AI/Cortex per-user | Monthly | Engineering managers |
| Internal billing with dollar estimates | Monthly | Finance, department heads |
| Multi-account comparison | Monthly | Cloud team, CTO |

---

## Dollar amount disclaimers

Queries in `05_internal_billing.sql` multiply credits by a placeholder rate of `$3.00`. This is not your actual rate. Your contracted per-credit price appears on your Snowflake invoice. Replace `3.00` with your actual rate before sharing reports with finance teams.

Dollar estimates from these queries are **not** the same as your Snowflake invoice. Invoices include contract adjustments, commitment discounts, and other factors not visible in `ACCOUNT_USAGE`.
