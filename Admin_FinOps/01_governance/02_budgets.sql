/*
================================================================================
  FILE: 01_governance/02_budgets.sql
  PURPOSE: Snowflake Budget setup for team-level cost tracking across all
           billing categories (compute + serverless + AI).
  REQUIRES: SNOWFLAKE.BUDGET_ADMIN database role (granted in 02_roles_and_privileges.sql)
  DOCUMENTATION: https://docs.snowflake.com/en/user-guide/budgets
================================================================================

  KEY DIFFERENCES FROM RESOURCE MONITORS:
  ────────────────────────────────────────
  • Budgets cover compute + serverless + AI. Resource monitors cover compute only.
  • Budgets do NOT stop spending by default — they alert only.
  • Budgets track a rolling monthly window, not a fixed calendar month.
  • A single budget can be assigned to multiple objects (warehouses, schemas, databases).
  • A budget alert fires when spending reaches the SPENDING_LIMIT — once per period.

  COST:
  ─────
  Budgets themselves consume serverless credits when they run their evaluation
  process. This is typically very small (< 1 credit/month per budget) but worth
  noting when calculating the overhead of your FinOps infrastructure.
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1: Account-level budget (full account visibility)
-- ─────────────────────────────────────────────────────────────────────────────
-- The account budget is a built-in budget automatically available for the whole
-- account. You do not need to create it — just configure the spending limit.
-- This is different from custom budgets which you create per team.

-- View the current account budget status:
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!GET_SPENDING_LIMIT();
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!GET_SERVICE_TYPE_BUDGET_STATUSES();

-- Set the account-level spending limit (in credits, monthly rolling window):
-- ⚠️ Replace 10000 with your actual monthly credit budget.
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SET_SPENDING_LIMIT(10000);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2: Custom team budgets
-- ─────────────────────────────────────────────────────────────────────────────
-- Create one budget per team. Each budget covers all objects assigned to it,
-- including the serverless activity within those schemas.

-- Analytics team budget
-- ⚠️ Replace 500 with the team's actual monthly credit budget.
CREATE SNOWFLAKE.CORE.BUDGET analytics_team_budget
    WITH SPENDING_LIMIT = 500
    COMMENT = 'Monthly credit budget for Analytics team. Covers ANALYTICS_WH and PROD.ANALYTICS schema.';

-- Data Engineering team budget
CREATE SNOWFLAKE.CORE.BUDGET data_engineering_budget
    WITH SPENDING_LIMIT = 800
    COMMENT = 'Monthly credit budget for Data Engineering. Covers DE_WH, INGESTION_WH, and PROD.RAW + PROD.STAGED schemas.';

-- ML Platform team budget
CREATE SNOWFLAKE.CORE.BUDGET ml_platform_budget
    WITH SPENDING_LIMIT = 1200
    COMMENT = 'Monthly credit budget for ML Platform. Covers ML_WH and ML schema.';


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3: Assign objects to budgets
-- ─────────────────────────────────────────────────────────────────────────────
-- Add warehouses and schemas to each budget. Schemas cover all objects within
-- them, including serverless costs like Automatic Clustering on their tables.

-- Analytics team: warehouse + schema
CALL analytics_team_budget!ADD_RESOURCE(
    SYSTEM$REFERENCE('WAREHOUSE', 'ANALYTICS_WH', 'SESSION', 'APPLYBUDGET')
);
CALL analytics_team_budget!ADD_RESOURCE(
    SYSTEM$REFERENCE('SCHEMA', 'PROD.ANALYTICS', 'SESSION', 'APPLYBUDGET')
);

-- Data Engineering team: multiple warehouses + multiple schemas
CALL data_engineering_budget!ADD_RESOURCE(
    SYSTEM$REFERENCE('WAREHOUSE', 'DE_WH', 'SESSION', 'APPLYBUDGET')
);
CALL data_engineering_budget!ADD_RESOURCE(
    SYSTEM$REFERENCE('WAREHOUSE', 'INGESTION_WH', 'SESSION', 'APPLYBUDGET')
);
CALL data_engineering_budget!ADD_RESOURCE(
    SYSTEM$REFERENCE('SCHEMA', 'PROD.RAW', 'SESSION', 'APPLYBUDGET')
);
CALL data_engineering_budget!ADD_RESOURCE(
    SYSTEM$REFERENCE('SCHEMA', 'PROD.STAGED', 'SESSION', 'APPLYBUDGET')
);

-- ML Platform: warehouse + schema
CALL ml_platform_budget!ADD_RESOURCE(
    SYSTEM$REFERENCE('WAREHOUSE', 'ML_WH', 'SESSION', 'APPLYBUDGET')
);
CALL ml_platform_budget!ADD_RESOURCE(
    SYSTEM$REFERENCE('SCHEMA', 'PROD.ML', 'SESSION', 'APPLYBUDGET')
);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4: Review budget status
-- ─────────────────────────────────────────────────────────────────────────────

-- Check current spending against each budget's limit.
-- Run these queries regularly or schedule them as part of your weekly report.

CALL analytics_team_budget!GET_SPENDING_LIMIT();
CALL analytics_team_budget!GET_SERVICE_TYPE_BUDGET_STATUSES();

CALL data_engineering_budget!GET_SPENDING_LIMIT();
CALL data_engineering_budget!GET_SERVICE_TYPE_BUDGET_STATUSES();

CALL ml_platform_budget!GET_SPENDING_LIMIT();
CALL ml_platform_budget!GET_SERVICE_TYPE_BUDGET_STATUSES();

-- List all custom budgets in the account:
SHOW BUDGETS IN ACCOUNT;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5: Remove resources from a budget
-- ─────────────────────────────────────────────────────────────────────────────
-- When a team reorganizes or a warehouse is repurposed, remove it from the budget
-- before deleting or reassigning it.

-- Example: Remove a warehouse from analytics budget
-- CALL analytics_team_budget!REMOVE_RESOURCE(
--     SYSTEM$REFERENCE('WAREHOUSE', 'OLD_ANALYTICS_WH', 'SESSION', 'APPLYBUDGET')
-- );


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 6: Delete a budget
-- ─────────────────────────────────────────────────────────────────────────────
-- Budgets must have all resources removed before they can be dropped.
-- ⚠️ This is irreversible. Remove all resources first.

-- DROP SNOWFLAKE.CORE.BUDGET analytics_team_budget;


-- ─────────────────────────────────────────────────────────────────────────────
-- TROUBLESHOOTING
-- ─────────────────────────────────────────────────────────────────────────────
/*
  ISSUE: "Insufficient privileges" when creating budget
  FIX:   Your role needs the SNOWFLAKE.BUDGET_ADMIN database role.
         Run as ACCOUNTADMIN: GRANT DATABASE ROLE SNOWFLAKE.BUDGET_ADMIN TO ROLE FINOPS_ADMIN;

  ISSUE: Budget spending amount does not match ACCOUNT_USAGE queries
  FIX:   Budget data has up to 2 hours of latency. ACCOUNT_USAGE data has up to
         3 hours. Neither is real-time. For exact figures, use your Snowflake
         invoice or ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY (72h latency).

  ISSUE: Budget is not capturing serverless spend
  FIX:   Serverless spend is attributed to the schema where the objects live.
         If you added a WAREHOUSE to the budget but not the SCHEMA, serverless
         activity in that schema will not be counted. Add both.

  ISSUE: Budget alert fired but spending seems normal
  FIX:   Budgets track a rolling 30-day window, not a calendar month. Spending
         from 29 days ago still counts toward today's total. A spend spike
         from last month can trigger an alert this month.

  ISSUE: SYSTEM$REFERENCE fails with "object not found"
  FIX:   The object name in SYSTEM$REFERENCE must match exactly (case-sensitive
         for some object types). For warehouses, use the uppercase name:
           SYSTEM$REFERENCE('WAREHOUSE', 'MY_WH', 'SESSION', 'APPLYBUDGET')
         Not 'my_wh' or 'My_Wh'.
*/
