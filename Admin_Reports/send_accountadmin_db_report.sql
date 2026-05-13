-- ============================================================
-- Procedure : UTIL_DB.ADMIN.SEND_ACCOUNTADMIN_DB_REPORT
-- Language  : Python 3.11 (Snowpark)  |  EXECUTE AS CALLER
-- ============================================================
-- Emails a monthly HTML database inventory to all ACCOUNTADMIN users.
--
-- Categories:  SYSTEM (blue) | PROJECT (green) | SYSADMIN (orange)
--              USER (purple) | OTHER (grey)
-- USER = owner is <NAME>_DB_ROLE AND database name is <NAME>_DB.
-- PROJECT = _DB_ROLE convention but name doesn't match <NAME>_DB pattern.
-- _DB_ROLE_NEW suffix also recognised (role migration in progress).
--
-- Recommendations:
--   USER  ≥0.3 GB + idle >60d → ACTION REQUIRED  |  >30d → Recommend cleanup
--   Other idle >60d → MUST DELETE  |  >30d → Recommend delete
--   Non-SYSTEM with unconventional owner → Fix ownership appended
--
-- SECURITY: EXECUTE AS CALLER prevents privilege escalation.
--   All DB-sourced strings in HTML are wrapped in html.escape().
--   sql_esc() used on every value passed to SYSTEM$SEND_EMAIL.
--   Exceptions truncated to 80 chars before being returned.
--
-- DEPENDENCIES: SNOWFLAKE.ACCOUNT_USAGE.{DATABASES,
--   DATABASE_STORAGE_USAGE_HISTORY, QUERY_HISTORY},
--   MY_EMAIL_INTEGRATION (notification integration, must exist).
-- ============================================================
CREATE OR REPLACE PROCEDURE UTIL_DB.ADMIN.SEND_ACCOUNTADMIN_DB_REPORT()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'send_report'
EXECUTE AS CALLER
AS
$$
from datetime import datetime
from html import escape

