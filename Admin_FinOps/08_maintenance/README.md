# 08 — Maintenance

A FinOps system that is not maintained becomes stale — new billing categories appear, new views are added to ACCOUNT_USAGE, and the playbook falls behind. This section provides a structured process for keeping the playbook current.

---

## Quarterly maintenance checklist

Run this checklist every quarter, or after every major Snowflake release that affects billing or ACCOUNT_USAGE.

### 1. Check for new ACCOUNT_USAGE views

```sql
-- Compare against what was present when this playbook was last updated.
-- Look for view names starting with these patterns that are not in the playbook:
SHOW VIEWS IN SCHEMA SNOWFLAKE.ACCOUNT_USAGE;
```

**New views to look for:**
- Views containing `USAGE_HISTORY`, `HISTORY`, or `METRICS` in the name
- Views for new Snowflake features (new AI models, new serverless functions, new storage types)
- Views adding granularity to existing billing categories

### 2. Check for new ORGANIZATION_USAGE views

```sql
SHOW VIEWS IN SCHEMA SNOWFLAKE.ORGANIZATION_USAGE;
```

### 3. Check for new Cortex Code parameters

```sql
SHOW PARAMETERS LIKE 'CORTEX_CODE%' IN ACCOUNT;
```

New surfaces (desktop, mobile, etc.) may add new parameters. Update `03_cost_reports/04_ai_cortex_costs.sql` when new parameters appear.

### 4. Check for new AI service types

```sql
SELECT DISTINCT SERVICE_TYPE
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE)
ORDER BY 1;
```

Compare against the list in `03_cost_reports/04_ai_cortex_costs.sql`. New SERVICE_TYPE values indicate new billing categories.

### 5. Verify your credit rate is current

Your contracted per-credit price may change at contract renewal. Update the `3.00` placeholder in `03_cost_reports/05_internal_billing.sql` whenever your contract changes.

### 6. Review anomaly detection performance

```sql
SELECT
    DATE_TRUNC('month', detected_at) AS month,
    COUNT(*) AS total_detections,
    SUM(CASE WHEN alert_sent THEN 1 ELSE 0 END) AS alerts_sent,
    AVG(z_score) AS avg_z_score
FROM FINOPS.ALERTS.ANOMALY_LOG
WHERE detected_at >= DATEADD('month', -6, CURRENT_DATE)
GROUP BY 1
ORDER BY 1 DESC;
```

If alerts are too frequent, increase the z-score threshold. If you are missing spikes, lower it or widen the baseline window.

### 7. Audit untagged warehouses

Run `02_attribution/01_tag_setup.sql` Section 5 to find objects created without tags in the last quarter. Tag them and update the tag enforcement policy if needed.

---

## Where to find Snowflake release notes

- **Release notes:** https://docs.snowflake.com/en/release-notes/new-features
- **ACCOUNT_USAGE reference:** https://docs.snowflake.com/en/sql-reference/account-usage
- **ORGANIZATION_USAGE reference:** https://docs.snowflake.com/en/sql-reference/organization-usage
- **Budgets changelog:** https://docs.snowflake.com/en/user-guide/budgets
- **Cost management overview:** https://docs.snowflake.com/en/user-guide/cost-understanding-overall

Snowflake releases new features on a continuous basis (approximately every 2-3 weeks). Subscribe to the release notes RSS feed or set a calendar reminder to review them monthly.

---

## See also: `DOCUMENTATION_WATCH.md`

`DOCUMENTATION_WATCH.md` in this directory contains a structured watch list of specific documentation pages to review regularly, organized by playbook section.
