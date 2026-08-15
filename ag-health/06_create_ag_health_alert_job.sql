/*
AG Alert Job Setup
Creates SQL Agent job to monitor Always On AG health and notify operator on failure.

What it checks:
1) Replica connectivity/health status
2) Database synchronization health
3) Log send queue threshold (KB)
4) Redo queue threshold (KB)

Behavior:
- If any violations found, step raises error and job fails.
- SQL Agent notification emails DBA operator when job fails.

Placeholders to update before running:
- @OperatorName
- @OperatorEmail
- @LogSendQueueThresholdKB
- @RedoQueueThresholdKB
*/

USE msdb;
GO

DECLARE @OperatorName SYSNAME = N'DBA_Operator';
DECLARE @OperatorEmail NVARCHAR(256) = N'dba-team@example.com';
DECLARE @JobName SYSNAME = N'SQLDB - AG Health Alert Job';
DECLARE @ScheduleName SYSNAME = N'SQLDB - Every 5 Min';

-- Ensure operator exists
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
BEGIN
    EXEC msdb.dbo.sp_add_operator
        @name = @OperatorName,
        @enabled = 1,
        @email_address = @OperatorEmail;
END
GO

-- Recreate job to keep script idempotent
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLDB - AG Health Alert Job')
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = N'SQLDB - AG Health Alert Job', @delete_unused_schedule = 0;
END
GO

EXEC msdb.dbo.sp_add_job
    @job_name = N'SQLDB - AG Health Alert Job',
    @enabled = 1,
    @description = N'Monitors AG health and fails when thresholds or health conditions are violated.';
GO

EXEC msdb.dbo.sp_add_jobstep
    @job_name = N'SQLDB - AG Health Alert Job',
    @step_name = N'Check AG Health',
    @subsystem = N'TSQL',
    @database_name = N'master',
    @command = N'
SET NOCOUNT ON;

DECLARE @LogSendQueueThresholdKB BIGINT = 102400; -- 100 MB
DECLARE @RedoQueueThresholdKB BIGINT = 102400;    -- 100 MB

IF OBJECT_ID(''tempdb..#issues'') IS NOT NULL DROP TABLE #issues;
CREATE TABLE #issues
(
    issue_type NVARCHAR(100),
    ag_name SYSNAME NULL,
    replica_server_name SYSNAME NULL,
    database_name SYSNAME NULL,
    details NVARCHAR(4000)
);

-- 1) Replica-level issues
INSERT INTO #issues(issue_type, ag_name, replica_server_name, database_name, details)
SELECT
    N''REPLICA_HEALTH'',
    ag.name,
    ar.replica_server_name,
    NULL,
    CONCAT(N''role='', ISNULL(ars.role_desc,N''UNKNOWN''),
           N''; connected='', ISNULL(ars.connected_state_desc,N''UNKNOWN''),
           N''; recovery='', ISNULL(ars.recovery_health_desc,N''UNKNOWN''),
           N''; sync_health='', ISNULL(ars.synchronization_health_desc,N''UNKNOWN''))
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar
  ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars
  ON ar.replica_id = ars.replica_id
WHERE ars.connected_state_desc <> ''CONNECTED''
   OR ars.recovery_health_desc <> ''ONLINE''
   OR ars.synchronization_health_desc NOT IN (''HEALTHY'',''PARTIALLY_HEALTHY'');

-- 2) Database-level sync issues
INSERT INTO #issues(issue_type, ag_name, replica_server_name, database_name, details)
SELECT
    N''DB_SYNC_HEALTH'',
    ag.name,
    ar.replica_server_name,
    DB_NAME(drs.database_id),
    CONCAT(N''sync_state='', drs.synchronization_state_desc,
           N''; sync_health='', drs.synchronization_health_desc,
           N''; is_primary='', drs.is_primary_replica)
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar
  ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag
  ON ar.group_id = ag.group_id
WHERE drs.synchronization_health_desc <> ''HEALTHY''
   OR (drs.is_primary_replica = 0 AND drs.synchronization_state_desc <> ''SYNCHRONIZED'');

-- 3) Queue threshold issues
INSERT INTO #issues(issue_type, ag_name, replica_server_name, database_name, details)
SELECT
    N''QUEUE_THRESHOLD'',
    ag.name,
    ar.replica_server_name,
    DB_NAME(drs.database_id),
    CONCAT(N''log_send_queue_kb='', drs.log_send_queue_size,
           N''; redo_queue_kb='', drs.redo_queue_size,
           N''; threshold_kb='', @LogSendQueueThresholdKB)
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar
  ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag
  ON ar.group_id = ag.group_id
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
END
';
GO

-- Create or reuse schedule
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'SQLDB - Every 5 Min')
BEGIN
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'SQLDB - Every 5 Min',
        @enabled = 1,
        @freq_type = 4,             -- daily
        @freq_interval = 1,         -- every day
        @freq_subday_type = 4,      -- minutes
        @freq_subday_interval = 5,  -- every 5 minutes
        @active_start_time = 000000;
END
GO

EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'SQLDB - AG Health Alert Job',
    @schedule_name = N'SQLDB - Every 5 Min';
GO

EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'SQLDB - AG Health Alert Job';
GO

-- Enable notification on job failure
EXEC msdb.dbo.sp_update_job
    @job_name = N'SQLDB - AG Health Alert Job',
    @notify_level_email = 2, -- on failure
    @notify_email_operator_name = N'DBA_Operator';
GO
