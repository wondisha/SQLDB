/*
Single-Run Installer: AG Health Pack
Repository: wondisha/SQLDB

What this installer does:
1) Validates basic prerequisites.
2) Creates helper objects for AG health checks and SID checks.
3) Creates/updates SQL Agent jobs:
   - SQLDB - AG Health Alert Job
   - SQLDB - AG SID Consistency Check
4) Prints post-install checklist.

IMPORTANT:
- Update placeholders in section [CONFIGURATION].
- Run as sysadmin.
- Execute on the primary replica instance where SQL Agent runs.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

PRINT '=== SQLDB AG Health Pack Installer started ===';

/* ============================================================
   [CONFIGURATION] - UPDATE THESE VALUES
   ============================================================ */
DECLARE @OperatorName SYSNAME = N'DBA_Operator';
DECLARE @OperatorEmail NVARCHAR(256) = N'dba-team@example.com';
DECLARE @HealthScheduleName SYSNAME = N'SQLDB - Every 5 Min';
DECLARE @SidScheduleName SYSNAME = N'SQLDB - Every 30 Min';
DECLARE @LogSendQueueThresholdKB BIGINT = 102400; -- 100 MB
DECLARE @RedoQueueThresholdKB BIGINT = 102400;    -- 100 MB

/*
Replica -> Linked Server mapping is stored in dbo.AGReplicaLinkedServers.
Populate after install if not already populated.
*/

/***************************************************************
  1) PREREQUISITE CHECKS
****************************************************************/
BEGIN TRY
    IF IS_SRVROLEMEMBER('sysadmin') <> 1
    BEGIN
        RAISERROR('Installer must be executed by a sysadmin.', 16, 1);
        RETURN;
    END;

    IF SERVERPROPERTY('IsHadrEnabled') <> 1
    BEGIN
        RAISERROR('Always On AG is not enabled on this SQL Server instance.', 16, 1);
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.availability_groups)
    BEGIN
        RAISERROR('No availability groups found on this instance.', 16, 1);
        RETURN;
    END;

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syssubsystems WHERE subsystem = 'TSQL')
    BEGIN
        RAISERROR('SQL Server Agent TSQL subsystem not available.', 16, 1);
        RETURN;
    END;

    PRINT 'Prerequisite checks passed.';
END TRY
BEGIN CATCH
    RAISERROR('Prerequisite check failed: %s', 16, 1, ERROR_MESSAGE());
    RETURN;
END CATCH;

/***************************************************************
  2) HELPER OBJECTS
****************************************************************/
BEGIN TRY
    IF OBJECT_ID('dbo.AGReplicaLinkedServers','U') IS NULL
    BEGIN
        CREATE TABLE dbo.AGReplicaLinkedServers
        (
            replica_server_name SYSNAME NOT NULL PRIMARY KEY,
            linked_server_name SYSNAME NOT NULL,
            is_primary BIT NOT NULL DEFAULT(0),
            is_enabled BIT NOT NULL DEFAULT(1),
            created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
            updated_at DATETIME2(0) NULL
        );
        PRINT 'Created dbo.AGReplicaLinkedServers';
    END
    ELSE
    BEGIN
        PRINT 'dbo.AGReplicaLinkedServers already exists';
    END;

    IF OBJECT_ID('dbo.AGSidRepairLog','U') IS NULL
    BEGIN
        CREATE TABLE dbo.AGSidRepairLog
        (
            log_id BIGINT IDENTITY(1,1) PRIMARY KEY,
            run_id UNIQUEIDENTIFIER NOT NULL,
            logged_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
            replica_server_name SYSNAME NOT NULL,
            login_name SYSNAME NOT NULL,
            principal_type CHAR(1) NOT NULL,
            action_type NVARCHAR(50) NOT NULL,
            command_text NVARCHAR(MAX) NULL,
            success BIT NULL,
            error_message NVARCHAR(4000) NULL
        );
        PRINT 'Created dbo.AGSidRepairLog';
    END
    ELSE
    BEGIN
        PRINT 'dbo.AGSidRepairLog already exists';
    END;
END TRY
BEGIN CATCH
    RAISERROR('Helper object creation failed: %s', 16, 1, ERROR_MESSAGE());
    RETURN;
END CATCH;

