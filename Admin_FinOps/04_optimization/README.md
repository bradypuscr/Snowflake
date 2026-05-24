# 04 — Optimization

Cost optimization addresses the gap between what you are paying and what you need to pay. This section identifies concrete waste patterns: warehouses running idle, warehouses sized incorrectly, and serverless services that are no longer earning their cost.

---

## Files

| File | What it finds |
|---|---|
| `01_idle_warehouses.sql` | Warehouses with AUTO_SUSPEND disabled, no recent activity, or very low utilization |
| `02_queue_and_sizing.sql` | Undersized warehouses (high queue time) and oversized warehouses (very short queries) |
| `03_serverless_audit.sql` | Search Optimization on unused tables, auto-clustering on already-optimal tables, idle Snowpipes |

---

## Expected findings and what to do

**Warehouse with AUTO_SUSPEND = 0 and significant spend:**
Set AUTO_SUSPEND to 60 seconds for interactive warehouses, 300 seconds for batch warehouses. Warehouses should never run with no auto-suspend unless a specific operational reason requires it (and that reason should be documented).

**Warehouse with high queue time (>20% of elapsed time in queue):**
The warehouse is undersized for its concurrent load. Options: increase size, enable multi-cluster, or split workloads onto separate warehouses.

**Warehouse with very short average query times but large size:**
The warehouse is oversized. Downsize by one tier. Snowflake charges the same credit rate regardless of whether the warehouse is busy or idle.

**Search Optimization on a table with no recent queries:**
Disable it. Search Optimization runs a continuous background process regardless of query activity. A table that is not queried does not need the index.

**Auto-clustering where reclustering bytes are declining over time:**
The table may have stabilized (clustering complete). Consider pausing auto-clustering and monitoring — a stable table does not need continuous reclustering. Enable it again if DML activity starts fragmenting the clustering again.

---

## Optimization cadence

Run optimization queries quarterly, or whenever a spike appears in a weekly report. Do not run them too frequently — Snowflake's optimization features are designed to be enabled and forgotten, and disabling them prematurely can hurt query performance.

Document every optimization decision with: what you changed, why, what the expected credit savings are, and a date to re-evaluate.