def send_report(session):


    # Databases larger than this threshold are flagged for cleanup
    # recommendations when they are also inactive.
    CLEANUP_THRESHOLD_BYTES = 0.3 * 1024 * 1024 * 1024  # 0.3 GB

    def sql_esc(val):
        # Doubles single quotes for SYSTEM$SEND_EMAIL strings. Use params=[] elsewhere.
        return str(val).replace("'", "''")

    # Recipients from SHOW GRANTS OF ROLE ACCOUNTADMIN + SHOW USERS (real-time, no lag).
    # IMPORTANT: RESULT_SCAN(LAST_QUERY_ID()) must stay adjacent to SHOW —
    # any intervening SQL resets LAST_QUERY_ID() and reads the wrong result.
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

        # f-string IN clause: SHOW result sets can't use params=[]. Values are sql_esc()'d.
        session.sql("SHOW USERS").collect()   # must stay adjacent to RESULT_SCAN below
        user_filter = ",".join(["'" + sql_esc(u) + "'" for u in user_list])
        email_df = session.sql(f"""
            SELECT "name", "email"
            FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
            WHERE "name" IN ({user_filter})
              AND "email" IS NOT NULL
              AND "email" != ''
        """).collect()
    except Exception as e:
        # Truncate to avoid leaking verbose Snowflake internals.
        return "Error getting recipients: " + str(e)[:80]

    emails = [(row["name"], row["email"]) for row in email_df]
    if not emails:
        return "No valid emails found"

    # 90-day window on QUERY_HISTORY is a performance trade-off — unbounded would be slow.
    # LIKE patterns use \_ to match a literal underscore (SQL LIKE wildcard).
    try:
        db_info_df = session.sql("""
            WITH db_list AS (
                SELECT database_name, database_owner
                FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASES
                WHERE deleted IS NULL
                  AND database_name NOT LIKE 'USER$%'
            ),
            db_storage AS (
                SELECT database_name,
                       COALESCE(average_database_bytes, 0)
                       + COALESCE(average_failsafe_bytes, 0) AS total_bytes
                FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
                WHERE USAGE_DATE = (
                    SELECT MAX(USAGE_DATE)
                    FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
                )
            ),
            db_access AS (
                SELECT database_name,
                       MAX(start_time) AS last_accessed
                FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
                WHERE start_time > DATEADD('day', -90, CURRENT_TIMESTAMP())
                GROUP BY database_name
            )
            SELECT
                d.database_name,
                d.database_owner,
                CASE
                    WHEN d.database_name IN (
                        'SNOWFLAKE','SNOWFLAKE_SAMPLE_DATA',
                        'SNOWFLAKE_SETUP','SNOWFLAKE_PUBLIC_DATA_FREE'
                    ) THEN 'SYSTEM'
                    WHEN d.database_owner LIKE '%\_DB\_ROLE'
                      OR d.database_owner LIKE '%\_DB\_ROLE\_NEW'
                    THEN
                        CASE
                            WHEN REPLACE(
                                     REPLACE(d.database_owner, '_DB_ROLE_NEW', ''),
                                     '_DB_ROLE', ''
                                 ) || '_DB' = d.database_name
                            THEN 'USER'      -- personal DB: <NAME>_DB_ROLE owns <NAME>_DB
                            ELSE 'PROJECT'   -- shared/team DB with same role convention
                        END
                    WHEN d.database_owner = 'SYSADMIN' THEN 'SYSADMIN'
                    ELSE 'OTHER'
                END AS db_type,
                COALESCE(s.total_bytes, 0) AS size_bytes,
                TO_VARCHAR(ROUND(COALESCE(s.total_bytes, 0) / POWER(1024,3), 4)) AS size_gb,
                a.last_accessed,
                COALESCE(
                    TO_VARCHAR(a.last_accessed, 'YYYY-MM-DD HH24:MI'),
                    'No recent access (>90d)'
                ) AS last_accessed_str,
                CASE
                    WHEN a.last_accessed IS NULL
                      OR a.last_accessed < DATEADD('day', -30, CURRENT_TIMESTAMP())
                    THEN TRUE ELSE FALSE
                END AS inactive_30d,
                DATEDIFF('day', a.last_accessed, CURRENT_TIMESTAMP()) AS days_since_access
            FROM db_list d
            LEFT JOIN db_storage s ON d.database_name = s.database_name
            LEFT JOIN db_access  a ON d.database_name = a.database_name
            ORDER BY
                CASE db_type
                    WHEN 'SYSTEM'   THEN 1
                    WHEN 'PROJECT'  THEN 2
                    WHEN 'SYSADMIN' THEN 3
                    WHEN 'OTHER'    THEN 4
                    WHEN 'USER'     THEN 5
                END,
                COALESCE(s.total_bytes, 0) DESC
        """).collect()
    except Exception as e:
        return "Error querying database inventory: " + str(e)[:80]


    categories = {"SYSTEM": [], "PROJECT": [], "SYSADMIN": [], "OTHER": [], "USER": []}
    total_storage = 0
    inactive_count = 0
    max_size = 0

    for row in db_info_df:
        categories.get(row["DB_TYPE"], categories["OTHER"]).append(row)
        size = float(row["SIZE_BYTES"] or 0)
        total_storage += size
        if size > max_size:
            max_size = size
        if row["INACTIVE_30D"]:
            inactive_count += 1

    total_dbs = len(db_info_df)
    total_storage_gb = total_storage / (1024 ** 3)
    report_date = str(session.sql("SELECT CURRENT_DATE()").collect()[0][0])

    # Live account identifier for email header.
    account_label = session.sql(
        "SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT() AS acct"
    ).collect()[0]["ACCT"]

    # Per-category storage totals used for the distribution bar
    cat_colors = {
        "SYSTEM":   "#1565c0",
        "PROJECT":  "#2e7d32",
        "SYSADMIN": "#e65100",
        "USER":     "#6a1b9a",
        "OTHER":    "#546e7a",
    }
    cat_storage = {
        key: sum(float(r["SIZE_BYTES"] or 0) for r in dbs) / (1024 ** 3)
        for key, dbs in categories.items()
    }

    # Gmail strips <style> blocks — all styling is inline. Layout uses HTML <table>.
    # DQ = chr(34) avoids escaping double-quotes inside HTML attribute strings.
    DQ = chr(34)   # double-quote character used inside HTML attribute strings
    h = []

    h.append(
        '<!DOCTYPE html><html><head></head>'
        '<body style=' + DQ + 'margin:0;padding:20px;background:#f5f7fa;'
        'font-family:Arial,sans-serif;font-size:14px;color:#333;' + DQ + '>'
    )
    # Outer centering table
    h.append(
        '<table width=' + DQ + '100%' + DQ + ' cellpadding=' + DQ + '0' + DQ +
        ' cellspacing=' + DQ + '0' + DQ + ' border=' + DQ + '0' + DQ + '><tr>'
        '<td align=' + DQ + 'center' + DQ + '>'
    )
    # Inner 900px content card
    h.append(
        '<table width=' + DQ + '900' + DQ + ' cellpadding=' + DQ + '0' + DQ +
        ' cellspacing=' + DQ + '0' + DQ + ' border=' + DQ + '0' + DQ +
        ' bgcolor=' + DQ + '#ffffff' + DQ +
        ' style=' + DQ + 'border-radius:12px;' + DQ + '>'
        '<tr><td style=' + DQ + 'padding:30px;' + DQ + '>'
    )

    # Report title and account/date line
    h.append(
        '<h1 style=' + DQ + 'color:#29B5E8;font-size:22px;margin:0 0 5px 0;' + DQ +
        '>Monthly Database Report</h1>'
    )
    h.append(
        '<p style=' + DQ + 'color:#666;font-size:13px;margin:0 0 25px 0;' + DQ + '>'
        'Account: ' + escape(account_label) + ' &mdash; ' + escape(report_date) + '</p>'
    )

    # --- Metric summary cards ---
    h.append(
        '<table width=' + DQ + '100%' + DQ + ' cellpadding=' + DQ + '10' + DQ +
        ' cellspacing=' + DQ + '6' + DQ + ' border=' + DQ + '0' + DQ + '><tr>'
    )
    for val, label, color in [
        (str(total_dbs),                          "DATABASES",  "#29B5E8"),
        ("{:.2f}".format(total_storage_gb),        "STORAGE GB", "#29B5E8"),
        (str(inactive_count),                      "INACTIVE",   "#dc3545" if inactive_count > 0 else "#29B5E8"),
        (str(len(categories["PROJECT"])),          "PROJECT",    "#2e7d32"),
        (str(len(categories["USER"])),             "USER",       "#6a1b9a"),
    ]:
        h.append(
            '<td align=' + DQ + 'center' + DQ + ' bgcolor=' + DQ + '#f0f8ff' + DQ + '>'
            '<div style=' + DQ + 'font-size:22px;font-weight:bold;color:' + color + ';' + DQ + '>' + val + '</div>'
            '<div style=' + DQ + 'font-size:10px;color:#666;margin-top:3px;' + DQ + '>' + label + '</div>'
            '</td>'
        )
    h.append('</tr></table>')

    # Horizontal storage distribution bar — segments below 0.5% omitted.
    if total_storage > 0:
        h.append(
            '<table width=' + DQ + '100%' + DQ + ' cellpadding=' + DQ + '0' + DQ +
            ' cellspacing=' + DQ + '0' + DQ + ' border=' + DQ + '0' + DQ +
            ' style=' + DQ + 'margin:15px 0;' + DQ + '><tr>'
        )
        for key in ["PROJECT", "USER", "SYSADMIN", "SYSTEM", "OTHER"]:
            pct = (cat_storage[key] / total_storage_gb * 100) if total_storage_gb > 0 else 0
            if pct > 0.5:
                h.append(
                    '<td width=' + DQ + '{:.0f}'.format(pct) + '%' + DQ +
                    ' bgcolor=' + DQ + cat_colors[key] + DQ +
                    ' style=' + DQ + 'height:12px;' + DQ + '></td>'
                )
        h.append('</tr></table>')

    # Per-category sections. is_user enables USER-specific thresholds (0.3 GB minimum).
    for title, key, color, is_user in [
        ("System",         "SYSTEM",   "#1565c0", False),
        ("Project/Shared", "PROJECT",  "#2e7d32", False),
        ("Sysadmin-Owned", "SYSADMIN", "#e65100", False),
        ("Other",          "OTHER",    "#546e7a", False),
        ("User Personal",  "USER",     "#6a1b9a", True),
    ]:
        dbs = categories[key]
        if not dbs:
            continue

        inactive_in_section = sum(1 for d in dbs if d["INACTIVE_30D"])
        section_storage_gb  = sum(float(d["SIZE_BYTES"] or 0) for d in dbs) / (1024 ** 3)

        badge = (
            ' <span style=' + DQ + 'background:#dc3545;color:white;font-size:10px;'
            'padding:2px 6px;border-radius:8px;' + DQ + '>'
            + str(inactive_in_section) + ' inactive</span>'
            if inactive_in_section > 0 else ""
        )
        h.append(
            '<h2 style=' + DQ + 'color:#1a1a2e;font-size:15px;border-bottom:3px solid '
            + color + ';padding-bottom:5px;margin-top:25px;' + DQ + '>'
            + title + ' (' + str(len(dbs)) + ')' + badge + '</h2>'
        )
        h.append(
            '<table width=' + DQ + '100%' + DQ + ' cellpadding=' + DQ + '0' + DQ +
            ' cellspacing=' + DQ + '0' + DQ + ' border=' + DQ + '0' + DQ +
            ' style=' + DQ + 'font-size:13px;' + DQ + '>'
            '<tr bgcolor=' + DQ + '#29B5E8' + DQ + '>'
        )
        for hd in ["", "Database", "Owner", "Size (GB)", "% Storage", "Last Access", "Idle", "Action"]:
            al = "right" if hd in ("Size", "Idle") else ("center" if hd == "" else "left")
            h.append(
                '<th style=' + DQ + 'padding:8px 10px;color:white;text-align:' + al + ';' + DQ + '>'
                + hd + '</th>'
            )
        h.append('</tr>')

        for i, row in enumerate(dbs):
            days_idle = row["DAYS_SINCE_ACCESS"]
            is_inactive = row["INACTIVE_30D"]
            size_bytes  = float(row["SIZE_BYTES"] or 0)

            # Status dot colour and idle label
            if days_idle is None:
                dot_color = "#dc3545"; idle_label = "90+d"
            elif days_idle > 30:
                dot_color = "#dc3545"; idle_label = str(days_idle) + "d"
            elif days_idle > 7:
                dot_color = "#ffc107"; idle_label = str(days_idle) + "d"
            else:
                dot_color = "#28a745"; idle_label = str(days_idle) + "d"

            # Proportional size bar (80px wide, relative to largest DB in account)
            bar_pct  = int((size_bytes / max_size) * 100) if max_size > 0 else 0
            size_bar = (
                '<table cellpadding=' + DQ + '0' + DQ + ' cellspacing=' + DQ + '0' + DQ +
                ' border=' + DQ + '0' + DQ + ' width=' + DQ + '80' + DQ + '><tr>'
                '<td bgcolor=' + DQ + '#29B5E8' + DQ + ' width=' + DQ + str(bar_pct) + DQ +
                ' style=' + DQ + 'height:7px;' + DQ + '></td>'
                '<td bgcolor=' + DQ + '#e9ecef' + DQ + ' width=' + DQ + str(80 - bar_pct) + DQ +
                ' style=' + DQ + 'height:7px;' + DQ + '></td>'
                '</tr></table>'
            )

            # USER: size gate (0.3 GB) before idle check. Non-USER: idle only.
            # Unconventional owner on non-SYSTEM DB → "Fix ownership" appended.
            rec       = ""
            rec_color = ""
            owner     = str(row["DATABASE_OWNER"])

            if is_user:
                # Personal databases: size + idle thresholds
                if is_inactive and size_bytes >= CLEANUP_THRESHOLD_BYTES:
                    if days_idle is not None and days_idle > 60:
                        rec       = "ACTION REQUIRED: Clean up"
                        rec_color = "#dc3545"
                    else:
                        rec       = "Recommend cleanup"
                        rec_color = "#ffc107"
            else:
                # Shared/system databases: idle threshold only
                if days_idle is not None and days_idle > 60:
                    rec       = "MUST DELETE"
                    rec_color = "#dc3545"
                elif is_inactive:
                    rec       = "Recommend delete"
                    rec_color = "#ffc107"

            # Ownership check: flag databases that do not follow the
            # expected role convention for their category.
            owner_follows_convention = (
                owner == "SYSADMIN" or
                owner.endswith("_DB_ROLE") or
                owner.endswith("_DB_ROLE_NEW")
            )
            if key not in ("SYSTEM",) and not owner_follows_convention:
                if rec:
                    rec += " + Fix ownership"
                else:
                    rec       = "Fix ownership"
                    rec_color = "#e65100"

            # Row background: pink highlight for large inactive USER DBs
            highlight_row = is_inactive and is_user and size_bytes > CLEANUP_THRESHOLD_BYTES
            row_bg = "#fff5f5" if highlight_row else ("#f8f9fa" if i % 2 == 1 else "#ffffff")

            h.append('<tr bgcolor=' + DQ + row_bg + DQ + '>')
            # Status dot
            h.append(
                '<td style=' + DQ + 'padding:7px;text-align:center;' + DQ + '>'
                '<table cellpadding=' + DQ + '0' + DQ + ' cellspacing=' + DQ + '0' + DQ +
                ' border=' + DQ + '0' + DQ + '><tr>'
                '<td bgcolor=' + DQ + dot_color + DQ + ' width=' + DQ + '9' + DQ +
                ' height=' + DQ + '9' + DQ + ' style=' + DQ + 'border-radius:50%;' + DQ + '>'
                '</td></tr></table></td>'
            )
            # Database name — escape() prevents XSS from unexpected chars in DB names
            h.append(
                '<td style=' + DQ + 'padding:7px 10px;font-weight:600;' + DQ + '>'
                + escape(row["DATABASE_NAME"]) + '</td>'
            )
            # Owner role — escape() for the same reason
            h.append(
                '<td style=' + DQ + 'padding:7px 10px;color:#555;' + DQ + '>'
                + escape(owner) + '</td>'
            )
            # Size in GB (pre-formatted numeric string, safe to embed directly)
            h.append(
                '<td style=' + DQ + 'padding:7px 10px;text-align:right;' + DQ + '>'
                + row["SIZE_GB"] + '</td>'
            )
            # Proportional size bar
            h.append(
                '<td style=' + DQ + 'padding:7px 10px;' + DQ + '>' + size_bar + '</td>'
            )
            # Last access timestamp — escape() because the value comes from
            # a database-sourced COALESCE that can contain freeform text
            h.append(
                '<td style=' + DQ + 'padding:7px 10px;color:#555;' + DQ + '>'
                + escape(str(row["LAST_ACCESSED_STR"])) + '</td>'
            )
            # Idle days
            h.append(
                '<td style=' + DQ + 'padding:7px 10px;text-align:right;color:'
                + dot_color + ';font-weight:600;' + DQ + '>' + idle_label + '</td>'
            )
            # Action recommendation
            if rec:
                h.append(
                    '<td style=' + DQ + 'padding:7px 10px;font-size:11px;font-weight:600;color:'
                    + rec_color + ';' + DQ + '>' + rec + '</td>'
                )
            else:
                h.append('<td style=' + DQ + 'padding:7px 10px;' + DQ + '></td>')
            h.append('</tr>')

        # Section footer row with aggregate counts
        h.append(
            '<tr bgcolor=' + DQ + '#f0f0f0' + DQ + '>'
            '<td colspan=' + DQ + '8' + DQ +
            ' style=' + DQ + 'padding:7px 10px;font-size:12px;color:#666;border-top:2px solid #ddd;' + DQ + '>'
            + str(len(dbs)) + ' databases | ' + '{:.4f}'.format(section_storage_gb) + ' GB total'
            '</td></tr></table>'
        )

    # Report footer
    h.append(
        '<p style=' + DQ + 'margin-top:25px;padding-top:12px;border-top:1px solid #eee;'
        'font-size:11px;color:#999;' + DQ + '>'
        'Generated by UTIL_DB.ADMIN.SEND_ACCOUNTADMIN_DB_REPORT'
        '</p>'
    )
    # Close inner card, outer centering table, body
    h.append('</td></tr></table></td></tr></table></body></html>')

    # SYSTEM$SEND_EMAIL has no parameterized binding — sql_esc() all values.
    # Q = chr(39) avoids quote-style mixing in the CALL string.
    html_body      = "".join(h)
    escaped_html   = sql_esc(html_body)
    subject        = sql_esc("[Monthly DB Report] " + account_label + " — " + report_date)
    Q = chr(39)   # single-quote character used in the SYSTEM$SEND_EMAIL call string

    sent_to = []
    failed  = []
    for name, email_addr in emails:
        try:
            safe_email = sql_esc(email_addr)
            send_sql = (
                "CALL SYSTEM$SEND_EMAIL("
                + Q + "MY_EMAIL_INTEGRATION" + Q + ", "
                + Q + safe_email + Q + ", "
                + Q + subject + Q + ", "
                + Q + escaped_html + Q + ", "
                + Q + "text/html" + Q + ")"
            )
            session.sql(send_sql).collect()
            sent_to.append(email_addr)
        except Exception as e:
            # Truncate to 50 chars to avoid leaking internal error details.
            failed.append(email_addr + ": " + str(e)[:50])

    return "Report sent to: " + str(len(sent_to)) + " recipients. Failed: " + str(len(failed))
$$;
