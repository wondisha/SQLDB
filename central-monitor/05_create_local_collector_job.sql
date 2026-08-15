/*
Create local collector SQL Agent job
Run this on each AG instance that should publish data to central monitoring.

Job name:
- SQLDB - Local AG Snapshot Collector

Behavior:
- Detect if local replica is PRIMARY for each AG
- Collect AG health rows from DMVs into JSON payload
- Collect AG SID consistency rows into JSON payload
- Push both payloads to central DB via linked server RPC:
    [<CentralLinkedServer>].[<CentralDB>].[dbo].[usp_AG_IngestHealthSnapshot]
    [<CentralLinkedServer>].[<CentralDB>].[dbo].[usp_AG_IngestSIDSnapshot]
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @CentralLinkedServer SYSNAME = N'CentralMonitorLS';
DECLARE @CentralDatabase SYSNAME = N'DBA_Monitor';
DECLARE @JobName SYSNAME = N'SQLDB - Local AG Snapshot Collector';
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
        @description = N'Collects local AG health/SID snapshots and pushes JSON payloads to central monitoring DB.';

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

IF @CollectPrimaryOnly = 1
BEGIN
    IF NOT EXISTS (SELECT 1 FROM #PrimaryAgs)
    BEGIN
        PRINT ''Local collector: no PRIMARY AG on this instance; skipping publish.'';
        RETURN;
    END
END

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

-- NOTE:
-- This local script records a baseline SID snapshot for SQL logins on the local instance.
-- Cross-replica SID comparison can be layered in if linked-server mappings exist per replica.
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
    sp.name,
    sp.type,
    N''LOCAL_BASELINE'',
    master.sys.fn_varbintohexstr(sp.sid),
    NULL,
    N''Captured local login SID baseline; compare across replicas in central analysis or extended collector.''
FROM sys.server_principals sp
WHERE sp.type IN (''S'',''U'',''G'')
  AND sp.name NOT LIKE ''##%''
  AND sp.name NOT LIKE ''NT SERVICE\%''
  AND sp.name NOT LIKE ''NT AUTHORITY\%'';

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

PRINT ''Local collector: published AG health and SID snapshot to central.'';
';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name = @JobName,
        @step_name = N'Collect + publish snapshots',
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

    PRINT 'Local collector job created/updated.';
END TRY
BEGIN CATCH
    DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR('Local collector job creation failed: %s', 16, 1, @Err);
END CATCH;
