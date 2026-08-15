/*
Central AG Monitoring Schema
Target DB: Central monitoring database (e.g., DBA_Monitor)

Creates:
- dbo.AG_InstanceRegistry
- dbo.AG_HealthSnapshot
- dbo.AG_SIDConsistencySnapshot
- dbo.AG_AlertEvent
- Helpful indexes
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

PRINT '=== Creating central AG monitoring schema ===';

BEGIN TRY
    IF OBJECT_ID('dbo.AG_InstanceRegistry','U') IS NULL
    BEGIN
        CREATE TABLE dbo.AG_InstanceRegistry
        (
            instance_id INT IDENTITY(1,1) PRIMARY KEY,
            instance_name SYSNAME NOT NULL UNIQUE,
            environment_name NVARCHAR(64) NULL,
            is_enabled BIT NOT NULL DEFAULT(1),
            created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
            updated_at DATETIME2(0) NULL
        );
        PRINT 'Created dbo.AG_InstanceRegistry';
    END
    ELSE
        PRINT 'dbo.AG_InstanceRegistry already exists';

    IF OBJECT_ID('dbo.AG_HealthSnapshot','U') IS NULL
    BEGIN
        CREATE TABLE dbo.AG_HealthSnapshot
        (
            snapshot_id BIGINT IDENTITY(1,1) PRIMARY KEY,
            captured_at DATETIME2(0) NOT NULL,
            source_instance SYSNAME NOT NULL,
            ag_name SYSNAME NOT NULL,
            replica_server_name SYSNAME NOT NULL,
            database_name SYSNAME NULL,
            role_desc NVARCHAR(60) NULL,
            connected_state_desc NVARCHAR(60) NULL,
            recovery_health_desc NVARCHAR(60) NULL,
            synchronization_health_desc NVARCHAR(60) NULL,
            synchronization_state_desc NVARCHAR(60) NULL,
            is_primary_replica BIT NULL,
            log_send_queue_kb BIGINT NULL,
            redo_queue_kb BIGINT NULL,
            details NVARCHAR(4000) NULL,
            created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
        );
        PRINT 'Created dbo.AG_HealthSnapshot';
    END
    ELSE
        PRINT 'dbo.AG_HealthSnapshot already exists';

    IF OBJECT_ID('dbo.AG_SIDConsistencySnapshot','U') IS NULL
    BEGIN
        CREATE TABLE dbo.AG_SIDConsistencySnapshot
        (
            sid_snapshot_id BIGINT IDENTITY(1,1) PRIMARY KEY,
            captured_at DATETIME2(0) NOT NULL,
            source_instance SYSNAME NOT NULL,
            replica_server_name SYSNAME NOT NULL,
            login_name SYSNAME NOT NULL,
            principal_type CHAR(1) NOT NULL,
            status NVARCHAR(50) NOT NULL,
            primary_sid_hex VARCHAR(200) NULL,
            secondary_sid_hex VARCHAR(200) NULL,
            details NVARCHAR(4000) NULL,
            created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
        );
        PRINT 'Created dbo.AG_SIDConsistencySnapshot';
    END
    ELSE
        PRINT 'dbo.AG_SIDConsistencySnapshot already exists';

    IF OBJECT_ID('dbo.AG_AlertEvent','U') IS NULL
    BEGIN
        CREATE TABLE dbo.AG_AlertEvent
        (
            alert_event_id BIGINT IDENTITY(1,1) PRIMARY KEY,
            event_time DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
            source_instance SYSNAME NOT NULL,
            alert_type NVARCHAR(100) NOT NULL,
            severity TINYINT NOT NULL,
            ag_name SYSNAME NULL,
            replica_server_name SYSNAME NULL,
            database_name SYSNAME NULL,
            status NVARCHAR(50) NULL,
            details NVARCHAR(4000) NULL,
            is_acknowledged BIT NOT NULL DEFAULT(0),
            acknowledged_by SYSNAME NULL,
            acknowledged_at DATETIME2(0) NULL
        );
        PRINT 'Created dbo.AG_AlertEvent';
    END
    ELSE
        PRINT 'dbo.AG_AlertEvent already exists';

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AG_HealthSnapshot_captured_at' AND object_id = OBJECT_ID('dbo.AG_HealthSnapshot'))
        CREATE INDEX IX_AG_HealthSnapshot_captured_at ON dbo.AG_HealthSnapshot(captured_at DESC);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AG_HealthSnapshot_source_ag' AND object_id = OBJECT_ID('dbo.AG_HealthSnapshot'))
        CREATE INDEX IX_AG_HealthSnapshot_source_ag ON dbo.AG_HealthSnapshot(source_instance, ag_name, captured_at DESC);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AG_SIDConsistencySnapshot_captured_at' AND object_id = OBJECT_ID('dbo.AG_SIDConsistencySnapshot'))
        CREATE INDEX IX_AG_SIDConsistencySnapshot_captured_at ON dbo.AG_SIDConsistencySnapshot(captured_at DESC);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AG_AlertEvent_event_time' AND object_id = OBJECT_ID('dbo.AG_AlertEvent'))
        CREATE INDEX IX_AG_AlertEvent_event_time ON dbo.AG_AlertEvent(event_time DESC);

    PRINT 'Indexes ensured.';
    PRINT '=== Central AG monitoring schema complete ===';
END TRY
BEGIN CATCH
    DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
    RAISERROR('Central schema creation failed: %s', 16, 1, @Err);
END CATCH;
