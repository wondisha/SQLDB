/*
Create local collector SQL Agent job (v2 SID comparison)
Run this on each AG instance that should publish data to central monitoring.

Job name:
- SQLDB - Local AG Snapshot Collector v2

Behavior:
- Detect if local replica is PRIMARY for each AG
- Collect AG health rows from DMVs into JSON payload
- Compare local SQL login SIDs against configured remote replicas via linked servers
- Build explicit SID status rows: MATCH, SID_MISMATCH, MISSING_ON_REPLICA, LINKED_SERVER_ERROR
- Push both payloads to central DB via linked server RPC:
    [<CentralLinkedServer>].[<CentralDB>].[dbo].[usp_AG_IngestHealthSnapshot]
    [<CentralLinkedServer>].[<CentralDB>].[dbo].[usp_AG_IngestSIDSnapshot]

Prerequisites:
- dbo.AGReplicaLinkedServers exists on local instance and contains replica->linked server mappings.
- Linked servers to replicas and central monitor support RPC OUT.
- SQL Agent context can query sys.server_principals on remote replicas.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @CentralLinkedServer SYSNAME = N'CentralMonitorLS';
DECLARE @CentralDatabase SYSNAME = N'DBA_Monitor';
DECLARE @JobName SYSNAME = N'SQLDB - Local AG Snapshot Collector v2';
DECLARE @ScheduleName SYSNAME = N'SQLDB - Local AG Collector Every 5 Min';
DECLARE @CollectPrimaryOnly BIT = 1;

BEGIN TRY
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
    BEGIN
        EXEC msdb.dbo.sp_delete_job
            @job_name = @JobName,
            @delete_unused_schedule = 0;
    END;

    EXEC msdb.dbo.sp_add_job
        @job_name = @JobName,
        @enabled = 1,
        @description = N'Collects local AG health snapshots and performs cross-replica SID comparison before publishing to central DB.';

    DECLARE @Command NVARCHAR(MAX) = N'
SET NOCOUNT ON;
DECLARE @SourceInstance SYSNAME = @@SERVERNAME;
DECLARE @CapturedAt DATETIME2(0) = SYSUTCDATETIME();
DECLARE @PayloadHealth NVARCHAR(MAX);
DECLARE @PayloadSid NVARCHAR(MAX);
DECLARE @CollectPrimaryOnly BIT = ' + CAST(@CollectPrimaryOnly AS NVARCHAR(1)) + N';

IF OBJECT_ID(''tempdb..#PrimaryAgs'',''U'') IS NOT NULL DROP TABLE #PrimaryAgs;
CREATE TABLE #PrimaryAgs(ag_name SYSNAME PRIMARY KEY);

INSERT INTO #PrimaryAgs(ag_name)
SELECT ag.name
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states ars
  ON ag.group_id = ars.group_id
JOIN sys.availability_replicas ar
  ON ars.replica_id = ar.replica_id
WHERE ar.replica_server_name = @@SERVERNAME
  AND ars.role_desc = ''PRIMARY'';

IF @CollectPrimaryOnly = 1 AND NOT EXISTS (SELECT 1 FROM #PrimaryAgs)
BEGIN
    PRINT ''Local collector v2: no PRIMARY AG on this instance; skipping publish.'';
    RETURN;
END;

/* =========================
   AG Health payload
   ========================= */
