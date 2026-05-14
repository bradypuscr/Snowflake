-- ============================================================
-- Procedure : UTIL_DB.ADMIN.SEND_ACCOUNT_USAGE_REPORT
-- Schema    : UTIL_DB.ADMIN
-- Language  : Python 3.11 (Snowpark)
-- Owner     : ACCOUNTADMIN (EXECUTE AS CALLER)
-- Version   : 3.0
-- ============================================================
--
-- PURPOSE
-- -------
-- Generates a comprehensive, Gmail-compatible HTML account usage report
-- and delivers it via email to every active ACCOUNTADMIN user.
-- The report covers two modes — WEEKLY and MONTHLY — and includes:
--   • Credit consumption summary vs. the prior period
--   • Credit breakdown by service type
--   • Top consumers (users and warehouses)
--   • AI / Cortex usage (credits and per-user query counts)
--   • Daily credit trend for the reporting window
--   • Top 10 longest-running queries with disk-spill detection
--   • Warehouse efficiency metrics (queue time, spill, credits-per-query)
--   • Resource monitor status with color-coded utilization alerts
--   • Security & governance: failed logins, ACCOUNTADMIN role usage,
--     and users inactive for 30+ days
--
-- PARAMETER
-- ---------
--   REPORT_TYPE  VARCHAR   'WEEKLY'  — last 7 days vs. the 7 days before that.
--                                      Also shows the month-to-date credit total.
--                           'MONTHLY' — the full prior calendar month vs. the
--                                      month before that.
--
-- RETURNS
-- -------
--   VARCHAR  Human-readable summary, e.g.:
--            "Report sent to: 3 recipients. Failed: 0"
--            On early exit:
--            "Invalid report type. Use WEEKLY or MONTHLY."
--            "No ACCOUNTADMIN users with valid emails found."
--            "Error getting recipients: <exception>"
--
-- DATE RANGES
-- -----------
--   WEEKLY  : [today-7d, today)   — excludes today (incomplete day)
--   MONTHLY : [first_of_last_month, first_of_current_month)
--             This always covers a complete, closed calendar month.
--
-- RECIPIENT DETECTION
-- -------------------
--   Uses SHOW GRANTS OF ROLE ACCOUNTADMIN + SHOW USERS (real-time) rather
--   than SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS + USERS (up to 2-hour lag).
--   This ensures newly-granted admins receive the report immediately and
--   recently-revoked users are excluded.
--
-- EMAIL FORMAT
-- ------------
--   Content-Type: text/html
--   All styling is done with inline CSS (no <style> block, no CSS classes).
--   The Executive Summary section uses an HTML <table> layout instead of
--   CSS flexbox / display:inline-block, both of which are stripped or
--   ignored by Gmail and many corporate mail clients.
--   Row alternation is computed in Python (idx % 2) rather than relying on
--   CSS :nth-child selectors, which are unsupported in Gmail.
--   Alert colors (warn / alert / critical) are rendered as bgcolor attributes
--   AND inline style attributes on <tr> elements for maximum compatibility.
--
-- SQL INJECTION PREVENTION
-- ------------------------
--   All ACCOUNT_USAGE queries use Snowpark parameterized queries
--   (session.sql("...", params=[...])) — no string concatenation for values.
--   The helper sql_esc() double-escapes single quotes for the SYSTEM$SEND_EMAIL
--   CALL statement, which cannot be parameterized in the same way.
--   html.escape() is applied to every database-sourced value inserted into HTML
--   to prevent XSS in mail clients that render raw HTML.
--
-- AI / CORTEX DETECTION
-- ----------------------
--   Cortex queries are identified by matching fully-qualified function names
--   (e.g., SNOWFLAKE.CORTEX.COMPLETE, CORTEX.SUMMARIZE) in QUERY_TEXT.
--   This avoids false positives from the generic '%CORTEX%' pattern, which
--   would match comments, column names, or string literals containing that word.
--   Cortex credit consumption is read from METERING_DAILY_HISTORY filtered to
--   SERVICE_TYPE = 'AI_SERVICES', which is the authoritative source.
--
-- DEPENDENCIES
-- ------------
--   Views  : SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
--            SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
--            SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
--            SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
--            SNOWFLAKE.ACCOUNT_USAGE.USERS
--   Commands: SHOW GRANTS OF ROLE ACCOUNTADMIN
--             SHOW USERS
--             SHOW WAREHOUSES
--             SHOW RESOURCE MONITORS
--   Integration: MY_EMAIL_INTEGRATION  (notification integration, must exist)
--
-- PERMISSIONS REQUIRED (caller)
-- ------------------------------
--   ACCOUNTADMIN role (grants access to all ACCOUNT_USAGE views and SHOW cmds)
--
-- TYPICAL USAGE
-- -------------
--   -- Send the weekly report manually:
--   CALL UTIL_DB.ADMIN.SEND_ACCOUNT_USAGE_REPORT('WEEKLY');
--
--   -- Schedule weekly every Monday at 07:00 UTC:
--   CREATE OR REPLACE TASK UTIL_DB.ADMIN.WEEKLY_USAGE_REPORT
--     WAREHOUSE = ADMIN_WH
--     SCHEDULE  = 'USING CRON 0 7 * * 1 UTC'
--   AS
--     CALL UTIL_DB.ADMIN.SEND_ACCOUNT_USAGE_REPORT('WEEKLY');
--
-- KNOWN LIMITATIONS
-- -----------------
--   • ACCOUNT_USAGE views have up to 45-minute ingestion latency for
--     QUERY_HISTORY and up to 3 hours for METERING_DAILY_HISTORY.
--     Running the report too early in the day may undercount the last day.
--   • SHOW WAREHOUSES and SHOW RESOURCE MONITORS reflect current state only
--     (no historical data); a warehouse suspended since last night would not
--     appear in the always-on list.
--   • The email body grows with data volume. Very large accounts with hundreds
--     of warehouses and users may approach mail-client size limits (~10 MB).
-- ============================================================

