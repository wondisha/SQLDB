/*
Ingestion Procedure: AG Health Snapshot
Target DB: Central monitoring database

Usage example from source instance (linked server to central):
EXEC [CentralLinkedServer].[DBA_Monitor].[dbo].[usp_AG_IngestHealthSnapshot]
    @SourceInstance = @@SERVERNAME,
    @CapturedAt = SYSUTCDATETIME(),
    @PayloadJson = N'[...]';

Payload JSON format: array of objects
[
  {
    "ag_name":"AG1",
    "replica_server_name":"SQLNODE1",
    "database_name":"MyDB",
    "role_desc":"PRIMARY",
    "connected_state_desc":"CONNECTED",
    "recovery_health_desc":"ONLINE",
    "synchronization_health_desc":"HEALTHY",
    "synchronization_state_desc":"SYNCHRONIZED",
    "is_primary_replica":1,
    "log_send_queue_kb":0,
    "redo_queue_kb":0,
    "details":"optional"
  }
]
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

CREATE OR ALTER PROCEDURE dbo.usp_AG_IngestHealthSnapshot
    @SourceInstance SYSNAME,
    @CapturedAt DATETIME2(0),
    @PayloadJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    IF @SourceInstance IS NULL OR LTRIM(RTRIM(@SourceInstance)) = ''
    BEGIN
        RAISERROR('SourceInstance is required.', 16, 1);
        RETURN;
    END;

    IF @CapturedAt IS NULL
        SET @CapturedAt = SYSUTCDATETIME();

    IF @PayloadJson IS NULL OR ISJSON(@PayloadJson) <> 1
    BEGIN
        RAISERROR('PayloadJson must be valid JSON.', 16, 1);
        RETURN;
    END;

    BEGIN TRY
        INSERT INTO dbo.AG_HealthSnapshot
        (
            captured_at,
            source_instance,
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
        )
        SELECT
            @CapturedAt,
            @SourceInstance,
            j.ag_name,
            j.replica_server_name,
            j.database_name,
            j.role_desc,
            j.connected_state_desc,
            j.recovery_health_desc,
            j.synchronization_health_desc,
            j.synchronization_state_desc,
            j.is_primary_replica,
            j.log_send_queue_kb,
            j.redo_queue_kb,
            j.details
        FROM OPENJSON(@PayloadJson)
        WITH
        (
            ag_name SYSNAME '$.ag_name',
            replica_server_name SYSNAME '$.replica_server_name',
            database_name SYSNAME '$.database_name',
            role_desc NVARCHAR(60) '$.role_desc',
            connected_state_desc NVARCHAR(60) '$.connected_state_desc',
            recovery_health_desc NVARCHAR(60) '$.recovery_health_desc',
            synchronization_health_desc NVARCHAR(60) '$.synchronization_health_desc',
            synchronization_state_desc NVARCHAR(60) '$.synchronization_state_desc',
            is_primary_replica BIT '$.is_primary_replica',
            log_send_queue_kb BIGINT '$.log_send_queue_kb',
            redo_queue_kb BIGINT '$.redo_queue_kb',
            details NVARCHAR(4000) '$.details'
        ) AS j
        WHERE j.ag_name IS NOT NULL
          AND j.replica_server_name IS NOT NULL;

        SELECT @@ROWCOUNT AS inserted_rows;
    END TRY
    BEGIN CATCH
        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('usp_AG_IngestHealthSnapshot failed: %s', 16, 1, @Err);
        RETURN;
    END CATCH;
END
GO
