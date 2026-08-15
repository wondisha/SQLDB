/*
Ingestion Procedure: AG SID Consistency Snapshot
Target DB: Central monitoring database

Usage example from source instance (linked server to central):
EXEC [CentralLinkedServer].[DBA_Monitor].[dbo].[usp_AG_IngestSIDSnapshot]
    @SourceInstance = @@SERVERNAME,
    @CapturedAt = SYSUTCDATETIME(),
    @PayloadJson = N'[...]';

Payload JSON format: array of objects
[
  {
    "replica_server_name":"SQLNODE2",
    "login_name":"app_login",
    "principal_type":"S",
    "status":"SID_MISMATCH",
    "primary_sid_hex":"0x...",
    "secondary_sid_hex":"0x...",
    "details":"optional"
  }
]
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

CREATE OR ALTER PROCEDURE dbo.usp_AG_IngestSIDSnapshot
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
        INSERT INTO dbo.AG_SIDConsistencySnapshot
        (
            captured_at,
            source_instance,
            replica_server_name,
            login_name,
            principal_type,
            status,
            primary_sid_hex,
            secondary_sid_hex,
            details
        )
        SELECT
            @CapturedAt,
            @SourceInstance,
            j.replica_server_name,
            j.login_name,
            j.principal_type,
            j.status,
            j.primary_sid_hex,
            j.secondary_sid_hex,
            j.details
        FROM OPENJSON(@PayloadJson)
        WITH
        (
            replica_server_name SYSNAME '$.replica_server_name',
            login_name SYSNAME '$.login_name',
            principal_type CHAR(1) '$.principal_type',
            status NVARCHAR(50) '$.status',
            primary_sid_hex VARCHAR(200) '$.primary_sid_hex',
            secondary_sid_hex VARCHAR(200) '$.secondary_sid_hex',
            details NVARCHAR(4000) '$.details'
        ) AS j
        WHERE j.replica_server_name IS NOT NULL
          AND j.login_name IS NOT NULL
          AND j.status IS NOT NULL;

        SELECT @@ROWCOUNT AS inserted_rows;
    END TRY
    BEGIN CATCH
        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('usp_AG_IngestSIDSnapshot failed: %s', 16, 1, @Err);
        RETURN;
    END CATCH;
END
GO
