/*
================================================================================
  FILE: 06_automation/02_warehouse_catalog_proc.sql
  PURPOSE: Stored procedure that captures SHOW WAREHOUSES output into
           FINOPS.RAW.WAREHOUSE_CATALOG. Solves the session isolation problem
           that prevents SHOW + RESULT_SCAN from working inside Tasks.
  REQUIRES: FINOPS_ADMIN role | FINOPS database must exist (01_finops_schema_setup.sql)
  CALLED BY: FINOPS_WAREHOUSE_CATALOG_TASK (03_daily_snapshot_task.sql)
================================================================================

  WHY A STORED PROCEDURE?
  ────────────────────────
  Snowflake Tasks run each SQL statement in an isolated session. RESULT_SCAN()
  depends on LAST_QUERY_ID(), which returns the ID of the MOST RECENT QUERY
  IN THE CURRENT SESSION. In a Task, that is the task framework's own internal
  query — not your SHOW WAREHOUSES.

  A JavaScript stored procedure executes all its SQL within a single session
  context, so SHOW WAREHOUSES followed by RESULT_SCAN(LAST_QUERY_ID()) works
  correctly inside the procedure even when the procedure is called from a Task.

  COLUMN POSITIONS IN SHOW WAREHOUSES OUTPUT:
  ─────────────────────────────────────────────
  The positional columns ($1, $2, ...) from RESULT_SCAN after SHOW WAREHOUSES
  map to the following fields (verify against your Snowflake version):
    $1  = name
    $2  = state (STARTED, SUSPENDED)
    $3  = type (STANDARD, SNOWPARK-OPTIMIZED)
    $4  = size
    $5  = min_cluster_count
    $6  = max_cluster_count
    $7  = started_clusters
    $8  = running
    $9  = queued
    $10 = is_default
    $11 = is_current
    $12 = auto_suspend
    $13 = auto_resume
    ... (additional columns vary by version)
    $21 = owner
    $27 = resource_monitor
    $28 = budget (budget name if assigned)

  ⚠️ Column positions can shift between Snowflake releases. If the procedure
  produces unexpected values, run SHOW WAREHOUSES interactively and check
  the column positions with: SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
*/

USE ROLE FINOPS_ADMIN;
USE DATABASE FINOPS;
USE SCHEMA FINOPS.UTILS;


-- ─────────────────────────────────────────────────────────────────────────────
-- CREATE THE STORED PROCEDURE
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE PROCEDURE FINOPS.UTILS.REFRESH_WAREHOUSE_CATALOG()
RETURNS STRING
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
COMMENT = 'Runs SHOW WAREHOUSES and upserts results into FINOPS.RAW.WAREHOUSE_CATALOG. Must run as CALLER to inherit session privileges.'
AS $$
    try {
        // Step 1: Run SHOW WAREHOUSES within this procedure's session.
        // LAST_QUERY_ID() will refer to this SHOW command throughout
        // the rest of this procedure's execution.
        var showStmt = snowflake.createStatement({ sqlText: 'SHOW WAREHOUSES' });
        showStmt.execute();

        // Step 2: MERGE using RESULT_SCAN — within this session, LAST_QUERY_ID()
        // correctly points to the SHOW WAREHOUSES above.
        var mergeSQL = `
            MERGE INTO FINOPS.RAW.WAREHOUSE_CATALOG AS target
            USING (
                SELECT
                    $1::STRING   AS warehouse_name,
                    $4::STRING   AS warehouse_size,
                    $12::NUMBER  AS auto_suspend,
                    $3::STRING   AS warehouse_type,
                    -- Scaling policy is not in standard SHOW output; default to STANDARD
                    'STANDARD'   AS scaling_policy,
                    $5::NUMBER   AS min_cluster_count,
                    $6::NUMBER   AS max_cluster_count,
                    $21::STRING  AS owner_role,
                    $27::STRING  AS resource_monitor,
                    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS snapshot_time
                FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
            ) AS source
            ON UPPER(target.warehouse_name) = UPPER(source.warehouse_name)
            WHEN MATCHED THEN UPDATE SET
                warehouse_size    = source.warehouse_size,
                auto_suspend      = source.auto_suspend,
                warehouse_type    = source.warehouse_type,
                scaling_policy    = source.scaling_policy,
                min_cluster_count = source.min_cluster_count,
                max_cluster_count = source.max_cluster_count,
                owner_role        = source.owner_role,
                resource_monitor  = source.resource_monitor,
                snapshot_time     = source.snapshot_time
            WHEN NOT MATCHED THEN INSERT (
                warehouse_name, warehouse_size, auto_suspend, warehouse_type,
                scaling_policy, min_cluster_count, max_cluster_count,
                owner_role, resource_monitor, snapshot_time
            ) VALUES (
                source.warehouse_name, source.warehouse_size, source.auto_suspend,
                source.warehouse_type, source.scaling_policy, source.min_cluster_count,
                source.max_cluster_count, source.owner_role, source.resource_monitor,
                source.snapshot_time
            )
        `;

        var mergeStmt = snowflake.createStatement({ sqlText: mergeSQL });
        var result = mergeStmt.execute();
        result.next();

        return 'Warehouse catalog refreshed at ' + new Date().toISOString();

    } catch (err) {
        throw 'REFRESH_WAREHOUSE_CATALOG failed: ' + err.message;
    }
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- TEST THE PROCEDURE
-- ─────────────────────────────────────────────────────────────────────────────

