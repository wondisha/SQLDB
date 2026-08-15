/*
SQL Agent automation jobs setup
Creates jobs for:
1) Daily Health Check Snapshot
2) Weekly Index Maintenance
3) Daily Statistics Refresh (sampled)

Prerequisites:
- SQL Server Agent running
- msdb access
*/
USE msdb;
GO

-- 1) Daily Health Check Snapshot Job
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = 'SQLDB - Daily Health Check Snapshot')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name = N'SQLDB - Daily Health Check Snapshot',
        @enabled = 1,
        @description = N'Collects daily health-check snapshots for DBA review.';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name = N'SQLDB - Daily Health Check Snapshot',
        @step_name = N'Collect Health Snapshot',
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'
SET NOCOUNT ON;
SELECT GETDATE() AS captured_at, * FROM sys.dm_os_wait_stats;
SELECT GETDATE() AS captured_at, DB_NAME(database_id) AS database_name, state_desc, recovery_model_desc FROM sys.databases;
';

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'SQLDB - Daily - 01AM',
        @freq_type = 4,
        @freq_interval = 1,
        @active_start_time = 010000;

    EXEC msdb.dbo.sp_attach_schedule
        @job_name = N'SQLDB - Daily Health Check Snapshot',
        @schedule_name = N'SQLDB - Daily - 01AM';

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'SQLDB - Daily Health Check Snapshot';
END
GO

-- 2) Weekly Index Maintenance Job
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = 'SQLDB - Weekly Index Maintenance')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name = N'SQLDB - Weekly Index Maintenance',
        @enabled = 1,
        @description = N'Executes dbo.usp_IndexMaintenance with default thresholds.';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name = N'SQLDB - Weekly Index Maintenance',
        @step_name = N'Run Index Maintenance Procedure',
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'
-- Change [YourUserDatabase] before running
USE [YourUserDatabase];
EXEC dbo.usp_IndexMaintenance
    @MinPageCount = 128,
    @ReorgThreshold = 10,
    @RebuildThreshold = 30,
    @OnlineRebuild = 0,
    @Execute = 1;
';

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'SQLDB - Weekly - Sun 02AM',
        @freq_type = 8,
        @freq_interval = 1,
        @active_start_time = 020000;

    EXEC msdb.dbo.sp_attach_schedule
        @job_name = N'SQLDB - Weekly Index Maintenance',
        @schedule_name = N'SQLDB - Weekly - Sun 02AM';

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'SQLDB - Weekly Index Maintenance';
END
GO

-- 3) Daily Statistics Refresh Job
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = 'SQLDB - Daily Statistics Refresh')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name = N'SQLDB - Daily Statistics Refresh',
        @enabled = 1,
        @description = N'Updates statistics daily using sp_updatestats.';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name = N'SQLDB - Daily Statistics Refresh',
        @step_name = N'Run sp_updatestats',
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'
-- Change [YourUserDatabase] before running
USE [YourUserDatabase];
EXEC sp_updatestats;
';

    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'SQLDB - Daily - 03AM',
        @freq_type = 4,
        @freq_interval = 1,
        @active_start_time = 030000;

    EXEC msdb.dbo.sp_attach_schedule
        @job_name = N'SQLDB - Daily Statistics Refresh',
        @schedule_name = N'SQLDB - Daily - 03AM';

    EXEC msdb.dbo.sp_add_jobserver
        @job_name = N'SQLDB - Daily Statistics Refresh';
END
GO
