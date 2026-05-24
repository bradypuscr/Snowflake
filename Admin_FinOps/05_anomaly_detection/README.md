# 05 — Anomaly Detection

Anomaly detection converts the weekly report from passive observation to proactive alerting. Instead of reviewing numbers manually every Monday, you get notified when something statistically unusual happens.

---

## How the z-score approach works

A z-score measures how many standard deviations a data point is from the mean of a reference window. For weekly spend:

- **z-score < 1.0:** Normal variation. No action needed.
- **z-score 1.0–2.0:** Elevated. Worth checking if there is a known reason (scheduled batch, month-end process).
- **z-score > 2.0:** Statistically unusual. Investigate. The 4-week rolling baseline adjusts for growth trends, so a z-score above 2 means the spike is large relative to recent behavior, not just relative to historical averages.

The 4-week window is a balance: wide enough to smooth noise, narrow enough to adapt to growth. Adjust to 8 or 12 weeks if your account has high natural variance.

---

## Files

| File | What it does |
|---|---|
| `01_zscore_baseline.sql` | Rolling baseline z-score for warehouse compute, per-warehouse anomalies, serverless, and storage |

---

## Automating the alert

The z-score query in this section is designed to be wrapped in a Snowflake Task. See `06_automation/04_anomaly_alert_task.sql` for the Task implementation that runs the query on a schedule and sends an email when the threshold is exceeded.

---

## Limitations

- The z-score requires at least 5 weeks of data to be meaningful. On new accounts, the baseline will be unreliable until data accumulates.
- Very low-spend warehouses (< 1 credit/week) will trigger false positives because a small absolute change produces a large z-score. Filter out low-spend warehouses with a minimum threshold.
- Seasonal patterns (month-end reporting, quarterly closes) will appear as anomalies. Document expected high-spend periods so the on-call team knows not to page someone at 11pm for a known quarterly run.
