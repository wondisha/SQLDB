/*
Index fragmentation report.
Use before maintenance windows.
*/
SET NOCOUNT ON;

SELECT
    DB_NAME() AS database_name,
    s.name AS schema_name,
    t.name AS table_name,
    i.name AS index_name,
    i.index_id,
    ips.index_type_desc,
    ips.page_count,
    CAST(ips.avg_fragmentation_in_percent AS DECIMAL(6,2)) AS avg_fragmentation_in_percent
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') ips
JOIN sys.indexes i
    ON ips.object_id = i.object_id
   AND ips.index_id = i.index_id
JOIN sys.tables t
    ON i.object_id = t.object_id
JOIN sys.schemas s
    ON t.schema_id = s.schema_id
WHERE ips.page_count >= 128
  AND i.index_id > 0
ORDER BY ips.avg_fragmentation_in_percent DESC, ips.page_count DESC;
