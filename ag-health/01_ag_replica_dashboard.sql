/*
AG replica dashboard
Shows role, health, synchronization, and failover settings.
*/
SET NOCOUNT ON;

SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    ars.role_desc,
    ars.connected_state_desc,
    ars.recovery_health_desc,
    ars.synchronization_health_desc,
    ar.availability_mode_desc,
    ar.failover_mode_desc,
    ar.session_timeout,
    ar.primary_role_allow_connections_desc,
    ar.secondary_role_allow_connections_desc,
    ars.last_connect_error_number,
    ars.last_connect_error_description,
    ars.last_connect_error_timestamp
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar
    ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars
    ON ar.replica_id = ars.replica_id
ORDER BY ag.name, ar.replica_server_name;
