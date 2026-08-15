# Always On Availability Group (AG) Health Pack

This folder contains practical AG monitoring and repair scripts for SQL Server.

## Files

- `01_ag_replica_dashboard.sql`
- `02_ag_database_sync_status.sql`
- `03_ag_listener_and_routing_check.sql`
- `04_ag_failover_readiness_check.sql`
- `05_ag_recent_errors_from_xe.sql`
- `06_create_ag_health_alert_job.sql`
- `07_ag_sid_consistency_check.sql`
- `08_ag_sid_auto_repair.sql`
- `09_create_ag_sid_check_job_wrapper.sql`

## Permissions

Most queries require:

- `VIEW SERVER STATE`
- Metadata visibility on AG DMVs
- `msdb` access (for SQL Agent job setup)
- `sysadmin` for SID repair execution

## Usage

1. Run replica and database dashboards first.
2. Check send/redo queue growth and synchronization states.
3. Validate listener and read-only routing.
4. Run failover readiness check before any planned failover.
5. Review recent AG-related errors from Extended Events.
6. Deploy AG alert job for recurring monitoring and email notification.
7. Run SID consistency check across replicas.
8. Run SID auto-repair in PREVIEW mode first, then execute mode.
9. Deploy SID check SQL Agent wrapper for recurring report-only monitoring.

## SID repair notes (AD groups/users and SQL logins)

In scripts `07`, `08`, and `09`:

- Configure `@ReplicaServers` mapping (replica name -> linked server name).
- Ensure linked servers have RPC OUT enabled.
- Run `08_ag_sid_auto_repair.sql` with `@Execute = 0` first.
- After validation, set `@Execute = 1`.
