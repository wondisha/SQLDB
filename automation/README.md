# Automation and Alerting

This folder contains SQL Agent automation and alert scripts.

## Contents

- `sql-agent/01_create_sql_agent_automation_jobs.sql`
  - Creates daily health check, weekly index maintenance, and daily stats jobs.

- `alerts/01_deadlock_email_alert_setup.sql`
  - Creates a SQL Agent alert for deadlock victim errors (1205) and emails operator.

## Important placeholders

Before running, replace:

- `YourUserDatabase`
- `dba-team@example.com`
- Operator/profile names as needed

## Recommended deployment order

1. Deploy `index-maintenance/03_usp_index_maintenance.sql`
2. Configure Database Mail and SQL Agent Operator
3. Run alert setup script
4. Run SQL Agent jobs setup script
