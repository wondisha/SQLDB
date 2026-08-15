# Central AG Monitoring Mode

This folder contains scripts for hub-and-spoke AG monitoring where each SQL Server instance reports to a central monitoring database.

## Files

- `01_create_central_ag_schema.sql`
- `02_ingest_ag_health_proc.sql`
- `03_ingest_ag_sid_proc.sql`
- `04_create_central_alert_job.sql`
- `05_create_local_collector_job.sql`

## Deployment Order

1. Run `01_create_central_ag_schema.sql` on the central monitoring DB.
2. Run `02_ingest_ag_health_proc.sql` on the central monitoring DB.
3. Run `03_ingest_ag_sid_proc.sql` on the central monitoring DB.
4. Run `04_create_central_alert_job.sql` on the SQL instance hosting the central monitoring DB.
5. Run `05_create_local_collector_job.sql` on each AG instance that should publish local snapshots.

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
- Update placeholders in `05_create_local_collector_job.sql`:
  - `@CentralLinkedServer`
  - `@CentralDatabase`
- Confirm SQL Agent service account/login mapping can execute the central ingest procedures.

## Notes

- Keep all timestamps in UTC (`SYSUTCDATETIME()`).
- Tune thresholds and lookback window in `04_create_central_alert_job.sql`.
- If you only trust primary data collection, keep `@CollectPrimaryOnly = 1` in the local collector.
- Current SID collector step captures local baseline SIDs; cross-replica comparison can be added in an extended version with per-replica linked-server lookups.
