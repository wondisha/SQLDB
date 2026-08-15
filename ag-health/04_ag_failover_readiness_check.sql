/*
AG failover readiness check
Use before planned failover.
Flags non-synchronized databases and unhealthy replicas.
*/
SET NOCOUNT ON;

;WITH replica_health AS (
    SELECT
        ag.name AS ag_name,
        ar.replica_server_name,
        ars.role_desc,
        ars.connected_state_desc,
        ars.recovery_health_desc,
        ars.synchronization_health_desc,
        CASE
            WHEN ars.connected_state_desc <> 'CONNECTED' THEN 1
            WHEN ars.recovery_health_desc <> 'ONLINE' THEN 1
            WHEN ars.synchronization_health_desc NOT IN ('HEALTHY','PARTIALLY_HEALTHY') THEN 1
            ELSE 0
        END AS replica_issue
    FROM sys.availability_groups ag
    JOIN sys.availability_replicas ar
      ON ag.group_id = ar.group_id
    LEFT JOIN sys.dm_hadr_availability_replica_states ars
      ON ar.replica_id = ars.replica_id
),
db_health AS (
    SELECT
        ag.name AS ag_name,
        ar.replica_server_name,
        DB_NAME(drs.database_id) AS database_name,
        drs.is_primary_replica,
        drs.synchronization_state_desc,
        drs.synchronization_health_desc,
        drs.log_send_queue_size,
        drs.redo_queue_size,
        CASE
            WHEN drs.is_primary_replica = 0 AND drs.synchronization_state_desc <> 'SYNCHRONIZED' THEN 1
            WHEN drs.synchronization_health_desc <> 'HEALTHY' THEN 1
            ELSE 0
        END AS db_issue
    FROM sys.dm_hadr_database_replica_states drs
    JOIN sys.availability_replicas ar
      ON drs.replica_id = ar.replica_id
    JOIN sys.availability_groups ag
      ON ar.group_id = ag.group_id
)
SELECT
    rh.ag_name,
    rh.replica_server_name,
    rh.role_desc,
    rh.connected_state_desc,
    rh.recovery_health_desc,
    rh.synchronization_health_desc,
    rh.replica_issue,
    dh.database_name,
    dh.is_primary_replica,
    dh.synchronization_state_desc,
    dh.synchronization_health_desc AS db_sync_health,
    dh.log_send_queue_size,
    dh.redo_queue_size,
    dh.db_issue,
    CASE
        WHEN rh.replica_issue = 0 AND ISNULL(dh.db_issue,0) = 0 THEN 'READY'
        ELSE 'NOT_READY'
    END AS failover_readiness
FROM replica_health rh
LEFT JOIN db_health dh
    ON rh.ag_name = dh.ag_name
   AND rh.replica_server_name = dh.replica_server_name
ORDER BY rh.ag_name, rh.replica_server_name, dh.database_name;