/***************************************************************
  3) OPERATOR
****************************************************************/
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
    BEGIN
        EXEC msdb.dbo.sp_add_operator
            @name = @OperatorName,
            @enabled = 1,
            @email_address = @OperatorEmail;
        PRINT 'Created operator: ' + @OperatorName;
    END
    ELSE
    BEGIN
        EXEC msdb.dbo.sp_update_operator
            @name = @OperatorName,
            @enabled = 1,
            @email_address = @OperatorEmail;
        PRINT 'Updated operator: ' + @OperatorName;
    END;
END TRY
BEGIN CATCH
    RAISERROR('Operator setup failed: %s', 16, 1, ERROR_MESSAGE());
    RETURN;
END CATCH;

/***************************************************************
  4) JOB: SQLDB - AG Health Alert Job
****************************************************************/
BEGIN TRY
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLDB - AG Health Alert Job')
    BEGIN
        EXEC msdb.dbo.sp_delete_job
            @job_name = N'SQLDB - AG Health Alert Job',
            @delete_unused_schedule = 0;
        PRINT 'Dropped existing job: SQLDB - AG Health Alert Job';
    END;

    EXEC msdb.dbo.sp_add_job
        @job_name = N'SQLDB - AG Health Alert Job',
        @enabled = 1,
        @description = N'Monitors AG health and fails when thresholds or health conditions are violated.';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name = N'SQLDB - AG Health Alert Job',
        @step_name = N'Check AG Health',
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'
SET NOCOUNT ON;
DECLARE @LogSendQueueThresholdKB BIGINT = ' + CAST(@LogSendQueueThresholdKB AS NVARCHAR(30)) + N';
DECLARE @RedoQueueThresholdKB BIGINT = ' + CAST(@RedoQueueThresholdKB AS NVARCHAR(30)) + N';

