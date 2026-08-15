/*
Index maintenance generator:
- REORGANIZE when fragmentation between 10 and 30
- REBUILD when fragmentation > 30
Skips small indexes (<128 pages)
Review generated commands before execution.
*/
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#frag') IS NOT NULL DROP TABLE #frag;

SELECT
    s.name AS schema_name,
    t.name AS table_name,
    i.name AS index_name,
    i.object_id,
    i.index_id,
    ips.page_count,
    ips.avg_fragmentation_in_percent
INTO #frag
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') ips
JOIN sys.indexes i
    ON ips.object_id = i.object_id
   AND ips.index_id = i.index_id
JOIN sys.tables t
    ON i.object_id = t.object_id
JOIN sys.schemas s
    ON t.schema_id = s.schema_id
WHERE i.index_id > 0
  AND ips.page_count >= 128;

SELECT
    schema_name,
    table_name,
    index_name,
    page_count,
    CAST(avg_fragmentation_in_percent AS DECIMAL(6,2)) AS frag_pct,
    CASE
        WHEN avg_fragmentation_in_percent BETWEEN 10 AND 30 THEN
            'ALTER INDEX [' + index_name + '] ON [' + schema_name + '].[' + table_name + '] REORGANIZE;'
        WHEN avg_fragmentation_in_percent > 30 THEN
            'ALTER INDEX [' + index_name + '] ON [' + schema_name + '].[' + table_name + '] REBUILD WITH (SORT_IN_TEMPDB = ON);'
        ELSE NULL
    END AS maintenance_sql
FROM #frag
WHERE avg_fragmentation_in_percent >= 10
ORDER BY avg_fragmentation_in_percent DESC, page_count DESC;
