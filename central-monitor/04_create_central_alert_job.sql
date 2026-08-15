/*
Create central alert evaluator job
Target DB: Central monitoring database host instance

Job:
- SQLDB - Central AG Alert Evaluator

Behavior:
- Checks recent AG_HealthSnapshot rows (last N minutes)
- Inserts alert rows into dbo.AG_AlertEvent for unhealthy conditions
- Fails job if critical alerts are found so SQL Agent can notify operator
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @OperatorName SYSNAME = N'DBA_Operator';
DECLARE @OperatorEmail NVARCHAR(256) = N'dba-team@example.com';
DECLARE @ScheduleName SYSNAME = N'SQLDB - Central AG Evaluator Every 5 Min';
DECLARE @LookbackMinutes INT = 10;
DECLARE @LogSendQueueThresholdKB BIGINT = 102400;
DECLARE @RedoQueueThresholdKB BIGINT = 102400;

BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
    BEGIN
        EXEC msdb.dbo.sp_add_operator
            @name = @OperatorName,
            @enabled = 1,
            @email_address = @OperatorEmail;
    END
    ELSE
    BEGIN
        EXEC msdb.dbo.sp_update_operator
            @name = @OperatorName,
            @enabled = 1,
            @email_address = @OperatorEmail;
    END;

    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLDB - Central AG Alert Evaluator')
    BEGIN
        EXEC msdb.dbo.sp_delete_job
            @job_name = N'SQLDB - Central AG Alert Evaluator',
            @delete_unused_schedule = 0;
    END;

    EXEC msdb.dbo.sp_add_job
        @job_name = N'SQLDB - Central AG Alert Evaluator',
        @enabled = 1,
        @description = N'Evaluates centralized AG snapshots and raises alerts for unhealthy conditions.';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name = N'SQLDB - Central AG Alert Evaluator',
        @step_name = N'Evaluate AG snapshots',
        @subsystem = N'TSQL',
        @database_name = DB_NAME(),
        @command = N'
SET NOCOUNT ON;
DECLARE @LookbackMinutes INT = ' + CAST(@LookbackMinutes AS NVARCHAR(20)) + N';
DECLARE @LogSendQueueThresholdKB BIGINT = ' + CAST(@LogSendQueueThresholdKB AS NVARCHAR(30)) + N';
DECLARE @RedoQueueThresholdKB BIGINT = ' + CAST(@RedoQueueThresholdKB AS NVARCHAR(30)) + N';

;WITH recent AS
(
    SELECT *
    FROM dbo.AG_HealthSnapshot
    WHERE captured_at >= DATEADD(MINUTE, -@LookbackMinutes, SYSUTCDATETIME())
)
INSERT INTO dbo.AG_AlertEvent
(
    source_instance,
    alert_type,
    severity,
    ag_name,
    replica_server_name,
    database_name,
    status,
    details
)
SELECT
    r.source_instance,
    N''AG_HEALTH'',
    2,
    r.ag_name,
    r.replica_server_name,
    r.database_name,
    COALESCE(r.synchronization_health_desc, r.recovery_health_desc, r.connected_state_desc),
    CONCAT(N''role='', COALESCE(r.role_desc,N''?''),
           N''; connected='', COALESCE(r.connected_state_desc,N''?''),
           N''; recovery='', COALESCE(r.recovery_health_desc,N''?''),
           N''; sync='', COALESCE(r.synchronization_health_desc,N''?''),
           N''; sendQ='', COALESCE(CONVERT(NVARCHAR(30), r.log_send_queue_kb),N''NULL''),
           N''; redoQ='', COALESCE(CONVERT(NVARCHAR(30), r.redo_queue_kb),N''NULL''))
FROM recent r
WHERE r.connected_state_desc <> ''CONNECTED''
   OR r.recovery_health_desc <> ''ONLINE''
   OR r.synchronization_health_desc NOT IN (''HEALTHY'',''PARTIALLY_HEALTHY'')
   OR COALESCE(r.log_send_queue_kb,0) > @LogSendQueueThresholdKB
   OR COALESCE(r.redo_queue_kb,0) > @RedoQueueThresholdKB;

IF EXISTS
(
    SELECT 1
    FROM dbo.AG_AlertEvent
    WHERE event_time >= DATEADD(MINUTE, -@LookbackMinutes, SYSUTCDATETIME())
      AND alert_type = N''AG_HEALTH''
      AND severity >= 2
)
BEGIN
    RAISERROR(''Central AG evaluator detected critical AG health alerts.'', 16, 1);
END
ELSE
BEGIN
    PRINT ''Central AG evaluator: no critical alerts in lookback window.'';
END';

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
        @job_name = N'SQLDB - Central AG Alert Evaluator',
        @schedule_name = @ScheduleName;

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'SQLDB - Central AG Alert Evaluator';

    EXEC msdb.dbo.sp_update_job
        @job_name = N'SQLDB - Central AG Alert Evaluator',
        @notify_level_email = 2,
        @notify_email_operator_name = @OperatorName;

    PRINT 'Central alert evaluator job created/updated.';
END TRY
BEGIN CATCH
    DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR('Central alert job creation failed: %s', 16, 1, @Err);
END CATCH;