-- Run manually to verify it works before scheduling as a Task:
CALL FINOPS.UTILS.REFRESH_WAREHOUSE_CATALOG();

-- Check the result:
SELECT * FROM FINOPS.RAW.WAREHOUSE_CATALOG ORDER BY warehouse_name;


-- ─────────────────────────────────────────────────────────────────────────────
-- QUERY: Join warehouse catalog to metering history (replaces SHOW + RESULT_SCAN)
-- ─────────────────────────────────────────────────────────────────────────────
-- Use this join pattern in automated reports instead of SHOW WAREHOUSES:
SELECT
    c.warehouse_name,
    c.warehouse_size,
    c.auto_suspend,
    c.resource_monitor,
    ROUND(SUM(m.CREDITS_USED), 2)   AS credits_last_30_days
FROM FINOPS.RAW.WAREHOUSE_CATALOG c
JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m
    ON UPPER(m.WAREHOUSE_NAME) = UPPER(c.warehouse_name)
WHERE m.START_TIME >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2, 3, 4
ORDER BY credits_last_30_days DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- TROUBLESHOOTING
-- ─────────────────────────────────────────────────────────────────────────────
/*
  ISSUE: Procedure returns wrong values (unexpected nulls or wrong sizes)
  FIX:   SHOW WAREHOUSES column positions may differ in your Snowflake version.
         Run SHOW WAREHOUSES interactively, then:
           SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) LIMIT 1;
         Verify the column positions and update $4, $12, $21, $27 in the procedure.

  ISSUE: "Object FINOPS.RAW.WAREHOUSE_CATALOG does not exist"
  FIX:   Run 06_automation/01_finops_schema_setup.sql first.

  ISSUE: Procedure executes successfully but table is empty
  FIX:   The MERGE may be filtering all rows. Check that the SHOW WAREHOUSES
         output has data: run SHOW WAREHOUSES interactively and verify there
         are rows before calling the procedure.

  ISSUE: EXECUTE AS CALLER vs EXECUTE AS OWNER
  FIX:   EXECUTE AS CALLER means the procedure runs with the privileges of
         whoever calls it. This is required because SHOW WAREHOUSES returns
         results based on the caller's role — a role with insufficient privileges
         may not see all warehouses. If the Task owner has a different role than
         expected, switch to EXECUTE AS OWNER and ensure the procedure owner
         has MONITOR USAGE on the account.
*/
