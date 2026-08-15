/*
AG listener and read-only routing check
*/
SET NOCOUNT ON;

-- Listener details
SELECT
    ag.name AS ag_name,
    l.dns_name AS listener_dns_name,
    l.port,
    ip.ip_address,
    ip.subnet_mask,
    ip.network_subnet_ip,
    ip.state_desc AS listener_ip_state
FROM sys.availability_group_listeners l
JOIN sys.availability_groups ag
    ON l.group_id = ag.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses ip
    ON l.listener_id = ip.listener_id
ORDER BY ag.name, l.dns_name;

-- Replica routing URL + read-only routing lists
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    ar.read_only_routing_url,
    ar.secondary_role_allow_connections_desc,
    ar.primary_role_allow_connections_desc
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag
    ON ar.group_id = ag.group_id
ORDER BY ag.name, ar.replica_server_name;

SELECT
    ag.name AS ag_name,
    ar.replica_server_name AS primary_replica,
    rl.routing_priority,
    ar2.replica_server_name AS readable_secondary
FROM sys.availability_read_only_routing_lists rl
JOIN sys.availability_replicas ar
    ON rl.replica_id = ar.replica_id
JOIN sys.availability_replicas ar2
    ON rl.read_only_replica_id = ar2.replica_id
JOIN sys.availability_groups ag
    ON ar.group_id = ag.group_id
ORDER BY ag.name, primary_replica, rl.routing_priority;
