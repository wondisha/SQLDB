/*
AG database synchronization status
Includes send/redo queue and estimated data loss indicators.
*/
SET NOCOUNT ON;

SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    DB_NAME(drs.database_id) AS database_name,
    drs.is_local,
    drs.is_primary_replica,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.database_state_desc,
    drs.log_send_queue_size,      -- KB
    drs.log_send_rate,            -- KB/s
    drs.redo_queue_size,          -- KB
    drs.redo_rate,                -- KB/s
    drs.last_sent_time,
    drs.last_received_time,
    drs.last_hardened_time,
    drs.last_redone_time,
    drs.last_commit_time,
    DATEDIFF(SECOND, drs.last_commit_time, GETDATE()) AS approx_commit_lag_seconds
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar
    ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag
    ON ar.group_id = ag.group_id
ORDER BY ag.name, database_name, ar.replica_server_name;