CREATE OR REPLACE PROCEDURE UTIL_DB.ADMIN.SEND_ACCOUNT_USAGE_REPORT("REPORT_TYPE" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
def main(session, report_type):
    """
    Entry point for the account usage report procedure.

    Parameters
    ----------
    session     : snowflake.snowpark.Session
                  Injected automatically by Snowflake when the procedure runs.
    report_type : str
                  'WEEKLY' or 'MONTHLY' (case-insensitive).

    Returns
    -------
    str
        A short status message describing how many emails were sent or
        the reason for an early exit.
    """
    from datetime import datetime, timedelta
    from html import escape  # Used to neutralise XSS in database-sourced values

    # ------------------------------------------------------------------
    # HELPER: SQL string escaping
    # ------------------------------------------------------------------
    def sql_esc(val):
        """
        Escapes single quotes by doubling them so the value can be safely
        embedded inside a single-quoted SQL string literal.

        This is necessary for the SYSTEM$SEND_EMAIL CALL statement, which
        must be built as a string (Snowpark does not support binding
        parameters for CALL statements).  All ACCOUNT_USAGE data queries
        use parameterized session.sql(..., params=[...]) instead, which is
        the preferred approach and does not require this function.

        Parameters
        ----------
        val : any
            Value to escape; will be coerced to str first.

        Returns
        -------
        str
            SQL-safe string with single quotes doubled.
        """
        return str(val).replace("'", "''")

    # ------------------------------------------------------------------
    # INLINE STYLE CONSTANTS
    # ------------------------------------------------------------------
    # All styling is expressed as inline CSS attributes rather than a
    # <style> block.  Gmail strips <style> blocks from received messages,
    # making class-based selectors (.warn, .critical, etc.) invisible.
    # Inline styles survive Gmail's sanitisation pipeline intact.
    #
    # The Executive Summary uses an HTML <table> instead of CSS flex /
    # display:inline-block because flexbox is not supported in Gmail.
    # Row alternation is computed in Python (see tr() helper below) rather
    # than relying on CSS :nth-child(), which Gmail also ignores.
    #
    # Each <tr> carries both bgcolor="..." (legacy HTML attribute, honoured
    # by Outlook and older webmail) and style="background-color:..." (CSS,
    # honoured by Gmail, Apple Mail, and modern clients).
    # ------------------------------------------------------------------
    S_H1    = "font-family:Arial,sans-serif;font-size:24px;color:#29B5E8;margin:0 0 10px 0;"
    S_H2    = "font-family:Arial,sans-serif;font-size:18px;color:#333;border-bottom:2px solid #29B5E8;padding-bottom:5px;margin-top:30px;"
    S_H3    = "font-family:Arial,sans-serif;font-size:15px;color:#555;margin-top:20px;"
    S_P     = "font-family:Arial,sans-serif;font-size:14px;color:#333;margin:5px 0;"
    S_PNOTE = "font-family:Arial,sans-serif;font-size:12px;color:#666;margin:5px 0;"
    S_TABLE = "border-collapse:collapse;width:100%;margin:15px 0;"
    S_TH    = "background-color:#29B5E8;color:white;padding:10px;text-align:left;font-family:Arial,sans-serif;font-size:14px;"
    S_TD    = "padding:8px;border-bottom:1px solid #ddd;font-family:Arial,sans-serif;font-size:14px;color:#333;"
    S_MONO  = "padding:8px;border-bottom:1px solid #ddd;font-family:monospace;font-size:12px;color:#555;"
    S_OK    = "font-family:Arial,sans-serif;font-size:14px;color:#28a745;margin:5px 0;"

    # Alert background colours — applied to entire <tr> rows.
    # Thresholds used throughout the report:
    #   warn     : mild issue  (queue >10s, failed logins >=5, rm usage >=60%)
    #   alert    : moderate    (rm usage >=80%)
    #   critical : action req. (queue >30s, failed logins >=10, rm usage >=95%,
    #                           never-suspended warehouse, user inactive >90d)
    BG_ALT      = "#f9f9f9"   # alternating row tint (even rows are white)
    BG_WARN     = "#fff3cd"   # yellow
    BG_ALERT    = "#ffe0b2"   # orange
    BG_CRITICAL = "#ffcccc"   # red

    # ------------------------------------------------------------------
    # HELPER: row background colour
    # ------------------------------------------------------------------
    def row_bg(idx, level=None):
        """
        Returns the appropriate background colour hex string for a table row.

        Alert levels take priority over alternating-row tinting so that a
        warning row is always visually distinct regardless of its position.

        Parameters
        ----------
        idx   : int   Zero-based row index within the current table.
        level : str   One of 'critical', 'alert', 'warn', 'spill', or None.
                      'spill' maps to the same yellow as 'warn'.

        Returns
        -------
        str  Hex colour string, or empty string for uncoloured (white) rows.
        """
        if level == "critical":           return BG_CRITICAL
        if level == "alert":              return BG_ALERT
        if level in ("warn", "spill"):    return BG_WARN
        return BG_ALT if idx % 2 == 1 else ""

    def tr(idx, level=None):
        """
        Builds an opening <tr> tag with both bgcolor attribute and inline style.
        Returns plain '<tr>' when no colour is needed (even, unalerted rows).
        """
        bg = row_bg(idx, level)
        return "<tr bgcolor='" + bg + "' style='background-color:" + bg + ";'>" if bg else "<tr>"

    def th(text):
        """
        Returns a styled <th> element with the Snowflake blue header colour.

        WARNING: this function does NOT apply html.escape() internally.
        All arguments must be hardcoded string literals or values that have
        already been escaped by the caller.  Never pass a database-sourced
        value directly — use td(escape(value)) instead.
        """
        return "<th style='" + S_TH + "'>" + text + "</th>"

    def td(text, mono=False):
        """
        Returns a styled <td> element.

        Parameters
        ----------
        text  : str   HTML-safe cell content (caller is responsible for escaping).
        mono  : bool  If True, renders in monospace (used for query previews).
        """
        s = S_MONO if mono else S_TD
        return "<td style='" + s + "'>" + text + "</td>"

    def metric_cell(value, label):
        """
        Returns a <td> containing a large metric value and a small descriptive
        label, used in the Executive Summary table.

        Parameters
        ----------
        value : str  Pre-formatted numeric string (e.g. '1,234.56').
        label : str  Short descriptor shown below the value.
        """
        return (
            "<td style='text-align:center;padding:20px;vertical-align:top;'>"
            "<div style='font-size:28px;font-weight:bold;color:#29B5E8;"
            "font-family:Arial,sans-serif;'>" + value + "</div>"
            "<div style='font-size:12px;color:#666;margin-top:5px;"
            "font-family:Arial,sans-serif;'>" + label + "</div>"
            "</td>"
        )

    def section_header(title):
        """
        Returns a full-width colored band used as a visual section divider.
        Separates the four logical sections of the report:
          1 · Overview  |  2 · Cost Breakdown  |
          3 · Performance & Efficiency  |  4 · Security & Governance

        Parameters
        ----------
        title : str  Hardcoded section title — no escaping needed.
        """
        return (
            "<div style='background-color:#1a6e94;color:white;"
            "padding:8px 15px;font-family:Arial,sans-serif;"
            "font-size:15px;font-weight:bold;margin:35px 0 15px 0;'>"
            + title + "</div>"
        )

    # ------------------------------------------------------------------
    # ACCOUNT METADATA
    # ------------------------------------------------------------------
    # CURRENT_ORGANIZATION_NAME() and CURRENT_ACCOUNT() are evaluated at
    # runtime, making the procedure portable across dev / staging / prod
    # accounts without any hardcoded strings.
    report_type = report_type.upper()
    today = datetime.now()

    account_info = session.sql(
        "SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT() AS FULL_ACCOUNT"
    ).collect()[0]
    account_name = account_info["FULL_ACCOUNT"]

    # ------------------------------------------------------------------
    # DATE RANGE CALCULATION
    # ------------------------------------------------------------------
    # WEEKLY  : end_date is today (exclusive upper bound).
    #           start_date is today minus 7 days.
    #           A second "previous period" window of identical length is
    #           computed for the % change indicator in the Executive Summary.
    #           An additional month-to-date total is included so recipients
    #           can track cumulative spend alongside the weekly delta.
    #
    # MONTHLY : covers the complete prior calendar month (not the rolling
    #           last-30-days) so the report is stable when re-run later
    #           in the same month and matches invoice periods.
    # ------------------------------------------------------------------
    if report_type == "WEEKLY":
        end_date          = today.date()
        start_date        = end_date - timedelta(days=7)
        prev_end_date     = start_date
        prev_start_date   = prev_end_date - timedelta(days=7)
        week_num          = today.isocalendar()[1]
        year              = today.year
        subject           = "[ACME CORP] Account Usage Report: Week " + str(week_num) + "/" + str(year)
        period_label      = ("Week " + str(week_num) + " ("
                             + start_date.strftime("%b %d") + " - "
                             + end_date.strftime("%b %d, %Y") + ")")
        prev_period_label = "Previous Week"

    elif report_type == "MONTHLY":
        first_of_current  = today.replace(day=1)
        end_date          = first_of_current - timedelta(days=1)   # last day of prior month
        start_date        = end_date.replace(day=1)                # first day of prior month
        prev_end_date     = start_date - timedelta(days=1)
        prev_start_date   = prev_end_date.replace(day=1)
        month_name        = start_date.strftime("%B %Y")
        subject           = "[ACME CORP] Account Usage Report: " + month_name
        period_label      = month_name
        prev_period_label = prev_start_date.strftime("%B %Y")
    else:
        return "Invalid report type. Use WEEKLY or MONTHLY."

    # ------------------------------------------------------------------
    # RECIPIENT DETECTION
    # ------------------------------------------------------------------
    # Strategy: SHOW GRANTS OF ROLE ACCOUNTADMIN → SHOW USERS (real-time).
    #
    # Alternative considered and rejected:
    #   SELECT email FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
    #   JOIN SNOWFLAKE.ACCOUNT_USAGE.USERS ...
    # ACCOUNT_USAGE views carry up to 2 hours of ingestion latency.
    # A new admin added moments before the report runs would be missed;
    # a revoked admin would still appear.  SHOW commands are always
    # current and are therefore used here and in the DB report procedure
    # for consistency.
    #
    # The two-step approach is necessary because SHOW GRANTS returns
    # grantee names but not email addresses; SHOW USERS provides emails
    # but requires the list of names to filter by.
    #
    # sql_esc() is applied to each username before building the IN (...)
    # filter to guard against usernames containing single quotes.
    # ------------------------------------------------------------------
    try:
        session.sql("SHOW GRANTS OF ROLE ACCOUNTADMIN").collect()
        users_df = session.sql("""
            SELECT "grantee_name" AS user_name
            FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
            WHERE "granted_to" = 'USER'
        """).collect()
        user_list = [row["USER_NAME"] for row in users_df]

        if not user_list:
            return "No users found with ACCOUNTADMIN role"

        session.sql("SHOW USERS").collect()
        # Why f-string interpolation instead of params=[...] here:
        # Snowpark parameterized queries do not support binding a dynamic
        # number of values for an IN (...) clause.  The values come from
        # Snowflake's own SHOW GRANTS result (not from external user input),
        # and each name is individually escaped with sql_esc() before being
        # embedded, so the injection surface is effectively zero.
        user_filter = ",".join(["'" + sql_esc(u) + "'" for u in user_list])
        email_df = session.sql(f"""
            SELECT "email"
            FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
            WHERE "name" IN ({user_filter})
            AND "email" IS NOT NULL AND "email" != ''
        """).collect()
        recipients = [row["email"] for row in email_df if row["email"]]
    except Exception as e:
        return "Error getting recipients: " + str(e)

    if not recipients:
        return "No ACCOUNTADMIN users with valid emails found."

    # ------------------------------------------------------------------
    # DATA QUERIES — CREDITS & CONSUMPTION
    # ------------------------------------------------------------------
    # All queries use Snowpark parameterised execution (params=[...]).
    # This prevents SQL injection regardless of the content of the dates
    # or any other parameter, and improves query plan reuse.
    #
    # Date bounds are passed as strings ('YYYY-MM-DD') because Snowflake's
    # USAGE_DATE column is of type DATE and implicit casting from VARCHAR
    # works correctly in this context.
    # ------------------------------------------------------------------

    # Overall credit totals for the current and previous period.
    # COMPUTE credits = virtual warehouse time.
    # CLOUD_SERVICES credits = metadata operations, query compilation, etc.
    # Both are sourced from METERING_DAILY_HISTORY which aggregates by day.
    current_summary = session.sql(
        "SELECT ROUND(SUM(CREDITS_USED), 2) AS TOTAL_CREDITS, "
        "ROUND(SUM(CREDITS_USED_COMPUTE), 2) AS COMPUTE_CREDITS, "
        "ROUND(SUM(CREDITS_USED_CLOUD_SERVICES), 2) AS CLOUD_CREDITS "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY "
        "WHERE USAGE_DATE >= ? AND USAGE_DATE < ?",
        params=[str(start_date), str(end_date)]
    ).collect()[0]

    prev_summary = session.sql(
        "SELECT ROUND(SUM(CREDITS_USED), 2) AS TOTAL_CREDITS "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY "
        "WHERE USAGE_DATE >= ? AND USAGE_DATE < ?",
        params=[str(prev_start_date), str(prev_end_date)]
    ).collect()[0]

    current_total   = float(current_summary["TOTAL_CREDITS"] or 0)
    compute_credits = float(current_summary["COMPUTE_CREDITS"] or 0)
    cloud_credits   = float(current_summary["CLOUD_CREDITS"] or 0)
    prev_total      = float(prev_summary["TOTAL_CREDITS"] or 0)

    # Percentage change vs. prior period.
    # Guard against division by zero when there was zero spend last period.
    # Three distinct cases are handled:
    #   pct_change > 0  → spending increased  (red, "UP")
    #   pct_change < 0  → spending decreased  (green, "DOWN")
    #   pct_change == 0 → no change           (grey, "=")
    # This avoids the original bug where 0% change was displayed as "DOWN ↓"
    # in green, which was both visually and semantically incorrect.
    pct_change = ((current_total - prev_total) / prev_total * 100) if prev_total > 0 else 0

    if pct_change > 0:
        change_color, change_arrow = "#dc3545", "UP"
    elif pct_change < 0:
        change_color, change_arrow = "#28a745", "DOWN"
    else:
        change_color, change_arrow = "#888888", "="

    # Month-to-date total — only meaningful in WEEKLY mode.
    # Shows accumulated spend since the first of the current month so
    # recipients can track progress against monthly budgets even when
    # looking at a weekly report.
    mtd_credits = 0
    if report_type == "WEEKLY":
        mtd_result  = session.sql(
            "SELECT ROUND(SUM(CREDITS_USED), 2) AS MTD_CREDITS "
            "FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY "
            "WHERE USAGE_DATE >= DATE_TRUNC('MONTH', CURRENT_DATE())"
        ).collect()[0]
        mtd_credits = float(mtd_result["MTD_CREDITS"] or 0)

    # Credits broken down by SERVICE_TYPE (COMPUTE, CLOUD_SERVICES,
    # SERVERLESS_TASK, AI_SERVICES, etc.).  Useful for understanding
    # which Snowflake feature is driving the spend.
    services = session.sql(
        "SELECT SERVICE_TYPE, ROUND(SUM(CREDITS_USED), 2) AS CREDITS "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY "
        "WHERE USAGE_DATE >= ? AND USAGE_DATE < ? "
        "GROUP BY SERVICE_TYPE ORDER BY CREDITS DESC",
        params=[str(start_date), str(end_date)]
    ).collect()

    # Top 15 users ranked by total elapsed query time (hours).
    # HOURS is used as the primary sort key instead of query count because
    # a user with 5 long-running queries has a greater compute impact than
    # one with 500 sub-second queries.
    # CLOUD_CREDITS from QUERY_HISTORY reflects per-query cloud services
    # usage (metadata lookups, compilation), distinct from the warehouse
    # compute credits in METERING_DAILY_HISTORY.
    users = session.sql(
        "SELECT USER_NAME, COUNT(*) AS QUERY_COUNT, "
        "ROUND(SUM(TOTAL_ELAPSED_TIME)/1000/60/60, 2) AS HOURS, "
        "ROUND(SUM(CREDITS_USED_CLOUD_SERVICES), 2) AS CLOUD_CREDITS "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY "
        "WHERE START_TIME >= ? AND START_TIME < ? AND USER_NAME IS NOT NULL "
        "GROUP BY USER_NAME ORDER BY HOURS DESC LIMIT 15",
        params=[str(start_date), str(end_date)]
    ).collect()

    # Top 15 warehouses by total virtual warehouse credits.
    # WAREHOUSE_METERING_HISTORY records credit consumption per warehouse
    # per hour of active use, independent of which queries ran in it.
    warehouses = session.sql(
        "SELECT WAREHOUSE_NAME, ROUND(SUM(CREDITS_USED), 2) AS CREDITS, "
        "COUNT(*) AS METERING_EVENTS "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY "
        "WHERE START_TIME >= ? AND START_TIME < ? "
        "GROUP BY WAREHOUSE_NAME ORDER BY CREDITS DESC LIMIT 15",
        params=[str(start_date), str(end_date)]
    ).collect()

    # Top 15 user-warehouse combinations ranked by hours.
    # Complements the standalone user and warehouse lists by identifying
    # which users are driving consumption on which warehouses — useful for
    # right-sizing or isolating workloads onto dedicated warehouses.
    user_wh = session.sql(
        "SELECT USER_NAME, WAREHOUSE_NAME, COUNT(*) AS QUERY_COUNT, "
        "ROUND(SUM(TOTAL_ELAPSED_TIME)/1000/60/60, 2) AS HOURS "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY "
        "WHERE START_TIME >= ? AND START_TIME < ? "
        "AND USER_NAME IS NOT NULL AND WAREHOUSE_NAME IS NOT NULL "
        "GROUP BY USER_NAME, WAREHOUSE_NAME ORDER BY HOURS DESC LIMIT 15",
        params=[str(start_date), str(end_date)]
    ).collect()

    # ------------------------------------------------------------------
    # DATA QUERIES — AI / CORTEX
    # ------------------------------------------------------------------
    # Cortex query detection uses fully-qualified function names rather than
    # the generic '%CORTEX%' pattern.  The generic pattern would produce false
    # positives for:
    #   • Column names or table names containing the word "cortex"
    #   • SQL comments mentioning "cortex"
    #   • String literals with that substring
    # By matching SNOWFLAKE.CORTEX.<function> or CORTEX.<function>( we restrict
    # matches to actual Cortex function calls.  The list covers all LLM inference
    # functions available as of the procedure's last revision; extend it if
    # Snowflake adds new Cortex functions.
    #
    # AI credit consumption covers all Cortex-related SERVICE_TYPEs:
    #   AI_SERVICES          — LLM inference functions (COMPLETE, SUMMARIZE, etc.)
    #   CORTEX_AGENTS        — Cortex Agents (multi-step LLM workflows)
    #   CORTEX_CODE_SNOWSIGHT — Cortex Code interactions in the Snowsight UI
    #   CORTEX_CODE_CLI      — Cortex usage from the Snowflake CLI / extensions
    # These are the four Cortex service types confirmed present in this account.
    # Using a single IN (...) filter ensures all Cortex spend is captured even
    # when credits are split across multiple types in the same period.
    # ------------------------------------------------------------------
    ai_users = session.sql(
        "SELECT USER_NAME, COUNT(*) AS AI_QUERIES "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY "
        "WHERE START_TIME >= ? AND START_TIME < ? "
        "AND (QUERY_TEXT ILIKE '%SNOWFLAKE.CORTEX.%' "        # namespace-qualified calls
        "  OR QUERY_TEXT ILIKE '%CORTEX.COMPLETE(%' "         # LLM completion
        "  OR QUERY_TEXT ILIKE '%CORTEX.SUMMARIZE(%' "        # text summarisation
        "  OR QUERY_TEXT ILIKE '%CORTEX.SENTIMENT(%' "        # sentiment analysis
        "  OR QUERY_TEXT ILIKE '%CORTEX.TRANSLATE(%' "        # language translation
        "  OR QUERY_TEXT ILIKE '%CORTEX.EXTRACT_ANSWER(%') "  # Q&A extraction
        "GROUP BY USER_NAME ORDER BY AI_QUERIES DESC LIMIT 10",
        params=[str(start_date), str(end_date)]
    ).collect()

    # Total Cortex credits — sum across all four service types.
    ai_credits_result = session.sql(
        "SELECT ROUND(SUM(CREDITS_USED), 4) AS AI_CREDITS "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY "
        "WHERE USAGE_DATE >= ? AND USAGE_DATE < ? "
        "AND SERVICE_TYPE IN ("
        "  'AI_SERVICES', 'CORTEX_AGENTS',"
        "  'CORTEX_CODE_SNOWSIGHT', 'CORTEX_CODE_CLI')",
        params=[str(start_date), str(end_date)]
    ).collect()[0]
    ai_credits = float(ai_credits_result["AI_CREDITS"] or 0)

    # Cortex credits broken down by service type — shows which Cortex product
    # is driving the spend (LLM functions vs. Agents vs. Snowsight vs. CLI).
    cortex_by_type = session.sql(
        "SELECT SERVICE_TYPE, ROUND(SUM(CREDITS_USED), 4) AS CREDITS "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY "
        "WHERE USAGE_DATE >= ? AND USAGE_DATE < ? "
        "AND SERVICE_TYPE IN ("
        "  'AI_SERVICES', 'CORTEX_AGENTS',"
        "  'CORTEX_CODE_SNOWSIGHT', 'CORTEX_CODE_CLI') "
        "GROUP BY SERVICE_TYPE ORDER BY CREDITS DESC",
        params=[str(start_date), str(end_date)]
    ).collect()

    # Daily credit trend for the report window (7 or 30 days).
    # Provides a day-by-day view to spot anomalies such as a single day with
    # unusually high spend (runaway query, accidental full-table scan, etc.).
    trend_days  = 7 if report_type == "WEEKLY" else 30
    trend_start = end_date - timedelta(days=trend_days)
    trend = session.sql(
        "SELECT USAGE_DATE, ROUND(SUM(CREDITS_USED), 2) AS DAILY_CREDITS "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY "
        "WHERE USAGE_DATE >= ? AND USAGE_DATE < ? "
        "GROUP BY USAGE_DATE ORDER BY USAGE_DATE",
        params=[str(trend_start), str(end_date)]
    ).collect()

    # ------------------------------------------------------------------
    # DATA QUERIES — PERFORMANCE: EXPENSIVE QUERIES
    # ------------------------------------------------------------------
    # Top 10 queries ranked by wall-clock elapsed time.
    # Includes disk-spill metrics (local and remote) which indicate that
    # the query exceeded the warehouse's available memory.  Spill to remote
    # storage is particularly expensive in terms of both latency and cost.
    # Spilled rows are highlighted in yellow in the report.
    #
    # QUERY_TEXT is truncated to 200 characters for email readability;
    # the full text is available in QUERY_HISTORY by QUERY_ID if needed.
    # Only EXECUTION_STATUS = 'SUCCESS' rows are included — failed queries
    # are covered separately in the security section via error analysis.
    # ------------------------------------------------------------------
    expensive_queries = session.sql(
        "SELECT USER_NAME, WAREHOUSE_NAME, "
        "ROUND(TOTAL_ELAPSED_TIME/1000, 1) AS ELAPSED_SEC, "
        "ROUND(BYTES_SPILLED_TO_LOCAL_STORAGE/POWER(1024,3), 3) AS SPILL_LOCAL_GB, "
        "ROUND(BYTES_SPILLED_TO_REMOTE_STORAGE/POWER(1024,3), 3) AS SPILL_REMOTE_GB, "
        "LEFT(QUERY_TEXT, 200) AS QUERY_PREVIEW "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY "
        "WHERE START_TIME >= ? AND START_TIME < ? "
        "AND EXECUTION_STATUS = 'SUCCESS' "
        "ORDER BY TOTAL_ELAPSED_TIME DESC LIMIT 10",
        params=[str(start_date), str(end_date)]
    ).collect()

    # ------------------------------------------------------------------
    # DATA QUERIES — PERFORMANCE: WAREHOUSE EFFICIENCY
    # ------------------------------------------------------------------
    # Aggregates per-warehouse performance indicators from QUERY_HISTORY.
    # Key metrics:
    #
    #   AVG_QUEUE_SEC  — average time queries spent waiting before execution.
    #                    Consistently high queue time indicates the warehouse
    #                    is undersized or overloaded; consider scaling up or
    #                    creating a dedicated warehouse for that workload.
    #                    Thresholds: >10s = warn (yellow), >30s = critical (red).
    #
    #   SPILL_QUERIES  — count of queries that overflowed to disk (local or
    #                    remote storage).  Even a small number of spill events
    #                    can dominate elapsed time; the root cause is typically
    #                    missing filters, Cartesian joins, or large sorts.
    #
    #   TOTAL_REMOTE_SPILL_GB — remote spill is billed as cloud storage I/O
    #                    and can add meaningful cost on top of compute credits.
    #
    # The SHOW WAREHOUSES check below complements this with static configuration:
    # a warehouse with AUTO_SUSPEND = 0 never suspends and burns credits even
    # when idle.  This is a common misconfiguration in shared environments.
    # ------------------------------------------------------------------
    wh_efficiency = session.sql(
        "SELECT WAREHOUSE_NAME, COUNT(*) AS QUERY_COUNT, "
        "ROUND(AVG(TOTAL_ELAPSED_TIME)/1000, 1) AS AVG_ELAPSED_SEC, "
        "ROUND(AVG(QUEUED_OVERLOAD_TIME + QUEUED_PROVISIONING_TIME)/1000, 1) AS AVG_QUEUE_SEC, "
        "SUM(CASE WHEN BYTES_SPILLED_TO_LOCAL_STORAGE > 0 "
        "         OR BYTES_SPILLED_TO_REMOTE_STORAGE > 0 THEN 1 ELSE 0 END) AS SPILL_QUERIES, "
        "ROUND(SUM(BYTES_SPILLED_TO_REMOTE_STORAGE)/POWER(1024,3), 2) AS TOTAL_REMOTE_SPILL_GB "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY "
        "WHERE START_TIME >= ? AND START_TIME < ? AND WAREHOUSE_NAME IS NOT NULL "
        "GROUP BY WAREHOUSE_NAME ORDER BY AVG_QUEUE_SEC DESC LIMIT 15",
        params=[str(start_date), str(end_date)]
    ).collect()

    # Identify warehouses with AUTO_SUSPEND disabled (auto_suspend = 0).
    # SHOW WAREHOUSES returns real-time configuration, unlike ACCOUNT_USAGE
    # which reflects historical snapshots.
    # RESULT_SCAN(LAST_QUERY_ID()) reads the result set of the immediately
    # preceding SHOW command in the same session.  These two statements must
    # remain adjacent — any intervening SQL would update LAST_QUERY_ID().
    #
    # Wrapped in try/except so that a permission error or transient failure
    # degrades gracefully to an empty list instead of aborting the procedure
    # before the email delivery loop runs.
    try:
        session.sql("SHOW WAREHOUSES").collect()
        always_on_wh = session.sql("""
            SELECT "name", "size", "state", "auto_suspend"
            FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
            WHERE "auto_suspend" = 0
        """).collect()
    except Exception:
        always_on_wh = []  # omit section if SHOW WAREHOUSES fails

    # ------------------------------------------------------------------
    # DATA QUERIES — RESOURCE MONITORS
    # ------------------------------------------------------------------
    # Resource monitors define credit quotas at the account or warehouse level
    # and can automatically notify, suspend, or suspend-immediately when
    # thresholds are reached.  SHOW RESOURCE MONITORS returns current state
    # including real-time used_credits and remaining_credits.
    #
    # Percentage used is computed in Python:
    #   pct = used_credits / credit_quota * 100
    # Colour coding:
    #   < 60%  → no colour
    #   ≥ 60%  → yellow  (warn)
    #   ≥ 80%  → orange  (alert)
    #   ≥ 95%  → red     (critical) — approaching automatic suspension
    #
    # Wrapped in try/except so that a permission error or transient failure
    # degrades gracefully to an empty list instead of aborting the procedure.
    # ------------------------------------------------------------------
    try:
        session.sql("SHOW RESOURCE MONITORS").collect()
        resource_monitors = session.sql("""
            SELECT "name", "credit_quota", "used_credits", "remaining_credits",
                   "level", "frequency", "suspend_at", "suspend_immediately_at"
            FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
            ORDER BY "used_credits" DESC
        """).collect()
    except Exception:
        resource_monitors = []  # omit section if SHOW RESOURCE MONITORS fails

    # ------------------------------------------------------------------
    # DATA QUERIES — SECURITY & GOVERNANCE
    # ------------------------------------------------------------------

    # Failed login attempts grouped by user and error type.
    # Repeated failures from the same user may indicate a misconfigured
    # application, a compromised credential being probed, or a forgotten
    # password.  The error message distinguishes between incorrect password,
    # expired password, MFA failure, network policy block, etc.
    # Thresholds: ≥5 attempts = warn (yellow), ≥10 = critical (red).
    failed_logins = session.sql(
        "SELECT USER_NAME, ERROR_MESSAGE, COUNT(*) AS FAILED_ATTEMPTS, "
        "TO_VARCHAR(MAX(EVENT_TIMESTAMP), 'YYYY-MM-DD HH24:MI') AS LAST_ATTEMPT "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY "
        "WHERE EVENT_TIMESTAMP >= ? AND EVENT_TIMESTAMP < ? AND IS_SUCCESS = 'NO' "
        "GROUP BY USER_NAME, ERROR_MESSAGE ORDER BY FAILED_ATTEMPTS DESC LIMIT 15",
        params=[str(start_date), str(end_date)]
    ).collect()

    # Queries executed under the ACCOUNTADMIN role.
    # ACCOUNTADMIN is the most privileged role in Snowflake and should only
    # be used for account-level administrative tasks.  Routine data work done
    # under ACCOUNTADMIN violates the principle of least privilege and bypasses
    # row-level security and column masking policies.
    # This section gives admins visibility into who is using elevated privileges
    # and how often, supporting governance reviews and access right-sizing.
    accountadmin_usage = session.sql(
        "SELECT USER_NAME, COUNT(*) AS QUERY_COUNT, "
        "ROUND(SUM(TOTAL_ELAPSED_TIME)/1000/60, 1) AS TOTAL_MIN "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY "
        "WHERE START_TIME >= ? AND START_TIME < ? AND ROLE_NAME = 'ACCOUNTADMIN' "
        "GROUP BY USER_NAME ORDER BY QUERY_COUNT DESC",
        params=[str(start_date), str(end_date)]
    ).collect()

    # Active, non-disabled users who have not logged in for 30+ days.
    # These accounts represent a security risk: they hold active credentials
    # and role grants but are not being monitored by their owners.
    # They should be reviewed for deactivation or role revocation.
    # Colour coding:
    #   30–90 days inactive  → yellow (warn)    — review recommended
    #   >90 days or never    → red   (critical) — deactivation recommended
    # Note: LAST_SUCCESS_LOGIN reflects the last successful authentication,
    # not the last query.  A user who authenticates but issues no queries
    # is still considered active.
    #
    # SYSTEM USER EXCLUSION:
    # Snowflake creates internal/system users that never log in interactively:
    #   - 'default'        : internal Snowflake placeholder user
    #   - 'SNOWFLAKE'      : system user for internal operations
    #   - 'OPENFLOW_USER'  : service account for Openflow connectors
    #   - 'runtime-%'      : ephemeral runtime users for serverless features
    # These are excluded because they are not human users and would always
    # appear as "Never logged in", creating noise in the report.
    inactive_users = session.sql(
        "SELECT NAME, EMAIL, "
        "COALESCE(TO_VARCHAR(LAST_SUCCESS_LOGIN, 'YYYY-MM-DD'), 'Never') AS LAST_LOGIN, "
        "CASE WHEN LAST_SUCCESS_LOGIN IS NULL THEN NULL "
        "     ELSE DATEDIFF('day', LAST_SUCCESS_LOGIN, CURRENT_TIMESTAMP()) END AS DAYS_INACTIVE "
        "FROM SNOWFLAKE.ACCOUNT_USAGE.USERS "
        "WHERE DELETED_ON IS NULL AND DISABLED = FALSE "
        "AND (LAST_SUCCESS_LOGIN IS NULL "
        "     OR LAST_SUCCESS_LOGIN < DATEADD('day', -30, CURRENT_TIMESTAMP())) "
        "AND NAME NOT IN ('default', 'SNOWFLAKE', 'OPENFLOW_USER') "
        "AND NAME NOT LIKE 'runtime-%' "
        "ORDER BY DAYS_INACTIVE DESC NULLS LAST LIMIT 20"
    ).collect()

    # ------------------------------------------------------------------
    # DATA QUERIES — AUTOMATED FEATURE COSTS (MONTHLY ONLY)
    # ------------------------------------------------------------------
    # Dynamic Tables use a dedicated warehouse for refresh operations.
    # Their credits are already counted in WAREHOUSE_METERING_HISTORY,
    # but this section exists to give visibility into the cost of this
    # specific feature by breaking it down per object.
    #
    # Materialized Views consume serverless credits independently of any
    # virtual warehouse — Snowflake manages their maintenance automatically.
    #
    # Both blocks are conditioned on MONTHLY mode because these costs
    # are more meaningful in a month-to-month comparison than in a weekly
    # tactical review.
    #
    # Each query is wrapped in try/except so that accounts where these
    # features are not used (empty history tables) or where the views are
    # not yet available return an empty list rather than aborting the report.
    # ------------------------------------------------------------------
    dynamic_tables = []
    mat_views      = []

    if report_type == "MONTHLY":

        # ---- Dynamic Tables ----
        # DYNAMIC_TABLE_REFRESH_HISTORY records every refresh event with
        # CREDITS_USED, REFRESH_START_TIME, and the warehouse used.
        # NOTE: These credits are warehouse-backed (not serverless) and are
        # already reflected in WAREHOUSE_METERING_HISTORY. This section
        # provides per-object visibility into DT-specific costs.
        try:
            dynamic_tables = session.sql(
                "SELECT r.DATABASE_NAME, r.SCHEMA_NAME, r.NAME AS TABLE_NAME, "
                "       COALESCE(t.TABLE_OWNER, 'UNKNOWN') AS OWNER_ROLE, "
                "       r.WAREHOUSE_NAME, "
                "       COUNT(*)                           AS REFRESH_COUNT, "
                "       ROUND(SUM(r.CREDITS_USED), 4)     AS TOTAL_CREDITS "
                "FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY r "
                "LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t "
                "  ON  r.DATABASE_NAME = t.TABLE_CATALOG "
                "  AND r.SCHEMA_NAME   = t.TABLE_SCHEMA "
                "  AND r.NAME          = t.TABLE_NAME "
                "WHERE r.REFRESH_START_TIME >= ? AND r.REFRESH_START_TIME < ? "
                "GROUP BY 1, 2, 3, 4, 5 "
                "ORDER BY TOTAL_CREDITS DESC LIMIT 20",
                params=[str(start_date), str(end_date)]
            ).collect()
        except Exception:
            dynamic_tables = []   # view absent or no activity — omit section

        # ---- Materialized Views ----
        # MATERIALIZED_VIEW_REFRESH_HISTORY records automatic serverless
        # maintenance operations with CREDITS_USED and START_TIME.
        # The LEFT JOIN to TABLES resolves the owner role.
        try:
            mat_views = session.sql(
                "SELECT r.DATABASE_NAME, r.SCHEMA_NAME, r.TABLE_NAME, "
                "       COALESCE(t.TABLE_OWNER, 'UNKNOWN') AS OWNER_ROLE, "
                "       COUNT(*)                           AS REFRESH_COUNT, "
                "       ROUND(SUM(r.CREDITS_USED), 4)     AS TOTAL_CREDITS "
                "FROM SNOWFLAKE.ACCOUNT_USAGE.MATERIALIZED_VIEW_REFRESH_HISTORY r "
                "LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t "
                "  ON  r.DATABASE_NAME = t.TABLE_CATALOG "
                "  AND r.SCHEMA_NAME   = t.TABLE_SCHEMA "
                "  AND r.TABLE_NAME    = t.TABLE_NAME "
                "WHERE r.START_TIME >= ? AND r.START_TIME < ? "
                "GROUP BY 1, 2, 3, 4 "
                "ORDER BY TOTAL_CREDITS DESC LIMIT 20",
                params=[str(start_date), str(end_date)]
            ).collect()
        except Exception:
            mat_views = []   # view absent or no activity — omit section

    # ------------------------------------------------------------------
    # NUMBER FORMATTING
    # ------------------------------------------------------------------
    total_str   = "{:,.2f}".format(current_total)
    compute_str = "{:,.2f}".format(compute_credits)
    cloud_str   = "{:,.2f}".format(cloud_credits)
    pct_str     = "{:.1f}".format(abs(pct_change))
    mtd_str     = "{:,.2f}".format(mtd_credits)
    ai_cred_str = "{:,.2f}".format(ai_credits)

    # ------------------------------------------------------------------
    # HTML GENERATION
    # ------------------------------------------------------------------
    # Structure: four clearly delimited sections with colored band headers.
    #
    #   1 · Overview              — Summary numbers + daily trend
    #   2 · Cost Breakdown        — Where credits are going and who is spending them
    #   3 · Performance & Efficiency — How well the platform is running
    #   4 · Security & Governance — Risk indicators and access hygiene
    #
    # The report is assembled into a list (h) and joined once at the end to
    # avoid O(n²) string concatenation on large outputs.
    # Every database-sourced value is wrapped in html.escape() to prevent XSS.
    # No <style> block — Gmail strips it. All styling is inline. See constants above.
    # ------------------------------------------------------------------
    h = []
    h.append("<!DOCTYPE html><html><head><meta charset='UTF-8'></head>")
    h.append("<body style='font-family:Arial,sans-serif;font-size:14px;color:#333;margin:20px;'>")

    h.append("<h1 style='" + S_H1 + "'>Snowflake Account Usage Report</h1>")
    h.append("<p style='" + S_P + "'><strong>Account:</strong> " + escape(account_name) + "</p>")
    h.append("<p style='" + S_P + "'><strong>Period:</strong> " + escape(period_label) + "</p>")
    h.append("<p style='" + S_P + "'><strong>Generated:</strong> " + today.strftime("%Y-%m-%d %H:%M:%S") + "</p>")

    # ================================================================
    # SECTION 1 — OVERVIEW
    # High-level pulse: what happened and when.
    # ================================================================
    h.append(section_header("1 &nbsp;&middot;&nbsp; Overview"))

    # Executive Summary — metric cards (HTML table layout, not flexbox)
    h.append("<h2 style='" + S_H2 + "'>Executive Summary</h2>")
    h.append("<table style='border-collapse:collapse;width:100%;background-color:#f0f8ff;"
             "margin:15px 0;' bgcolor='#f0f8ff'><tr>")
    h.append(metric_cell(total_str, "Total Credits"))
    h.append(metric_cell(compute_str, "Compute"))
    h.append(metric_cell(cloud_str, "Cloud Services"))
    h.append(
        "<td style='text-align:center;padding:20px;vertical-align:top;'>"
        "<div style='font-size:28px;font-weight:bold;color:" + change_color + ";"
        "font-family:Arial,sans-serif;'>" + change_arrow + " " + pct_str + "%</div>"
        "<div style='font-size:12px;color:#666;margin-top:5px;font-family:Arial,sans-serif;'>"
        "vs " + escape(prev_period_label) + "</div></td>"
    )
    if report_type == "WEEKLY":
        h.append(metric_cell(mtd_str, "Month-to-Date"))
    h.append("</tr></table>")

    # Daily Credit Trend — placed immediately after the summary so recipients
    # can spot the day that drove the numbers before reading the detail below.
    h.append("<h2 style='" + S_H2 + "'>Daily Credit Trend</h2>")
    h.append("<table style='" + S_TABLE + "'><tr>" + th("Date") + th("Credits") + "</tr>")
    for i, day in enumerate(trend):
        dc_str = "{:,.2f}".format(float(day["DAILY_CREDITS"] or 0))
        h.append(tr(i) + td(escape(str(day["USAGE_DATE"]))) + td(dc_str) + "</tr>")
    h.append("</table>")

    # ================================================================
    # SECTION 2 — COST BREAKDOWN
    # What is the spend going to, and who / what is driving it.
    # Order: service types → Cortex detail → serverless (monthly) →
    #        top users → top warehouses → user+warehouse combinations.
    # ================================================================
    h.append(section_header("2 &nbsp;&middot;&nbsp; Cost Breakdown"))

    # Credits by Service Type — all service types ranked by spend.
    # Gives an instant read on which Snowflake features consumed the most credits.
    h.append("<h2 style='" + S_H2 + "'>Credits by Service Type</h2>")
    h.append("<table style='" + S_TABLE + "'><tr>" + th("Service Type") + th("Credits") + "</tr>")
    for i, svc in enumerate(services):
        cred_str = "{:,.2f}".format(float(svc["CREDITS"] or 0))
        h.append(tr(i) + td(escape(str(svc["SERVICE_TYPE"]))) + td(cred_str) + "</tr>")
    h.append("</table>")

    # AI & Cortex Usage — total credits across all four Cortex service types,
    # broken down by type and then by user (SQL-level calls only).
    h.append("<h2 style='" + S_H2 + "'>AI &amp; Cortex Usage</h2>")
    h.append("<p style='" + S_P + "'><strong>Total Cortex Credits (all services):</strong> "
             + ai_cred_str + "</p>")

    # Breakdown by Cortex service type
    h.append("<h3 style='" + S_H3 + "'>Credits by Cortex Service</h3>")
    h.append(
        "<p style='" + S_PNOTE + "'>"
        "AI_SERVICES = LLM functions (COMPLETE, SUMMARIZE, SENTIMENT&hellip;) &nbsp;|&nbsp; "
        "CORTEX_AGENTS = Cortex Agents &nbsp;|&nbsp; "
        "CORTEX_CODE_SNOWSIGHT = Cortex Code in Snowsight &nbsp;|&nbsp; "
        "CORTEX_CODE_CLI = Cortex from CLI"
        "</p>"
    )
    if cortex_by_type:
        h.append("<table style='" + S_TABLE + "'><tr>"
                 + th("Cortex Service") + th("Credits") + "</tr>")
        for i, cs in enumerate(cortex_by_type):
            cr_str = "{:,.4f}".format(float(cs["CREDITS"] or 0))
            h.append(tr(i) + td(escape(str(cs["SERVICE_TYPE"]))) + td(cr_str) + "</tr>")
        h.append("</table>")
    else:
        h.append("<p style='" + S_OK + "'>No Cortex credit consumption in this period.</p>")

    # Per-user SQL Cortex queries (LLM functions detected in QUERY_HISTORY).
    # Cortex Code (Snowsight) and CLI usage appears in the credit breakdown above
    # but is not attributed per user in standard ACCOUNT_USAGE views.
    h.append("<h3 style='" + S_H3 + "'>SQL Cortex Queries by User</h3>")
    h.append(
        "<p style='" + S_PNOTE + "'>"
        "Users who called Cortex LLM functions via SQL (COMPLETE, SUMMARIZE, etc.). "
        "Cortex Code (Snowsight/CLI) usage is captured in the credit totals above but cannot be "
        "attributed per user through standard ACCOUNT_USAGE views."
        "</p>"
    )
    if ai_users:
        h.append("<table style='" + S_TABLE + "'><tr>"
                 + th("User") + th("AI Queries") + "</tr>")
        for i, ai in enumerate(ai_users):
            aq_str = "{:,}".format(ai["AI_QUERIES"])
            h.append(tr(i) + td(escape(str(ai["USER_NAME"]))) + td(aq_str) + "</tr>")
        h.append("</table>")
    else:
        h.append("<p style='" + S_OK + "'>No SQL Cortex function calls detected in this period.</p>")

    # Dynamic Table Costs — warehouse-backed, shown for per-object visibility (MONTHLY only).
    if report_type == "MONTHLY":
        h.append("<h2 style='" + S_H2 + "'>Dynamic Table Refresh Costs</h2>")
        h.append(
            "<p style='" + S_PNOTE + "'>"
            "Credits consumed by Dynamic Table refreshes. These costs use the "
            "warehouse assigned to each DT and are <strong>already included</strong> "
            "in the Warehouse Metering totals above. This section exists to give "
            "visibility into the cost of this specific feature per object."
            "</p>"
        )
        if dynamic_tables:
            h.append("<table style='" + S_TABLE + "'><tr>"
                     + th("Database") + th("Schema") + th("Table")
                     + th("Owner Role") + th("Warehouse") + th("Refreshes") + th("Credits") + "</tr>")
            for i, dt in enumerate(dynamic_tables):
                cr_str = "{:,.4f}".format(float(dt["TOTAL_CREDITS"] or 0))
                rc_str = "{:,}".format(dt["REFRESH_COUNT"])
                h.append(tr(i)
                         + td(escape(str(dt["DATABASE_NAME"])))
                         + td(escape(str(dt["SCHEMA_NAME"])))
                         + td(escape(str(dt["TABLE_NAME"])))
                         + td(escape(str(dt["OWNER_ROLE"])))
                         + td(escape(str(dt["WAREHOUSE_NAME"] or "")))
                         + td(rc_str) + td(cr_str) + "</tr>")
            h.append("</table>")
        else:
            h.append("<p style='" + S_OK + "'>No Dynamic Table refresh activity in this period.</p>")

        # Serverless Feature Costs — Materialized Views only (truly serverless).
        h.append("<h2 style='" + S_H2 + "'>Serverless Feature Costs</h2>")
        h.append(
            "<p style='" + S_PNOTE + "'>"
            "Credits consumed by Materialized Views. These refresh automatically "
            "without a virtual warehouse (serverless) — cost is attributed to the "
            "<strong>owner role</strong> of each object."
            "</p>"
        )
        h.append("<h3 style='" + S_H3 + "'>Materialized Views</h3>")
        if mat_views:
            h.append("<table style='" + S_TABLE + "'><tr>"
                     + th("Database") + th("Schema") + th("View")
                     + th("Owner Role") + th("Refreshes") + th("Credits") + "</tr>")
            for i, mv in enumerate(mat_views):
                cr_str = "{:,.4f}".format(float(mv["TOTAL_CREDITS"] or 0))
                rc_str = "{:,}".format(mv["REFRESH_COUNT"])
                h.append(tr(i)
                         + td(escape(str(mv["DATABASE_NAME"])))
                         + td(escape(str(mv["SCHEMA_NAME"])))
                         + td(escape(str(mv["TABLE_NAME"])))
                         + td(escape(str(mv["OWNER_ROLE"])))
                         + td(rc_str) + td(cr_str) + "</tr>")
            h.append("</table>")
        else:
            h.append("<p style='" + S_OK + "'>No Materialized View refresh activity in this period.</p>")

    # Top 15 Users by Consumption — sorted by compute hours (impact proxy).
    h.append("<h2 style='" + S_H2 + "'>Top 15 Users by Consumption</h2>")
    h.append("<table style='" + S_TABLE + "'><tr>"
             + th("User") + th("Query Count") + th("Hours") + th("Cloud Credits") + "</tr>")
    for i, user in enumerate(users):
        qc_str = "{:,}".format(user["QUERY_COUNT"])
        hr_str = "{:,.2f}".format(float(user["HOURS"] or 0))
        cc_str = "{:,.4f}".format(float(user["CLOUD_CREDITS"] or 0))
        h.append(tr(i) + td(escape(str(user["USER_NAME"])))
                 + td(qc_str) + td(hr_str) + td(cc_str) + "</tr>")
    h.append("</table>")

    # Top 15 Warehouses by Credits
    h.append("<h2 style='" + S_H2 + "'>Top 15 Warehouses by Credits</h2>")
    h.append("<table style='" + S_TABLE + "'><tr>"
             + th("Warehouse") + th("Credits") + th("Metering Events") + "</tr>")
    for i, wh in enumerate(warehouses):
        cr_str = "{:,.2f}".format(float(wh["CREDITS"] or 0))
        me_str = "{:,}".format(wh["METERING_EVENTS"])
        h.append(tr(i) + td(escape(str(wh["WAREHOUSE_NAME"])))
                 + td(cr_str) + td(me_str) + "</tr>")
    h.append("</table>")

    # Top 15 User + Warehouse Combinations — shows which users drive cost
    # on which warehouses; useful for workload isolation decisions.
    h.append("<h2 style='" + S_H2 + "'>Top 15 User + Warehouse Combinations</h2>")
    h.append("<table style='" + S_TABLE + "'><tr>"
             + th("User") + th("Warehouse") + th("Query Count") + th("Hours") + "</tr>")
    for i, uw in enumerate(user_wh):
        qc_str = "{:,}".format(uw["QUERY_COUNT"])
        hr_str = "{:,.2f}".format(float(uw["HOURS"] or 0))
        h.append(tr(i) + td(escape(str(uw["USER_NAME"])))
                 + td(escape(str(uw["WAREHOUSE_NAME"])))
                 + td(qc_str) + td(hr_str) + "</tr>")
    h.append("</table>")

    # ================================================================
    # SECTION 3 — PERFORMANCE & EFFICIENCY
    # How well the platform ran: slow queries, warehouse sizing, monitors.
    # Order: costly queries → warehouse efficiency → always-on warehouses
    #        → resource monitors.
    # ================================================================
    h.append(section_header("3 &nbsp;&middot;&nbsp; Performance &amp; Efficiency"))

    # Top 10 Longest Queries — with disk spill detection (yellow highlight).
    h.append("<h2 style='" + S_H2 + "'>Top 10 Longest Queries</h2>")
    h.append("<p style='" + S_PNOTE + "'>Rows in yellow have disk spill — "
             "consider resizing the warehouse or optimising the query.</p>")
    h.append("<table style='" + S_TABLE + "'><tr>"
             + th("User") + th("Warehouse") + th("Elapsed (s)")
             + th("Spill Local (GB)") + th("Spill Remote (GB)") + th("Query Preview") + "</tr>")
    for i, qr in enumerate(expensive_queries):
        spill_l = float(qr["SPILL_LOCAL_GB"] or 0)
        spill_r = float(qr["SPILL_REMOTE_GB"] or 0)
        level   = "spill" if (spill_l > 0 or spill_r > 0) else None
        el_str  = "{:,.1f}".format(float(qr["ELAPSED_SEC"] or 0))
        sl_str  = "{:.3f}".format(spill_l)
        sr_str  = "{:.3f}".format(spill_r)
        preview = escape(str(qr["QUERY_PREVIEW"] or "")).replace("\n", " ")
        h.append(tr(i, level)
                 + td(escape(str(qr["USER_NAME"])))
                 + td(escape(str(qr["WAREHOUSE_NAME"] or "")))
                 + td(el_str) + td(sl_str) + td(sr_str)
                 + td("<span style='font-family:monospace;font-size:12px;color:#555;'>"
                      + preview + "</span>")
                 + "</tr>")
    h.append("</table>")

    # Warehouse Efficiency — queue time and spill per warehouse.
    h.append("<h2 style='" + S_H2 + "'>Warehouse Efficiency</h2>")
    h.append("<p style='" + S_PNOTE + "'>Avg queue &gt;10s = yellow &nbsp;|&nbsp; &gt;30s = red. "
             "Persistent queue time indicates the warehouse is undersized or overloaded.</p>")
    h.append("<table style='" + S_TABLE + "'><tr>"
             + th("Warehouse") + th("Queries") + th("Avg Elapsed (s)")
             + th("Avg Queue (s)") + th("Queries w/ Spill") + th("Remote Spill (GB)") + "</tr>")
    for i, we in enumerate(wh_efficiency):
        avg_q  = float(we["AVG_QUEUE_SEC"] or 0)
        level  = "critical" if avg_q > 30 else ("warn" if avg_q > 10 else None)
        qc_str = "{:,}".format(we["QUERY_COUNT"])
        ae_str = "{:,.1f}".format(float(we["AVG_ELAPSED_SEC"] or 0))
        aq_str = "{:,.1f}".format(avg_q)
        sq_str = "{:,}".format(we["SPILL_QUERIES"])
        rs_str = "{:,.2f}".format(float(we["TOTAL_REMOTE_SPILL_GB"] or 0))
        h.append(tr(i, level)
                 + td(escape(str(we["WAREHOUSE_NAME"])))
                 + td(qc_str) + td(ae_str) + td(aq_str) + td(sq_str) + td(rs_str) + "</tr>")
    h.append("</table>")

    # Always-on warehouses (AUTO_SUSPEND = 0) — flagged as critical.
    if always_on_wh:
        h.append("<p style='font-family:Arial,sans-serif;font-size:14px;"
                 "color:#dc3545;margin:10px 0;'><strong>WARNING: Warehouses with "
                 "AUTO_SUSPEND disabled — these run continuously and consume credits "
                 "even when idle.</strong></p>")
        h.append("<table style='" + S_TABLE + "'><tr>"
                 + th("Warehouse") + th("Size") + th("State") + "</tr>")
        for i, wh in enumerate(always_on_wh):
            h.append(tr(i, "critical")
                     + td(escape(str(wh["name"])))
                     + td(escape(str(wh["size"])))
                     + td(escape(str(wh["state"]))) + "</tr>")
        h.append("</table>")

    # Resource Monitors — real-time quota utilisation, color-coded by threshold.
    h.append("<h2 style='" + S_H2 + "'>Resource Monitors</h2>")
    if resource_monitors:
        h.append("<table style='" + S_TABLE + "'><tr>"
                 + th("Monitor") + th("Level") + th("Frequency")
                 + th("Quota") + th("Used") + th("Remaining")
                 + th("% Used") + th("Suspend at %") + "</tr>")
        for i, rm in enumerate(resource_monitors):
            quota    = float(rm["credit_quota"] or 0)
            used     = float(rm["used_credits"] or 0)
            pct      = round(used / quota * 100, 1) if quota > 0 else 0
            level    = ("critical" if pct >= 95 else
                        "alert"    if pct >= 80 else
                        "warn"     if pct >= 60 else None)
            q_str    = "{:,.2f}".format(quota)
            u_str    = "{:,.2f}".format(used)
            rem_str  = "{:,.2f}".format(float(rm["remaining_credits"] or 0))
            pct_str2 = "{:.1f}%".format(pct)
            susp     = str(rm["suspend_at"] or rm["suspend_immediately_at"] or "-")
            h.append(tr(i, level)
                     + td(escape(str(rm["name"])))
                     + td(escape(str(rm["level"] or "")))
                     + td(escape(str(rm["frequency"] or "")))
                     + td(q_str) + td(u_str) + td(rem_str)
                     + td("<strong>" + pct_str2 + "</strong>")
                     + td(escape(susp)) + "</tr>")
        h.append("</table>")
    else:
        h.append("<p style='font-family:Arial,sans-serif;font-size:14px;color:#888;'>"
                 "No resource monitors configured.</p>")

    # ================================================================
    # SECTION 4 — SECURITY & GOVERNANCE
    # Risk indicators: authentication failures, privilege usage, stale accounts.
    # Order: failed logins → ACCOUNTADMIN usage → inactive users.
    # ================================================================
    h.append(section_header("4 &nbsp;&middot;&nbsp; Security &amp; Governance"))

    h.append("<h3 style='" + S_H3 + "'>Failed Login Attempts</h3>")
    if failed_logins:
        h.append("<table style='" + S_TABLE + "'><tr>"
                 + th("User") + th("Error") + th("Attempts") + th("Last Attempt") + "</tr>")
        for i, fl in enumerate(failed_logins):
            attempts = fl["FAILED_ATTEMPTS"]
            level    = "critical" if attempts >= 10 else ("warn" if attempts >= 5 else None)
            at_str   = "{:,}".format(attempts)
            h.append(tr(i, level)
                     + td(escape(str(fl["USER_NAME"] or "UNKNOWN")))
                     + td(escape(str(fl["ERROR_MESSAGE"] or "")))
                     + td(at_str)
                     + td(escape(str(fl["LAST_ATTEMPT"]))) + "</tr>")
        h.append("</table>")
    else:
        h.append("<p style='" + S_OK + "'>No failed login attempts in this period.</p>")

    h.append("<h3 style='" + S_H3 + "'>ACCOUNTADMIN Role Usage</h3>")
    h.append("<p style='" + S_PNOTE + "'>Queries run directly under ACCOUNTADMIN. "
             "Prefer least-privilege roles — usage here should be exceptional, not routine.</p>")
    if accountadmin_usage:
        h.append("<table style='" + S_TABLE + "'><tr>"
                 + th("User") + th("Queries") + th("Total Minutes") + "</tr>")
        for i, au in enumerate(accountadmin_usage):
            qc_str  = "{:,}".format(au["QUERY_COUNT"])
            min_str = "{:,.1f}".format(float(au["TOTAL_MIN"] or 0))
            h.append(tr(i) + td(escape(str(au["USER_NAME"])))
                     + td(qc_str) + td(min_str) + "</tr>")
        h.append("</table>")
    else:
        h.append("<p style='" + S_OK + "'>No queries run under ACCOUNTADMIN this period.</p>")

    h.append("<h3 style='" + S_H3 + "'>Inactive Users (30+ days without login)</h3>")
    if inactive_users:
        h.append("<table style='" + S_TABLE + "'><tr>"
                 + th("User") + th("Email") + th("Last Login") + th("Days Inactive") + "</tr>")
        for i, iu in enumerate(inactive_users):
            days    = iu["DAYS_INACTIVE"]
            level   = "critical" if (days is None or days > 90) else "warn"
            d_str   = "Never logged in" if days is None else "{:,}".format(days)
            h.append(tr(i, level)
                     + td(escape(str(iu["NAME"])))
                     + td(escape(str(iu["EMAIL"] or "")))
                     + td(escape(str(iu["LAST_LOGIN"])))
                     + td(d_str) + "</tr>")
        h.append("</table>")
    else:
        h.append("<p style='" + S_OK + "'>No inactive users found.</p>")

    h.append("<hr style='border:none;border-top:1px solid #ddd;margin:30px 0;'>")
    h.append("<p style='font-family:Arial,sans-serif;font-size:12px;color:#666;'>")
    h.append("Automated report from Snowflake Account: " + escape(account_name) + "<br>")
    h.append("Generated by UTIL_DB.ADMIN.SEND_ACCOUNT_USAGE_REPORT</p>")
    h.append("</body></html>")

    html = "".join(h)  # Single join avoids O(n²) string concatenation

    # ------------------------------------------------------------------
    # EMAIL DELIVERY
    # ------------------------------------------------------------------
    # Each recipient receives an individual email call so that a delivery
    # failure for one address does not prevent others from receiving the report.
    # sql_esc() is applied to both the email address and the HTML body before
    # embedding them in the CALL string, since SYSTEM$SEND_EMAIL cannot use
    # parameterised bindings.
    # Successes and failures are tracked separately and included in the return
    # value for audit purposes.
    # ------------------------------------------------------------------
    sent_to = []
    failed  = []

    for email in recipients:
        try:
            send_sql = (
                "CALL SYSTEM$SEND_EMAIL("
                "'MY_EMAIL_INTEGRATION', "
                "'" + sql_esc(email) + "', "
                "'" + sql_esc(subject) + "', "
                "'" + sql_esc(html) + "', "
                "'text/html')"
            )
            session.sql(send_sql).collect()
            sent_to.append(email)
        except Exception as e:
            # Truncate exception text to avoid leaking internal details
            # (table names, connection strings, etc.) in the return value,
            # which is recorded verbatim in Snowflake's QUERY_HISTORY.
            failed.append(email + ": " + str(e)[:80])

    return "Report sent to: " + str(len(sent_to)) + " recipients. Failed: " + str(len(failed))
$$;
