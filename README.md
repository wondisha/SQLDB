# SQLDB Toolkit: Performance, Index Maintenance, Blocking & Deadlock Monitoring

This repository contains practical SQL Server scripts for DBAs and Developers.

## Structure

- `performance/` — performance tuning and workload analysis scripts
- `index-maintenance/` — index health, fragmentation, and maintenance scripts
- `monitoring/blocking-deadlocks/` — blocking, waits, and deadlock monitoring scripts
- `dba-dev-handbook/` — daily operations scripts useful to both DBAs and developers

## Safety Notes

- Review all scripts before running in production.
- Prefer testing in non-production first.
- Some scripts require elevated permissions (VIEW SERVER STATE, ALTER INDEX, etc.).
- Do not run maintenance scripts during peak hours without change control.

## SQL Server Compatibility

- Baseline: SQL Server 2016+
- Works best on SQL Server 2019/2022 with Query Store enabled.

## Suggested Rollout

1. Run read-only diagnostics first (`performance/`, `monitoring/`, `dba-dev-handbook/`).
2. Review findings and validate recommendations.
3. Schedule index and statistics maintenance during approved windows.
4. Add SQL Agent jobs for recurring checks.
