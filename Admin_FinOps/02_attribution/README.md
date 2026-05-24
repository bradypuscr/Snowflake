# 02 — Attribution

Attribution answers the question: *who is responsible for this cost?* This section builds the data pipeline from raw tag metadata to cost-center-level reports, and documents what cannot be attributed and how to handle it.

---

## Execution order

1. `01_tag_setup.sql` — Define tags and apply them to objects. Run before any attribution query.
2. `02_warehouse_attribution.sql` — Attribute warehouse compute by cost center, team, and environment.
3. `03_user_query_attribution.sql` — Attribute costs at the user and query level.
4. `04_unattributable_costs.sql` — Document and estimate what cannot be directly attributed.

---

## Attribution accuracy levels

| What you are measuring | Accuracy | View used |
|---|---|---|
| Warehouse compute by warehouse | Exact | WAREHOUSE_METERING_HISTORY |
| Warehouse compute by cost center (tagged) | Exact (if tags are consistent) | WAREHOUSE_METERING_HISTORY + TAG_REFERENCES |
| Per-user compute | Weighted estimate | QUERY_ATTRIBUTION_HISTORY |
| Per-query compute | Rough estimate | QUERY_HISTORY (calculated) |
| Serverless by service type | Exact | Per-service views |
| Serverless by cost center | Partial (schema-level only) | Multiple views + TAG_REFERENCES |
| Storage by database | Exact | DATABASE_STORAGE_USAGE_HISTORY |
| Storage by cost center | Estimate (join to db tags) | DATABASE_STORAGE_USAGE_HISTORY + TAG_REFERENCES |
| Cloud services by user | Not available | N/A |
| AI/Cortex by team | Not available without query-level tags | METERING_DAILY_HISTORY |

---

## The untagged problem

In almost every account, the first attribution report shows a large "Untagged" bucket. This is not a data quality issue — it is a governance gap. Objects were created before tagging was established. The correct response is:

1. Use the untagged warehouse query in `02_warehouse_attribution.sql` to identify them
2. Tag them manually (or delegate to the owning team)
3. Set up tag enforcement (`01_governance/03_tag_enforcement.sql`) to prevent new gaps
4. Accept a small residual "Untagged" bucket for shared or unclear objects and allocate it proportionally

Do not filter out untagged spend — that makes your totals wrong and hides the gap from stakeholders.

---

## Latency considerations

- `TAG_REFERENCES` lags up to 3 hours. A tag applied today may not appear in attribution queries until later.
- `QUERY_ATTRIBUTION_HISTORY` lags up to 8 hours. Per-user costs from this morning may not be visible until the afternoon.
- Build your reports to pull from the previous day or previous week to avoid confusion with recent latency windows.
