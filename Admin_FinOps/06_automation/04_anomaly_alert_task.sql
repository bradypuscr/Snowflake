/*
================================================================================
  FILE: 06_automation/04_anomaly_alert_task.sql
  PURPOSE: Weekly task that runs z-score anomaly detection and sends an email
           alert when warehouse spend is statistically unusual.
  REQUIRES: FINOPS_ADMIN | EXECUTE TASK privilege | Email integration enabled
  SCHEDULE: Weekly on Monday at 08:00 UTC (runs after the weekly data settles)
================================================================================

  EMAIL SETUP REQUIREMENTS:
  ──────────────────────────
  SYSTEM$SEND_EMAIL() requires:
  1. An email notification integration created on the account (one-time setup by ACCOUNTADMIN)
  2. The sending email domain verified with Snowflake
  3. Recipient email addresses registered in Snowflake's notification allowlist

  If your account does not have email notifications configured, the task will
  still run the z-score detection and write results to FINOPS.ALERTS.ANOMALY_LOG.
  You can query that table manually or connect it to an external alerting system
  (PagerDuty, Slack webhook via External Function, etc.).
*/

USE ROLE ACCOUNTADMIN;  -- Need ACCOUNTADMIN to create the notification integration


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1: Create email notification integration (one-time, ACCOUNTADMIN)
-- ─────────────────────────────────────────────────────────────────────────────
-- ⚠️ Check if an integration already exists before creating a new one:
SHOW INTEGRATIONS;

CREATE NOTIFICATION INTEGRATION IF NOT EXISTS finops_email_integration
    TYPE            = EMAIL
    ENABLED         = TRUE
    COMMENT         = 'FinOps anomaly alert email notification integration.';

-- Grant FINOPS_ADMIN the ability to use this integration:
GRANT USAGE ON INTEGRATION finops_email_integration TO ROLE FINOPS_ADMIN;

USE ROLE FINOPS_ADMIN;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2: Create the anomaly detection procedure
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE FINOPS.UTILS.RUN_ANOMALY_CHECK()
RETURNS STRING
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
COMMENT = 'Runs weekly z-score anomaly detection. Writes to ANOMALY_LOG and sends email if z_score >= 2.0.'
AS $$
    const Z_SCORE_THRESHOLD = 2.0;
    const ALERT_EMAILS = 'finops@company.com,snowflake-admin@company.com';  // ⚠️ Replace

    // Query for current week's z-score
    var anomalySQL = `
        WITH weekly AS (
            SELECT
                DATE_TRUNC('week', USAGE_DATE) AS week_start,
                SUM(CREDITS_USED)              AS weekly_credits
            FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
            WHERE USAGE_DATE >= DATEADD('week', -6, CURRENT_DATE)
              AND SERVICE_TYPE = 'WAREHOUSE_METERING'
            GROUP BY 1
        ),
        with_baseline AS (
            SELECT
                week_start,
                weekly_credits,
                AVG(weekly_credits) OVER (
                    ORDER BY week_start ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING
                ) AS rolling_avg,
                STDDEV(weekly_credits) OVER (
                    ORDER BY week_start ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING
                ) AS rolling_stddev
            FROM weekly
        )
        SELECT
            week_start,
            ROUND(weekly_credits, 2) AS credits,
            ROUND(rolling_avg, 2) AS baseline_avg,
            ROUND((weekly_credits - rolling_avg) / NULLIF(rolling_stddev, 0), 2) AS z_score,
            ROUND(weekly_credits - rolling_avg, 2) AS credits_above_baseline
        FROM with_baseline
        WHERE rolling_avg IS NOT NULL
        ORDER BY week_start DESC
        LIMIT 1
    `;

    var stmt = snowflake.createStatement({ sqlText: anomalySQL });
    var result = stmt.execute();

    if (!result.next()) {
        return 'No anomaly data available (insufficient history for baseline).';
    }

    var weekStart       = result.getColumnValue('WEEK_START');
    var credits         = result.getColumnValue('CREDITS');
    var baselineAvg     = result.getColumnValue('BASELINE_AVG');
    var zScore          = result.getColumnValue('Z_SCORE');
    var creditsAbove    = result.getColumnValue('CREDITS_ABOVE_BASELINE');
    var shouldAlert     = zScore >= Z_SCORE_THRESHOLD;

    // Log the detection regardless of whether we alert
    var logSQL = `
        INSERT INTO FINOPS.ALERTS.ANOMALY_LOG
            (period_type, period_start, scope, metric, observed_value,
             baseline_avg, z_score, alert_sent)
        VALUES ('weekly', '${weekStart}', 'account', 'warehouse_compute',
                ${credits}, ${baselineAvg}, ${zScore}, ${shouldAlert})
    `;
    snowflake.createStatement({ sqlText: logSQL }).execute();

    if (!shouldAlert) {
        return `Week of ${weekStart}: z_score = ${zScore}. No alert needed.`;
    }

    // Send email alert
    var subject = `[Snowflake FinOps] Spend anomaly detected — week of ${weekStart}`;
    var body = `
Snowflake FinOps Anomaly Alert
===============================
Week of: ${weekStart}
Credits this week: ${credits}
4-week baseline avg: ${baselineAvg}
Credits above baseline: ${creditsAbove}
Z-score: ${zScore} (threshold: ${Z_SCORE_THRESHOLD})

This week's warehouse compute spend is ${zScore} standard deviations above the 4-week rolling average.

Next steps:
1. Review per-warehouse spend in WAREHOUSE_METERING_HISTORY for the week of ${weekStart}
2. Run 05_anomaly_detection/01_zscore_baseline.sql (Query 2) for per-warehouse z-scores
3. Check for unplanned batch jobs, new warehouses without AUTO_SUSPEND, or large query runs
4. Query FINOPS.ALERTS.ANOMALY_LOG for historical alert frequency

-- Sent by FINOPS.UTILS.RUN_ANOMALY_CHECK via FINOPS_ANOMALY_TASK
    `;

    var emailSQL = `
        CALL SYSTEM$SEND_EMAIL(
            'finops_email_integration',
            '${ALERT_EMAILS}',
            '${subject.replace(/'/g, "''")}',
            '${body.replace(/'/g, "''")}'
        )
    `;

    try {
        snowflake.createStatement({ sqlText: emailSQL }).execute();
        return `ALERT SENT: week of ${weekStart}, z_score = ${zScore}, credits = ${credits}`;
    } catch (emailErr) {
        // Email failed — log the error but don't fail the task
        // The anomaly is already recorded in ANOMALY_LOG
        return `z_score = ${zScore} (ALERT NOT SENT — email error: ${emailErr.message}). Check ANOMALY_LOG.`;
    }
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3: Create the weekly anomaly alert task
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TASK FINOPS.UTILS.FINOPS_ANOMALY_TASK
    WAREHOUSE   = FINOPS_WH
    SCHEDULE    = 'USING CRON 0 8 * * 1 UTC'   -- 08:00 UTC every Monday
    COMMENT     = 'Weekly anomaly detection task. Calls RUN_ANOMALY_CHECK, sends email if z_score >= 2.0.'
