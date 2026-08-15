/*
Index maintenance stored procedure
- Logs recommendations and actions
- Supports preview mode (@Execute = 0)
- Threshold based REORGANIZE / REBUILD
*/

IF OBJECT_ID('dbo.IndexMaintenanceLog','U') IS NULL
BEGIN
    CREATE TABLE dbo.IndexMaintenanceLog
    (
        log_id BIGINT IDENTITY(1,1) PRIMARY KEY,
        run_id UNIQUEIDENTIFIER NOT NULL,
        logged_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
        schema_name SYSNAME NOT NULL,
        table_name SYSNAME NOT NULL,
        index_name SYSNAME NOT NULL,
        page_count BIGINT NOT NULL,
        fragmentation_percent DECIMAL(6,2) NOT NULL,
        action_taken NVARCHAR(20) NOT NULL,
        command_text NVARCHAR(MAX) NULL,
        success BIT NULL,
        error_message NVARCHAR(4000) NULL
    );
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_IndexMaintenance
    @MinPageCount INT = 128,
    @ReorgThreshold DECIMAL(5,2) = 10,
    @RebuildThreshold DECIMAL(5,2) = 30,
    @OnlineRebuild BIT = 0,
    @Execute BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @run_id UNIQUEIDENTIFIER = NEWID();

    IF OBJECT_ID('tempdb..#work') IS NOT NULL DROP TABLE #work;

    SELECT
        s.name AS schema_name,
        t.name AS table_name,
        i.name AS index_name,
        i.object_id,
        i.index_id,
        ips.page_count,
        CAST(ips.avg_fragmentation_in_percent AS DECIMAL(6,2)) AS fragmentation_percent
    INTO #work
    FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') ips
    JOIN sys.indexes i
      ON ips.object_id = i.object_id
     AND ips.index_id = i.index_id
    JOIN sys.tables t
      ON i.object_id = t.object_id
    JOIN sys.schemas s
      ON t.schema_id = s.schema_id
    WHERE i.index_id > 0
      AND ips.page_count >= @MinPageCount
      AND i.name IS NOT NULL;

    DECLARE
        @schema SYSNAME,
        @table SYSNAME,
        @index SYSNAME,
        @page_count BIGINT,
        @frag DECIMAL(6,2),
        @action NVARCHAR(20),
        @sql NVARCHAR(MAX);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT schema_name, table_name, index_name, page_count, fragmentation_percent
    FROM #work
    WHERE fragmentation_percent >= @ReorgThreshold
    ORDER BY fragmentation_percent DESC, page_count DESC;

    OPEN c;
    FETCH NEXT FROM c INTO @schema, @table, @index, @page_count, @frag;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @action = CASE
            WHEN @frag >= @RebuildThreshold THEN N'REBUILD'
            ELSE N'REORGANIZE'
        END;

        SET @sql = CASE
            WHEN @action = N'REBUILD' THEN
                N'ALTER INDEX [' + @index + N'] ON [' + @schema + N'].[' + @table + N'] REBUILD WITH (SORT_IN_TEMPDB = ON' +
                CASE WHEN @OnlineRebuild = 1 THEN N', ONLINE = ON' ELSE N'' END + N');'
            ELSE
                N'ALTER INDEX [' + @index + N'] ON [' + @schema + N'].[' + @table + N'] REORGANIZE;'
        END;

        BEGIN TRY
            IF @Execute = 1
                EXEC sp_executesql @sql;

            INSERT INTO dbo.IndexMaintenanceLog
            (
                run_id, schema_name, table_name, index_name, page_count,
                fragmentation_percent, action_taken, command_text, success, error_message
            )
            VALUES
            (
                @run_id, @schema, @table, @index, @page_count,
                @frag, @action, @sql, 1, NULL
            );
        END TRY
        BEGIN CATCH
            INSERT INTO dbo.IndexMaintenanceLog
            (
                run_id, schema_name, table_name, index_name, page_count,
                fragmentation_percent, action_taken, command_text, success, error_message
            )
            VALUES
            (
                @run_id, @schema, @table, @index, @page_count,
                @frag, @action, @sql, 0, ERROR_MESSAGE()
            );
        END CATCH;

        FETCH NEXT FROM c INTO @schema, @table, @index, @page_count, @frag;
    END

    CLOSE c;
    DEALLOCATE c;

    SELECT *
    FROM dbo.IndexMaintenanceLog
    WHERE run_id = @run_id
    ORDER BY log_id;
END
GO