;WITH src AS
(
    SELECT
        ag.name AS ag_name,
        ar.replica_server_name,
        adc.database_name,
        ars.role_desc,
        ars.connected_state_desc,
        drs.recovery_health_desc,
        drs.synchronization_health_desc,
        drs.synchronization_state_desc,
        CASE WHEN ars.role_desc = ''PRIMARY'' THEN 1 ELSE 0 END AS is_primary_replica,
        drs.log_send_queue_size AS log_send_queue_kb,
        drs.redo_queue_size AS redo_queue_kb,
        CAST(NULL AS NVARCHAR(4000)) AS details
    FROM sys.availability_groups ag
    JOIN sys.availability_replicas ar
      ON ag.group_id = ar.group_id
    JOIN sys.dm_hadr_availability_replica_states ars
      ON ar.replica_id = ars.replica_id
    LEFT JOIN sys.dm_hadr_database_replica_states drs
      ON ars.replica_id = drs.replica_id
    LEFT JOIN sys.availability_databases_cluster adc
      ON drs.group_database_id = adc.group_database_id
    WHERE (@CollectPrimaryOnly = 0 OR ag.name IN (SELECT ag_name FROM #PrimaryAgs))
)
SELECT @PayloadHealth =
(
    SELECT
        ag_name,
        replica_server_name,
        database_name,
        role_desc,
        connected_state_desc,
        recovery_health_desc,
        synchronization_health_desc,
        synchronization_state_desc,
        is_primary_replica,
        log_send_queue_kb,
        redo_queue_kb,
        details
    FROM src
    FOR JSON PATH
);

IF @PayloadHealth IS NULL OR @PayloadHealth = ''''
    SET @PayloadHealth = N''[]'';

/* =========================
   SID comparison payload
   ========================= */
IF OBJECT_ID(''tempdb..#LocalLogins'',''U'') IS NOT NULL DROP TABLE #LocalLogins;
CREATE TABLE #LocalLogins
(
    login_name SYSNAME NOT NULL PRIMARY KEY,
    principal_type CHAR(1) NOT NULL,
    local_sid_hex VARCHAR(200) NOT NULL
);

INSERT INTO #LocalLogins(login_name, principal_type, local_sid_hex)
SELECT
    sp.name,
    sp.type,
    master.sys.fn_varbintohexstr(sp.sid)
FROM sys.server_principals sp
WHERE sp.type = ''S''
  AND sp.name NOT LIKE ''##%''
  AND sp.name NOT LIKE ''NT SERVICE\%''
  AND sp.name NOT LIKE ''NT AUTHORITY\%'';

IF OBJECT_ID(''tempdb..#SidResults'',''U'') IS NOT NULL DROP TABLE #SidResults;
CREATE TABLE #SidResults
(
    replica_server_name SYSNAME NOT NULL,
    login_name SYSNAME NOT NULL,
    principal_type CHAR(1) NOT NULL,
    status NVARCHAR(50) NOT NULL,
    primary_sid_hex VARCHAR(200) NULL,
    secondary_sid_hex VARCHAR(200) NULL,
    details NVARCHAR(4000) NULL
);

IF OBJECT_ID(''dbo.AGReplicaLinkedServers'',''U'') IS NULL
BEGIN
    INSERT INTO #SidResults
    (
        replica_server_name,
        login_name,
        principal_type,
        status,
        primary_sid_hex,
        secondary_sid_hex,
        details
    )
    SELECT
        @@SERVERNAME,
        l.login_name,
        l.principal_type,
        N''LINKED_SERVER_ERROR'',
        l.local_sid_hex,
        NULL,
        N''dbo.AGReplicaLinkedServers not found on local instance.''
    FROM #LocalLogins l;
END
ELSE
BEGIN
    IF OBJECT_ID(''tempdb..#ReplicaMap'',''U'') IS NOT NULL DROP TABLE #ReplicaMap;
    CREATE TABLE #ReplicaMap
    (
        replica_server_name SYSNAME NOT NULL,
        linked_server_name SYSNAME NOT NULL
    );

    INSERT INTO #ReplicaMap(replica_server_name, linked_server_name)
    SELECT replica_server_name, linked_server_name
    FROM dbo.AGReplicaLinkedServers
    WHERE is_enabled = 1
      AND replica_server_name <> @@SERVERNAME;

    DECLARE @Replica SYSNAME;
    DECLARE @LS SYSNAME;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT replica_server_name, linked_server_name
        FROM #ReplicaMap;

    OPEN cur;
    FETCH NEXT FROM cur INTO @Replica, @LS;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            IF OBJECT_ID(''tempdb..#RemoteLogins'',''U'') IS NOT NULL DROP TABLE #RemoteLogins;
            CREATE TABLE #RemoteLogins
            (
                login_name SYSNAME NOT NULL PRIMARY KEY,
                remote_sid_hex VARCHAR(200) NOT NULL
            );

            DECLARE @sqlRemote NVARCHAR(MAX) =
N''INSERT INTO #RemoteLogins(login_name, remote_sid_hex)
SELECT name, master.sys.fn_varbintohexstr(sid)
FROM ['' + REPLACE(@LS,'']'','']]'' ) + N''].[master].[sys].[server_principals]
WHERE type = ''''S''''
  AND name NOT LIKE ''''##%''''
  AND name NOT LIKE ''''NT SERVICE\%''''
  AND name NOT LIKE ''''NT AUTHORITY\%'''''';

            EXEC (@sqlRemote);

            INSERT INTO #SidResults
            (
                replica_server_name,
                login_name,
                principal_type,
                status,
                primary_sid_hex,
                secondary_sid_hex,
                details
            )
            SELECT
                @Replica,
                l.login_name,
                l.principal_type,
                CASE
                    WHEN r.login_name IS NULL THEN N''MISSING_ON_REPLICA''
                    WHEN r.remote_sid_hex = l.local_sid_hex THEN N''MATCH''
                    ELSE N''SID_MISMATCH''
                END AS status,
                l.local_sid_hex,
                r.remote_sid_hex,
                CASE
                    WHEN r.login_name IS NULL THEN N''Login exists locally but missing on replica.''
                    WHEN r.remote_sid_hex = l.local_sid_hex THEN N''SIDs are consistent.''
                    ELSE N''SID values differ between local and replica.''
                END AS details
            FROM #LocalLogins l
            LEFT JOIN #RemoteLogins r
              ON l.login_name = r.login_name;

            -- Optional: mark logins that exist on replica but missing locally.
            INSERT INTO #SidResults
            (
                replica_server_name,
                login_name,
                principal_type,
                status,
                primary_sid_hex,
                secondary_sid_hex,
                details
            )
            SELECT
                @Replica,
                r.login_name,
                ''S'',
                N''MISSING_LOCALLY'',
                NULL,
                r.remote_sid_hex,
                N''Login exists on replica but missing locally.''
            FROM #RemoteLogins r
            LEFT JOIN #LocalLogins l
              ON r.login_name = l.login_name
            WHERE l.login_name IS NULL;
        END TRY
        BEGIN CATCH
            INSERT INTO #SidResults
            (
                replica_server_name,
                login_name,
                principal_type,
                status,
                primary_sid_hex,
                secondary_sid_hex,
                details
            )
            SELECT
                @Replica,
                l.login_name,
                l.principal_type,
                N''LINKED_SERVER_ERROR'',
                l.local_sid_hex,
                NULL,
                CONCAT(N''Failed querying linked server '', @LS, N'': '', ERROR_MESSAGE())
            FROM #LocalLogins l;
        END CATCH;

        FETCH NEXT FROM cur INTO @Replica, @LS;
    END

    CLOSE cur;
    DEALLOCATE cur;

    -- If no replicas configured, still emit baseline marker rows for visibility.
    IF NOT EXISTS (SELECT 1 FROM #ReplicaMap)
    BEGIN
        INSERT INTO #SidResults
        (
            replica_server_name,
            login_name,
            principal_type,
            status,
            primary_sid_hex,
            secondary_sid_hex,
            details
        )
        SELECT
            @@SERVERNAME,
            l.login_name,
            l.principal_type,
            N''NO_REPLICA_CONFIG'',
            l.local_sid_hex,
            NULL,
            N''No enabled replica mappings found in dbo.AGReplicaLinkedServers.''
        FROM #LocalLogins l;
    END
END;

SELECT @PayloadSid =
(
    SELECT
        replica_server_name,
        login_name,
        principal_type,
        status,
        primary_sid_hex,
        secondary_sid_hex,
        details
    FROM #SidResults
    FOR JSON PATH
);

IF @PayloadSid IS NULL OR @PayloadSid = ''''
    SET @PayloadSid = N''[]'';

/* =========================
   Publish to central
   ========================= */
DECLARE @SqlHealth NVARCHAR(MAX) =
N''EXEC [' + REPLACE(@CentralLinkedServer,']',']]') + N''].[' + REPLACE(@CentralDatabase,']',']]') + N'].[dbo].[usp_AG_IngestHealthSnapshot] '' +
N''@SourceInstance=@p1, @CapturedAt=@p2, @PayloadJson=@p3'';