AS
    CALL FINOPS.UTILS.RUN_ANOMALY_CHECK();

-- Enable the task:
ALTER TASK FINOPS.UTILS.FINOPS_ANOMALY_TASK RESUME;


-- ─────────────────────────────────────────────────────────────────────────────
-- TEST: Run the procedure manually
-- ─────────────────────────────────────────────────────────────────────────────
CALL FINOPS.UTILS.RUN_ANOMALY_CHECK();

-- View the anomaly log:
SELECT *
FROM FINOPS.ALERTS.ANOMALY_LOG
ORDER BY detected_at DESC
LIMIT 20;


-- ─────────────────────────────────────────────────────────────────────────────
-- ALERT DEDUPLICATION: Check if we already alerted for this week
-- ─────────────────────────────────────────────────────────────────────────────
-- The procedure always writes to ANOMALY_LOG. If you want to suppress
-- repeat alerts for the same week (e.g., if the task is re-run manually),
-- add this check to the procedure before the INSERT:
/*
    var dedupSQL = `
        SELECT COUNT(*) AS cnt
        FROM FINOPS.ALERTS.ANOMALY_LOG
        WHERE period_start = '${weekStart}'
          AND scope = 'account'
          AND alert_sent = TRUE
    `;
    var dedup = snowflake.createStatement({ sqlText: dedupSQL }).execute();
    dedup.next();
    if (dedup.getColumnValue('CNT') > 0) {
        return `Already alerted for week of ${weekStart}. Skipping.`;
    }
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- TROUBLESHOOTING
-- ─────────────────────────────────────────────────────────────────────────────
/*
  ISSUE: "Email integration does not exist"
  FIX:   The notification integration must be created by ACCOUNTADMIN.
         Check SHOW INTEGRATIONS to see what exists. If no email integration
         exists, ask your account admin to create one or reach out to Snowflake support.

  ISSUE: Task runs successfully but no email received
  FIX:   1. Verify the recipient email is registered/allowlisted in Snowflake notifications.
         2. Check spam folder.
         3. Check ANOMALY_LOG — if ALERT_SENT = TRUE, the call succeeded on Snowflake's side.
         4. Verify the notification integration is TYPE = EMAIL and ENABLED = TRUE.

  ISSUE: z_score is NULL in the log
  FIX:   Insufficient history for the 4-week baseline. The z-score is NULL when
         fewer than 4 prior weeks of data exist. The task will start producing
         meaningful z-scores after 5+ weeks of metering data.

  ISSUE: Too many false positive alerts (z_score > 2 but spend is expected)
  FIX:   Document known high-spend periods (month-end, quarterly close) and either:
         a) Increase the threshold from 2.0 to 2.5 or 3.0
         b) Add a date-based suppression window in the procedure
         c) Widen the baseline window from 4 weeks to 6 or 8 weeks
*/
