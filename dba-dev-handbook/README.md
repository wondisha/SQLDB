# SQLDB DBA + Developer Toolkit

This toolkit provides verified starter scripts for:

- Performance tuning
- Index maintenance
- Blocking and deadlock monitoring
- Practical day-to-day DBA and developer operations

## Included folders

- `performance/`
  - `01_top_resource_queries.sql`
  - `02_missing_index_recommendations.sql`
  - `03_stats_health_check.sql`

- `index-maintenance/`
  - `01_index_fragmentation_report.sql`
  - `02_index_maintenance_generator.sql`

- `monitoring/blocking-deadlocks/`
  - `01_current_blocking_chains.sql`
  - `02_wait_stats_snapshot.sql`
  - `03_deadlock_report_from_system_health.sql`

- `dba-dev-handbook/`
  - `01_database_file_size_and_growth.sql`
  - `02_backup_freshness_check.sql`
  - `03_failed_jobs_last_7_days.sql`
  - `04_tempdb_usage_by_session.sql`
  - `05_long_running_transactions.sql`

## Permissions reference

Some scripts require:

- `VIEW SERVER STATE`
- Access to `msdb` (for backup/job history)
- `ALTER INDEX` (if executing generated maintenance commands)

## Operational guidance

1. Run diagnostics first and store baselines.
2. Validate recommendations before executing any DDL.
3. Schedule maintenance during low-traffic windows.
4. Use Query Store and Extended Events for deeper analysis.
