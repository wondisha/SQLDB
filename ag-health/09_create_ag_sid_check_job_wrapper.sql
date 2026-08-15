/*
SQL Agent Job Wrapper: AG SID Consistency Check (Report Only)

Purpose:
- Schedules and runs SID consistency validation across AG replicas.
- Does NOT execute auto-repair.
- Fails job when mismatches/missing logins are detected (for operator alerting).

Prerequisites:
- Script ag-health/07_ag_sid_consistency_check.sql is available and tested.
- Linked servers to secondary replicas are configured and RPC OUT enabled.
- SQL Agent Operator exists (or will be created by this script).

IMPORTANT:
- Update the @ReplicaServers population section in the embedded check query.
- Replace operator email/name placeholders.
*/

USE msdb;
GO

DECLARE @OperatorName SYSNAME = N'DBA_Operator';
DECLARE @OperatorEmail NVARCHAR(256) = N'dba-team@example.com';

-- Ensure operator exists
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
BEGIN
    EXEC msdb.dbo.sp_add_operator
        @name = @OperatorName,
        @enabled = 1,
        @email_address = @OperatorEmail;
END
GO

-- Recreate job idempotently
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLDB - AG SID Consistency Check')
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = N'SQLDB - AG SID Consistency Check',
        @delete_unused_schedule = 0;
END
GO

EXEC msdb.dbo.sp_add_job
    @job_name = N'SQLDB - AG SID Consistency Check',
    @enabled = 1,
    @description = N'Runs AG SID consistency check (report-only) and fails when mismatches are detected.';
GO

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

/*
TODO: Update with your environment
INSERT INTO @ReplicaServers(replica_server_name, linked_server_name, is_primary)
VALUES
(N''''SQLNODE1'''', N''''SQLNODE1_LS'''', 1),
(N''''SQLNODE2'''', N''''SQLNODE2_LS'''', 0);
*/

IF NOT EXISTS (SELECT 1 FROM @ReplicaServers WHERE is_primary = 1)
BEGIN
    RAISERROR(''Populate @ReplicaServers with at least one primary and one secondary mapping.'', 16, 1);
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

DECLARE replica_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT replica_server_name, linked_server_name
FROM @ReplicaServers
WHERE is_primary = 0;

OPEN replica_cursor;
FETCH NEXT FROM replica_cursor INTO @Replica, @Linked;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N''
    INSERT INTO #secondary_logins(replica_server_name, login_name, type, sid)
    SELECT
        N'''''' + REPLACE(@Replica,'''''','''''''') + N'''''' ,
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

    FETCH NEXT FROM replica_cursor INTO @Replica, @Linked;
END

CLOSE replica_cursor;
DEALLOCATE replica_cursor;

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
    CONVERT(VARCHAR(200), p.sid, 1) AS primary_sid_hex,
    CONVERT(VARCHAR(200), s.sid, 1) AS secondary_sid_hex
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
END
';
GO

-- Create schedule if missing (every 30 minutes)
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'SQLDB - Every 30 Min')
BEGIN
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'SQLDB - Every 30 Min',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 4,
        @freq_subday_interval = 30,
        @active_start_time = 000000;
END
GO

EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'SQLDB - AG SID Consistency Check',
    @schedule_name = N'SQLDB - Every 30 Min';
GO

EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'SQLDB - AG SID Consistency Check';
GO

EXEC msdb.dbo.sp_update_job
    @job_name = N'SQLDB - AG SID Consistency Check',
    @notify_level_email = 2,
    @notify_email_operator_name = N'DBA_Operator';
GO
