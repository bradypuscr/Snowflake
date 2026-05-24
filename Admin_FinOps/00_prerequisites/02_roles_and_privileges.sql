/*
================================================================================
  FILE: 00_prerequisites/02_roles_and_privileges.sql
  PURPOSE: Create dedicated FinOps roles and grant the minimum privileges
           needed to run all playbook queries.
  REQUIRES: ACCOUNTADMIN
  SAFE TO RUN: Yes — creates roles and grants only. Does not drop anything.
  RUN ONCE: Re-running is safe (uses CREATE IF NOT EXISTS patterns).
================================================================================
*/

USE ROLE ACCOUNTADMIN;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1: Create FinOps roles
-- ─────────────────────────────────────────────────────────────────────────────

-- FINOPS_ADMIN: Full read access to all cost data + ability to create monitors,
--              budgets, and manage tags. Assign to platform engineers and
--              finance partners who need to configure governance controls.
CREATE ROLE IF NOT EXISTS FINOPS_ADMIN
    COMMENT = 'Full access to Snowflake cost data, resource monitors, budgets, and tags. Managed by FinOps team.';

-- FINOPS_VIEWER: Read-only access to cost reports. Assign to team leads,
--               managers, and stakeholders who need visibility but should not
--               change configuration.
CREATE ROLE IF NOT EXISTS FINOPS_VIEWER
    COMMENT = 'Read-only access to FinOps cost reports. For team leads and business stakeholders.';

-- Role hierarchy: FINOPS_VIEWER is a subset of FINOPS_ADMIN
GRANT ROLE FINOPS_VIEWER TO ROLE FINOPS_ADMIN;

-- Grant FINOPS_ADMIN to SYSADMIN so it appears in the standard role hierarchy.
-- Adjust if your organization uses a different top-level role.
GRANT ROLE FINOPS_ADMIN TO ROLE SYSADMIN;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2: ACCOUNT_USAGE access
-- ─────────────────────────────────────────────────────────────────────────────

-- IMPORTED PRIVILEGES on the SNOWFLAKE database is the standard, recommended
-- way to grant access to ACCOUNT_USAGE views. It does not grant ACCOUNTADMIN.
-- Documentation: https://docs.snowflake.com/en/sql-reference/account-usage#enabling-account-usage-for-other-roles

GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE FINOPS_ADMIN;
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE FINOPS_VIEWER;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3: Resource monitor privileges
-- ─────────────────────────────────────────────────────────────────────────────

-- FINOPS_ADMIN needs to create and modify resource monitors.
-- MONITOR USAGE allows seeing warehouse-level credit consumption.
GRANT CREATE RESOURCE MONITOR ON ACCOUNT TO ROLE FINOPS_ADMIN;
GRANT MONITOR USAGE ON ACCOUNT TO ROLE FINOPS_ADMIN;

-- Read access for FINOPS_VIEWER: can see monitors but not create or modify them.
GRANT MONITOR USAGE ON ACCOUNT TO ROLE FINOPS_VIEWER;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4: Budget privileges
-- ─────────────────────────────────────────────────────────────────────────────

-- Budgets are managed through the SNOWFLAKE.CORE schema.
-- USAGE on the schema + CREATE BUDGET allows FINOPS_ADMIN to build budget objects.
GRANT DATABASE ROLE SNOWFLAKE.BUDGET_ADMIN TO ROLE FINOPS_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.BUDGET_VIEWER TO ROLE FINOPS_VIEWER;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5: Tag privileges (Enterprise Edition only)
-- ─────────────────────────────────────────────────────────────────────────────

-- TAG_ADMIN allows creating, modifying, and applying tags across the account.
-- If your account is Standard Edition, these grants will fail — skip this section.
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE FINOPS_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE FINOPS_VIEWER;

-- To apply tags to objects in specific databases, grant on those databases:
-- Example:
--   GRANT APPLY TAG ON ACCOUNT TO ROLE FINOPS_ADMIN;
-- The APPLY TAG privilege at the account level allows tagging any object.
-- For narrower scope, grant per-database:
--   GRANT APPLY TAG ON DATABASE <your_db> TO ROLE FINOPS_ADMIN;

-- ⚠️ Uncomment and adjust before running:
-- GRANT APPLY TAG ON ACCOUNT TO ROLE FINOPS_ADMIN;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 6: FINOPS database privileges (created in 06_automation)
-- ─────────────────────────────────────────────────────────────────────────────

-- These grants assume the FINOPS database has already been created by
-- 06_automation/01_finops_schema_setup.sql. Run that script first,
-- then return here to apply these grants — or run them after the fact.

-- ⚠️ Uncomment after running 06_automation/01_finops_schema_setup.sql:
/*
GRANT USAGE  ON DATABASE FINOPS TO ROLE FINOPS_ADMIN;
GRANT USAGE  ON DATABASE FINOPS TO ROLE FINOPS_VIEWER;
GRANT USAGE  ON ALL SCHEMAS IN DATABASE FINOPS TO ROLE FINOPS_ADMIN;
GRANT USAGE  ON ALL SCHEMAS IN DATABASE FINOPS TO ROLE FINOPS_VIEWER;
GRANT SELECT ON ALL TABLES IN DATABASE FINOPS TO ROLE FINOPS_ADMIN;
GRANT SELECT ON ALL TABLES IN DATABASE FINOPS TO ROLE FINOPS_VIEWER;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA FINOPS.RAW TO ROLE FINOPS_ADMIN;

-- Future grants so new tables created later are automatically accessible:
GRANT SELECT ON FUTURE TABLES IN DATABASE FINOPS TO ROLE FINOPS_VIEWER;
GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN DATABASE FINOPS TO ROLE FINOPS_ADMIN;
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 7: Assign roles to users
-- ─────────────────────────────────────────────────────────────────────────────

-- Replace with your actual usernames. You can also grant roles to other roles
-- if your organization uses role hierarchies.

-- ⚠️ Replace user names before running:
/*
GRANT ROLE FINOPS_ADMIN  TO USER <platform_engineer_username>;
GRANT ROLE FINOPS_ADMIN  TO USER <finops_lead_username>;
GRANT ROLE FINOPS_VIEWER TO USER <team_lead_username>;
GRANT ROLE FINOPS_VIEWER TO USER <manager_username>;
*/


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 8: Verify grants
-- ─────────────────────────────────────────────────────────────────────────────

-- After running this script, verify the role structure looks correct.
SHOW GRANTS TO ROLE FINOPS_ADMIN;
SHOW GRANTS TO ROLE FINOPS_VIEWER;

-- Test that FINOPS_ADMIN can access ACCOUNT_USAGE:
-- USE ROLE FINOPS_ADMIN;
-- SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY LIMIT 1;
