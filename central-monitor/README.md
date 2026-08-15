# Central AG Monitoring Mode

This folder contains scripts for hub-and-spoke AG monitoring where each SQL Server instance reports to a central monitoring database.

## Files

- `01_create_central_ag_schema.sql`
- `02_ingest_ag_health_proc.sql`
- `03_ingest_ag_sid_proc.sql`
- `04_create_central_alert_job.sql`
- `05_create_local_collector_job.sql`
- `06_create_local_sid_collector_v2.sql`

## Deployment Order

1. Run `01_create_central_ag_schema.sql` on the central monitoring DB.
2. Run `02_ingest_ag_health_proc.sql` on the central monitoring DB.
3. Run `03_ingest_ag_sid_proc.sql` on the central monitoring DB.
4. Run `04_create_central_alert_job.sql` on the SQL instance hosting the central monitoring DB.
5. Run `05_create_local_collector_job.sql` or `06_create_local_sid_collector_v2.sql` on each AG instance that should publish local snapshots.

## Suggested Architecture

- Each AG node (or AG primary only) runs a local collector job.
- Collector job builds JSON payload from AG DMVs.
- Collector sends payload to central DB via linked server call to:
  - `dbo.usp_AG_IngestHealthSnapshot`
  - `dbo.usp_AG_IngestSIDSnapshot`
- Central evaluator job reads recent snapshots and raises alerts.

## Local collector prerequisites

- Create a linked server on each AG node to the central SQL instance.
- Ensure **RPC OUT** is enabled on that linked server.
- Update placeholders in local collector script:
  - `@CentralLinkedServer`
  - `@CentralDatabase`
- Confirm SQL Agent service account/login mapping can execute the central ingest procedures.

## v2 SID collector prerequisites

`06_create_local_sid_collector_v2.sql` adds cross-replica SID comparison.

- Ensure `dbo.AGReplicaLinkedServers` exists on each local instance, with rows for each replica:
  - `replica_server_name` = target replica server name
  - `linked_server_name` = linked server to that replica
  - `is_enabled` = 1
- SQL Agent execution context must be able to query:
  - local `sys.server_principals`
  - remote `[linked].[master].[sys].[server_principals]`
- Remote linked servers should support RPC/RPC OUT as required by your security model.

Status values emitted by v2 include:
- `MATCH`
- `SID_MISMATCH`
- `MISSING_ON_REPLICA`
- `MISSING_LOCALLY`
- `LINKED_SERVER_ERROR`
- `NO_REPLICA_CONFIG`

## Notes

- Keep all timestamps in UTC (`SYSUTCDATETIME()`).
- Tune thresholds and lookback window in `04_create_central_alert_job.sql`.
- If you only trust primary data collection, keep `@CollectPrimaryOnly = 1` in local collectors.
- `05_create_local_collector_job.sql` captures SID baseline only (no cross-replica comparison).
- `06_create_local_sid_collector_v2.sql` performs cross-replica comparison via linked servers.
