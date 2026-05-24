# 07 — Troubleshooting

Common issues encountered when building and operating a Snowflake FinOps system. Organized by symptom.

---

## When to look here

- Your report totals do not match what you expected
- A query from the playbook returns an error
- Cost data appears to be missing or stale
- Tags are applied but not showing up in attribution queries
- Tasks are failing or not running
- Numbers don't reconcile with your Snowflake invoice

---

## Most common issues by category

**Data looks stale / missing recent activity**
→ ACCOUNT_USAGE latency. Most views lag up to 3 hours. QUERY_ATTRIBUTION_HISTORY lags up to 8 hours. ORGANIZATION_USAGE lags up to 72 hours. Always add a buffer when designing real-time reports.

**Report totals don't match the invoice**
→ Invoice figures include contract adjustments, discount tiers, and commitment consumption that are not visible in ACCOUNT_USAGE. Use ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY for figures closer to your actual invoice.

**Tags applied but not in TAG_REFERENCES**
→ TAG_REFERENCES also lags up to 3 hours. Use SYSTEM$GET_TAG() for immediate verification.

**RESULT_SCAN returns empty in a Task**
→ Classic session isolation problem. Use the stored procedure pattern in 06_automation/02_warehouse_catalog_proc.sql.

**Numbers differ between ACCOUNT_USAGE and ORGANIZATION_USAGE**
→ Different latencies, different granularities. ORGANIZATION_USAGE is the authoritative billing view.

---

## The reconciliation checklist

When your report total does not match expectations:

1. Check the time window — are you including partial days on either end?
2. Check the JOIN type — is an INNER JOIN hiding untagged spend?
3. Check ACCOUNT_USAGE latency — is the data from today complete yet?
4. Check the CREDITS_USED column — are you mixing compute and cloud services?
5. Check for dropped warehouses — metering data may exist for a warehouse that no longer appears in SHOW WAREHOUSES.
6. Check for multi-cluster warehouses — credits for additional clusters appear as separate rows, not as a multiplied single row.
