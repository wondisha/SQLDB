# Health Check Dashboard

Query pack for daily DBA/developer checks.

## File

- `01_dashboard_query_pack.sql`

## What it covers

- Top waits
- Blocking sessions
- Backup freshness
- Failed jobs (24h)
- TempDB heavy sessions
- Long running transactions

Run with a login that has `VIEW SERVER STATE` and `msdb` read access.
