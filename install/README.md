# SQLDB AG Health Pack Installer

Use this installer to deploy the AG monitoring baseline in one run.

## File

- `install/01_install_ag_health_pack.sql`

## What it deploys

- Helper tables:
  - `dbo.AGReplicaLinkedServers`
  - `dbo.AGSidRepairLog`
- SQL Agent jobs:
  - `SQLDB - AG Health Alert Job`
  - `SQLDB - AG SID Consistency Check`
- Operator setup/update for alert email notifications

## Before running

1. Open `install/01_install_ag_health_pack.sql`.
2. Update configuration placeholders:
   - Operator name/email
   - Queue thresholds
   - Schedule names if desired
3. Execute on AG primary as `sysadmin`.

## After running

1. Populate `dbo.AGReplicaLinkedServers` with replica/linked-server mappings.
2. Ensure linked servers have RPC OUT enabled.
3. Run both jobs manually once and verify output.
4. Confirm SQL Agent email notifications.