EXEC sp_executesql
    @SqlHealth,
    N''@p1 SYSNAME, @p2 DATETIME2(0), @p3 NVARCHAR(MAX)'',
    @p1 = @SourceInstance,
    @p2 = @CapturedAt,
    @p3 = @PayloadHealth;

DECLARE @SqlSid NVARCHAR(MAX) =
N''EXEC [' + REPLACE(@CentralLinkedServer,']',']]') + N''].[' + REPLACE(@CentralDatabase,']',']]') + N'].[dbo].[usp_AG_IngestSIDSnapshot] '' +
N''@SourceInstance=@p1, @CapturedAt=@p2, @PayloadJson=@p3'';

EXEC sp_executesql
    @SqlSid,
    N''@p1 SYSNAME, @p2 DATETIME2(0), @p3 NVARCHAR(MAX)'',
    @p1 = @SourceInstance,
    @p2 = @CapturedAt,
    @p3 = @PayloadSid;

PRINT ''Local collector v2: published AG health and SID comparison snapshot to central.'';
';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name = @JobName,
        @step_name = N'Collect + compare + publish snapshots',
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = @Command;

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = @ScheduleName)
    BEGIN
        EXEC msdb.dbo.sp_add_schedule
            @schedule_name = @ScheduleName,
            @enabled = 1,
            @freq_type = 4,
            @freq_interval = 1,
            @freq_subday_type = 4,
            @freq_subday_interval = 5,
            @active_start_time = 000000;
    END;

    EXEC msdb.dbo.sp_attach_schedule
        @job_name = @JobName,
        @schedule_name = @ScheduleName;

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = @JobName;

    PRINT 'Local collector v2 job created/updated.';
END TRY
BEGIN CATCH
    DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR('Local collector v2 job creation failed: %s', 16, 1, @Err);
END CATCH;
