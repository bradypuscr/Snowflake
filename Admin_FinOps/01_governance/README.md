# 01 — Governance

Governance is how you prevent cost surprises, not just detect them after the fact. This section covers the three layers of spending control available in Snowflake: hard stops (resource monitors), soft limits (budgets), and access control (tag enforcement policies).

---

## Execution order

1. `01_resource_monitors.sql` — Create warehouse-level hard stops. No edition requirement.
2. `02_budgets.sql` — Create team-level spending limits including serverless coverage.
3. `03_tag_enforcement.sql` — Require tags before warehouses become usable. **Enterprise Edition only.**

---

## Which tool covers what

| Spending type | Resource Monitor | Budget |
|---|---|---|
| Virtual warehouse compute | ✅ Hard stop | ✅ Tracked |
| Serverless (Snowpipe, Clustering, etc.) | ❌ Not covered | ✅ Tracked |
| AI / Cortex | ❌ Not covered | ✅ Tracked |
| Cloud services | ❌ Not covered | ⚠️ Partial |
| Cross-object rollup | ❌ One per warehouse | ✅ Multiple objects |
| Hard stop capability | ✅ Yes | ❌ Alerts only |

**The gap:** Budgets can cover everything but only alert — they do not stop spending. Resource monitors stop spending but only see warehouse compute. There is currently no single control that provides a hard stop across all billing categories. This is a known limitation worth communicating to finance stakeholders.

---

## Recommended setup sequence

1. Start with resource monitors on your highest-spend warehouses. This gives you immediate protection on the largest cost driver.
2. Add budgets for each team, covering their warehouses AND the schemas they own (for serverless coverage).
3. If on Enterprise Edition, add tag enforcement so new warehouses cannot be created without a cost center tag.

---

## Monitoring existing controls

After setup, periodically verify that monitors and budgets are still attached to the right objects:

```sql
-- Warehouses without a resource monitor
SHOW WAREHOUSES;
SELECT "name" AS warehouse_name, "resource_monitor"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "resource_monitor" = 'null' OR "resource_monitor" IS NULL;
```

---

## Important caveats

- **SUSPEND vs SUSPEND_IMMEDIATE:** `SUSPEND` waits for running queries to finish before suspending. `SUSPEND_IMMEDIATE` kills running queries immediately. Use `SUSPEND` for analytics workloads where killing mid-query is disruptive. Use `SUSPEND_IMMEDIATE` for dev/sandbox environments.
- **Resource monitor reset timing:** The credit quota resets at the start of each frequency window, not at midnight. A WEEKLY monitor created on a Wednesday resets the following Wednesday, not Monday.
- **Budget latency:** Budget spending data can lag up to 2 hours. Do not use budget spend figures for real-time enforcement.
- **One monitor per warehouse:** A warehouse can only have one resource monitor attached. Plan monitor scope (account vs. warehouse level) accordingly.
