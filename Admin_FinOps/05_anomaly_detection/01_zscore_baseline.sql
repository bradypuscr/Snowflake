/*
================================================================================
  FILE: 05_anomaly_detection/01_zscore_baseline.sql
  PURPOSE: Rolling z-score anomaly detection for compute, serverless, and storage.
           Identifies statistically unusual spending weeks without requiring
           manual threshold configuration.
  REQUIRES: FINOPS_ADMIN or FINOPS_VIEWER role
  KEY VIEW: SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
================================================================================

  Z-SCORE INTERPRETATION:
  ────────────────────────
  < 1.0    → Normal variation
  1.0–2.0  → Elevated — review if there is a known reason
  > 2.0    → Unusual — investigate
  > 3.0    → Very unusual — escalate

  BASELINE WINDOW: 4 weeks prior to the current week (not including current week).
  Adjust ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING to change the window size.
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 1: Account-level weekly z-score (all compute)
-- ─────────────────────────────────────────────────────────────────────────────
WITH weekly AS (
    SELECT
        DATE_TRUNC('week', USAGE_DATE)  AS week_start,
        SUM(CREDITS_USED)               AS weekly_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
    WHERE USAGE_DATE  >= DATEADD('week', -10, CURRENT_DATE)
      AND SERVICE_TYPE = 'WAREHOUSE_METERING'
    GROUP BY 1
),
with_baseline AS (
    SELECT
        week_start,
        weekly_credits,
        AVG(weekly_credits)    OVER (ORDER BY week_start
            ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS rolling_avg,
        STDDEV(weekly_credits) OVER (ORDER BY week_start
            ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS rolling_stddev
    FROM weekly
)
SELECT
    week_start,
    ROUND(weekly_credits, 2)                                        AS credits,
    ROUND(rolling_avg, 2)                                           AS baseline_avg,
    ROUND(rolling_stddev, 2)                                        AS baseline_stddev,
    ROUND((weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0), 2) AS z_score,
    CASE
        WHEN (weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0) > 3 THEN '🔴 CRITICAL'
        WHEN (weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0) > 2 THEN '🟡 ANOMALY'
        WHEN (weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0) > 1 THEN '🔵 ELEVATED'
        ELSE '✅ NORMAL'
    END AS status
FROM with_baseline
WHERE rolling_avg IS NOT NULL   -- exclude first 4 weeks (insufficient baseline)
ORDER BY week_start DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 2: Per-warehouse weekly z-score (last 10 weeks)
-- ─────────────────────────────────────────────────────────────────────────────
-- Identifies which specific warehouse caused an account-level anomaly.
-- Filter by minimum weekly credits to avoid noise from low-spend warehouses.
WITH wh_weekly AS (
    SELECT
        WAREHOUSE_NAME,
        DATE_TRUNC('week', START_TIME) AS week_start,
        SUM(CREDITS_USED)              AS weekly_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE START_TIME >= DATEADD('week', -10, CURRENT_DATE)
    GROUP BY 1, 2
),
with_baseline AS (
    SELECT
        WAREHOUSE_NAME,
        week_start,
        weekly_credits,
        AVG(weekly_credits)    OVER (PARTITION BY WAREHOUSE_NAME ORDER BY week_start
            ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS rolling_avg,
        STDDEV(weekly_credits) OVER (PARTITION BY WAREHOUSE_NAME ORDER BY week_start
            ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS rolling_stddev
    FROM wh_weekly
)
SELECT
    WAREHOUSE_NAME,
    week_start,
    ROUND(weekly_credits, 2)   AS credits,
    ROUND(rolling_avg, 2)      AS baseline_avg,
    ROUND((weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0), 2) AS z_score,
    CASE
        WHEN (weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0) > 2 THEN 'ANOMALY'
        WHEN (weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0) > 1 THEN 'ELEVATED'
        ELSE 'NORMAL'
    END AS status
FROM with_baseline
WHERE rolling_avg IS NOT NULL
  AND rolling_avg  > 1.0     -- filter out low-baseline warehouses to reduce noise
ORDER BY week_start DESC, z_score DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 3: Serverless spend anomaly detection (weekly)
-- ─────────────────────────────────────────────────────────────────────────────
WITH serverless_weekly AS (
    SELECT
        DATE_TRUNC('week', START_TIME) AS week_start,
        'Snowpipe'                     AS service,
        SUM(CREDITS_USED)              AS weekly_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
    WHERE START_TIME >= DATEADD('week', -10, CURRENT_DATE)
    GROUP BY 1

    UNION ALL
    SELECT DATE_TRUNC('week', START_TIME), 'Auto Clustering', SUM(CREDITS_USED)
    FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
    WHERE START_TIME >= DATEADD('week', -10, CURRENT_DATE)
    GROUP BY 1

    UNION ALL
    SELECT DATE_TRUNC('week', START_TIME), 'Serverless Tasks', SUM(CREDITS_USED)
    FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
    WHERE START_TIME >= DATEADD('week', -10, CURRENT_DATE)
    GROUP BY 1
),
with_baseline AS (
    SELECT
        service,
        week_start,
        weekly_credits,
        AVG(weekly_credits)    OVER (PARTITION BY service ORDER BY week_start
            ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS rolling_avg,
        STDDEV(weekly_credits) OVER (PARTITION BY service ORDER BY week_start
            ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS rolling_stddev
    FROM serverless_weekly
)
SELECT
    service,
    week_start,
    ROUND(weekly_credits, 4)   AS credits,
    ROUND(rolling_avg, 4)      AS baseline_avg,
    ROUND((weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0), 2) AS z_score,
    CASE
        WHEN (weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0) > 2 THEN 'ANOMALY'
        ELSE 'NORMAL'
    END AS status
FROM with_baseline
WHERE rolling_avg IS NOT NULL
ORDER BY week_start DESC, z_score DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 4: Storage growth anomaly (daily, last 60 days)
-- ─────────────────────────────────────────────────────────────────────────────
-- Unexpected storage growth spikes often indicate:
-- - A large table load without a corresponding delete
-- - A CLONE operation on a large database
-- - Failsafe accumulation from a high-churn table
WITH daily_storage AS (
    SELECT
        USAGE_DATE,
        (STORAGE_BYTES + FAILSAFE_BYTES) AS total_bytes
    FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
    WHERE USAGE_DATE >= DATEADD('day', -60, CURRENT_DATE)
),
with_growth AS (
    SELECT
        USAGE_DATE,
        total_bytes,
        ROUND((total_bytes - LAG(total_bytes) OVER (ORDER BY USAGE_DATE))
            / POWER(1024, 3), 2) AS day_over_day_gb_growth,
        AVG(total_bytes) OVER (ORDER BY USAGE_DATE ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING) AS rolling_avg_bytes,
        STDDEV(total_bytes - LAG(total_bytes) OVER (ORDER BY USAGE_DATE))
            OVER (ORDER BY USAGE_DATE ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING) AS rolling_stddev
    FROM daily_storage
)
SELECT
    USAGE_DATE,
    ROUND(total_bytes / POWER(1024, 4), 4)  AS total_tb,
    day_over_day_gb_growth,
    ROUND(day_over_day_gb_growth / NULLIF(rolling_stddev / POWER(1024, 3), 0), 2) AS growth_z_score,
    CASE
        WHEN day_over_day_gb_growth / NULLIF(rolling_stddev / POWER(1024, 3), 0) > 2
        THEN 'GROWTH SPIKE — investigate large loads or clones'
        ELSE 'NORMAL'
    END AS status
FROM with_growth
WHERE day_over_day_gb_growth IS NOT NULL
ORDER BY USAGE_DATE DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY 5: Current week anomaly summary (for email/alert automation)
-- ─────────────────────────────────────────────────────────────────────────────
-- Run this query in the anomaly alert Task (06_automation/04_anomaly_alert_task.sql).
-- Returns a single row with current week's z-score and a flag for alerting.
WITH weekly AS (
    SELECT
        DATE_TRUNC('week', USAGE_DATE) AS week_start,
        SUM(CREDITS_USED)              AS weekly_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
    WHERE USAGE_DATE  >= DATEADD('week', -6, CURRENT_DATE)
      AND SERVICE_TYPE = 'WAREHOUSE_METERING'
    GROUP BY 1
),
with_baseline AS (
    SELECT
        week_start,
        weekly_credits,
        AVG(weekly_credits)    OVER (ORDER BY week_start ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS rolling_avg,
        STDDEV(weekly_credits) OVER (ORDER BY week_start ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS rolling_stddev
    FROM weekly
)
SELECT
    week_start,
    ROUND(weekly_credits, 2)                                               AS credits,
    ROUND(rolling_avg, 2)                                                  AS baseline_avg,
    ROUND((weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0), 2)   AS z_score,
    -- Alert flag: TRUE if this week should trigger a notification
    CASE WHEN (weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0) >= 2.0
         THEN TRUE ELSE FALSE END                                           AS should_alert,
    ROUND(weekly_credits - rolling_avg, 2)                                 AS credits_above_baseline
FROM with_baseline
WHERE rolling_avg IS NOT NULL
ORDER BY week_start DESC
LIMIT 1;