IF OBJECT_ID(''tempdb..#issues'') IS NOT NULL DROP TABLE #issues;
CREATE TABLE #issues
(
    issue_type NVARCHAR(100),
    ag_name SYSNAME NULL,
    replica_server_name SYSNAME NULL,
    database_name SYSNAME NULL,
    details NVARCHAR(4000)
);

INSERT INTO #issues(issue_type, ag_name, replica_server_name, database_name, details)
SELECT N''REPLICA_HEALTH'', ag.name, ar.replica_server_name, NULL,
       CONCAT(N''role='', ISNULL(ars.role_desc,N''UNKNOWN''),
              N''; connected='', ISNULL(ars.connected_state_desc,N''UNKNOWN''),
              N''; recovery='', ISNULL(ars.recovery_health_desc,N''UNKNOWN''),
              N''; sync_health='', ISNULL(ars.synchronization_health_desc,N''UNKNOWN''))
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ars.connected_state_desc <> ''CONNECTED''
   OR ars.recovery_health_desc <> ''ONLINE''
   OR ars.synchronization_health_desc NOT IN (''HEALTHY'',''PARTIALLY_HEALTHY'');

INSERT INTO #issues(issue_type, ag_name, replica_server_name, database_name, details)
SELECT N''DB_SYNC_HEALTH'', ag.name, ar.replica_server_name, DB_NAME(drs.database_id),
       CONCAT(N''sync_state='', drs.synchronization_state_desc,
              N''; sync_health='', drs.synchronization_health_desc,
              N''; is_primary='', drs.is_primary_replica)
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE drs.synchronization_health_desc <> ''HEALTHY''
   OR (drs.is_primary_replica = 0 AND drs.synchronization_state_desc <> ''SYNCHRONIZED'');

INSERT INTO #issues(issue_type, ag_name, replica_server_name, database_name, details)
SELECT N''QUEUE_THRESHOLD'', ag.name, ar.replica_server_name, DB_NAME(drs.database_id),
       CONCAT(N''log_send_queue_kb='', drs.log_send_queue_size,
              N''; redo_queue_kb='', drs.redo_queue_size,
              N''; thresholds='', @LogSendQueueThresholdKB, N''/'', @RedoQueueThresholdKB)
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE drs.log_send_queue_size > @LogSendQueueThresholdKB
   OR drs.redo_queue_size > @RedoQueueThresholdKB;

IF EXISTS (SELECT 1 FROM #issues)
BEGIN
    SELECT * FROM #issues ORDER BY issue_type, ag_name, replica_server_name, database_name;
    RAISERROR (''AG health alert: issues detected. Review job output details.'', 16, 1);
END
ELSE
BEGIN
    PRINT ''AG health check passed. No issues found.'';
END';

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = @HealthScheduleName)
    BEGIN
        EXEC msdb.dbo.sp_add_schedule
            @schedule_name = @HealthScheduleName,
            @enabled = 1,
            @freq_type = 4,
            @freq_interval = 1,
            @freq_subday_type = 4,
            @freq_subday_interval = 5,
            @active_start_time = 000000;
    END;

    EXEC msdb.dbo.sp_attach_schedule
        @job_name = N'SQLDB - AG Health Alert Job',
        @schedule_name = @HealthScheduleName;

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'SQLDB - AG Health Alert Job';

    EXEC msdb.dbo.sp_update_job
        @job_name = N'SQLDB - AG Health Alert Job',
        @notify_level_email = 2,
        @notify_email_operator_name = @OperatorName;

    PRINT 'Created/updated job: SQLDB - AG Health Alert Job';
END TRY
BEGIN CATCH
    RAISERROR('AG health job setup failed: %s', 16, 1, ERROR_MESSAGE());
    RETURN;
END CATCH;

/***************************************************************
  5) JOB: SQLDB - AG SID Consistency Check (report only)
****************************************************************/
BEGIN TRY
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLDB - AG SID Consistency Check')
    BEGIN
        EXEC msdb.dbo.sp_delete_job
            @job_name = N'SQLDB - AG SID Consistency Check',
            @delete_unused_schedule = 0;
        PRINT 'Dropped existing job: SQLDB - AG SID Consistency Check';
    END;

    EXEC msdb.dbo.sp_add_job
        @job_name = N'SQLDB - AG SID Consistency Check',
        @enabled = 1,
        @description = N'Runs AG SID consistency check (report-only) and fails when mismatches are detected.';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name = N'SQLDB - AG SID Consistency Check',
        @step_name = N'Run SID consistency check',
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'
SET NOCOUNT ON;

DECLARE @ReplicaServers TABLE
(
    replica_server_name SYSNAME NOT NULL,
    linked_server_name SYSNAME NOT NULL,
    is_primary BIT NOT NULL
);

INSERT INTO @ReplicaServers(replica_server_name, linked_server_name, is_primary)
SELECT replica_server_name, linked_server_name, is_primary
FROM dbo.AGReplicaLinkedServers
WHERE is_enabled = 1;

IF NOT EXISTS (SELECT 1 FROM @ReplicaServers WHERE is_primary = 1)
BEGIN
    RAISERROR(''Populate dbo.AGReplicaLinkedServers with at least one primary and one secondary mapping.'', 16, 1);
    RETURN;
END;

IF OBJECT_ID(''tempdb..#primary_logins'') IS NOT NULL DROP TABLE #primary_logins;
CREATE TABLE #primary_logins
(
    login_name SYSNAME NOT NULL,
    type CHAR(1) NOT NULL,
    sid VARBINARY(85) NOT NULL
);

INSERT INTO #primary_logins(login_name, type, sid)
SELECT sp.name, sp.type, sp.sid
FROM sys.server_principals sp
WHERE sp.type IN (''S'',''U'',''G'')
  AND sp.name NOT LIKE ''##%''
  AND sp.name NOT LIKE ''NT AUTHORITY\%''
  AND sp.name NOT LIKE ''NT SERVICE\%''
  AND sp.name <> ''sa'';

IF OBJECT_ID(''tempdb..#secondary_logins'') IS NOT NULL DROP TABLE #secondary_logins;
CREATE TABLE #secondary_logins
(
    replica_server_name SYSNAME NOT NULL,
    login_name SYSNAME NOT NULL,
    type CHAR(1) NOT NULL,
    sid VARBINARY(85) NULL
);

DECLARE @Replica SYSNAME, @Linked SYSNAME, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
SELECT replica_server_name, linked_server_name
FROM @ReplicaServers WHERE is_primary = 0;

OPEN c;
FETCH NEXT FROM c INTO @Replica, @Linked;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N''
    INSERT INTO #secondary_logins(replica_server_name, login_name, type, sid)
    SELECT N'''''' + REPLACE(@Replica,'''''','''''''') + N'''''' ,
           CAST(R.sp_name AS SYSNAME),
           CAST(R.sp_type AS CHAR(1)),
           CAST(R.sp_sid AS VARBINARY(85))
    FROM OPENQUERY('' + QUOTENAME(@Linked) + N'',
      ''''SELECT sp.name AS sp_name, sp.type AS sp_type, sp.sid AS sp_sid
         FROM master.sys.server_principals sp
         WHERE sp.type IN (''''''''S'''''''',''''''''U'''''''',''''''''G'''''''')
           AND sp.name NOT LIKE ''''''''##%''''''''
           AND sp.name NOT LIKE ''''''''NT AUTHORITY\\%''''''''
           AND sp.name NOT LIKE ''''''''NT SERVICE\\%''''''''
           AND sp.name <> ''''''''sa'''''''' '''') AS R;
    '';

    BEGIN TRY
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        PRINT ''Failed to query linked server '' + @Linked + '': '' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM c INTO @Replica, @Linked;
END

CLOSE c;
DEALLOCATE c;

IF OBJECT_ID(''tempdb..#issues'') IS NOT NULL DROP TABLE #issues;
CREATE TABLE #issues
(
    replica_server_name SYSNAME,
    login_name SYSNAME,
    principal_type CHAR(1),
    status NVARCHAR(50),
    primary_sid_hex VARCHAR(200),
    secondary_sid_hex VARCHAR(200)
);

INSERT INTO #issues
SELECT
    s.replica_server_name,
    p.login_name,
    p.type,
    CASE
        WHEN s.login_name IS NULL THEN ''MISSING_ON_SECONDARY''
        WHEN s.sid IS NULL THEN ''MISSING_SID_ON_SECONDARY''
        WHEN p.sid <> s.sid THEN ''SID_MISMATCH''
        ELSE ''MATCH''
    END AS status,
    CONVERT(VARCHAR(200), p.sid, 1),
    CONVERT(VARCHAR(200), s.sid, 1)
FROM #primary_logins p
LEFT JOIN #secondary_logins s
  ON p.login_name = s.login_name
WHERE s.login_name IS NULL OR s.sid IS NULL OR p.sid <> s.sid;

IF EXISTS (SELECT 1 FROM #issues)
BEGIN
    SELECT * FROM #issues ORDER BY replica_server_name, principal_type, status, login_name;
    RAISERROR(''AG SID consistency check failed: mismatches/missing logins detected.'', 16, 1);
END
ELSE
BEGIN
    PRINT ''AG SID consistency check passed.'';
END';

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = @SidScheduleName)
    BEGIN
        EXEC msdb.dbo.sp_add_schedule
            @schedule_name = @SidScheduleName,
            @enabled = 1,
            @freq_type = 4,
            @freq_interval = 1,
            @freq_subday_type = 4,
            @freq_subday_interval = 30,
            @active_start_time = 000000;
    END;

    EXEC msdb.dbo.sp_attach_schedule
        @job_name = N'SQLDB - AG SID Consistency Check',
        @schedule_name = @SidScheduleName;

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'SQLDB - AG SID Consistency Check';

    EXEC msdb.dbo.sp_update_job
        @job_name = N'SQLDB - AG SID Consistency Check',
        @notify_level_email = 2,
        @notify_email_operator_name = @OperatorName;

    PRINT 'Created/updated job: SQLDB - AG SID Consistency Check';
END TRY
BEGIN CATCH
    RAISERROR('AG SID job setup failed: %s', 16, 1, ERROR_MESSAGE());
    RETURN;
END CATCH;

/***************************************************************
  6) POST-INSTALL CHECKLIST
****************************************************************/
PRINT '=== Installer completed successfully ===';
PRINT 'Post-install actions:';
PRINT '1) Populate dbo.AGReplicaLinkedServers with replica <-> linked server mappings.';
PRINT '2) Validate linked servers with RPC OUT enabled.';
PRINT '3) Run jobs once manually and review output.';
PRINT '4) Confirm SQL Agent operator email delivery.';

SELECT
    j.name AS job_name,
    j.enabled,
    s.name AS schedule_name
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobschedules js
  ON j.job_id = js.job_id
LEFT JOIN msdb.dbo.sysschedules s
  ON js.schedule_id = s.schedule_id
WHERE j.name IN (N'SQLDB - AG Health Alert Job', N'SQLDB - AG SID Consistency Check')
ORDER BY j.name;
