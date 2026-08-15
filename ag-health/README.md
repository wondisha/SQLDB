# Always On Availability Group (AG) Health Pack

This folder contains practical AG monitoring scripts for SQL Server.

## Files

- `01_ag_replica_dashboard.sql`
- `02_ag_database_sync_status.sql`
- `03_ag_listener_and_routing_check.sql`
- `04_ag_failover_readiness_check.sql`
- `05_ag_recent_errors_from_xe.sql`

## Permissions

Most queries require:

- `VIEW SERVER STATE`
- Metadata visibility on AG DMVs

## Usage

1. Run replica and database dashboards first.
2. Check send/redo queue growth and synchronization states.
3. Validate listener and read-only routing.
4. Run failover readiness check before any planned failover.
5. Review recent AG-related errors from Extended Events.
