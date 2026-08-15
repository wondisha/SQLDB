/*
Statistics health check and optional update script generator.
*/
SET NOCOUNT ON;

;WITH stats_info AS (
    SELECT
        s.object_id,
        OBJECT_SCHEMA_NAME(s.object_id) AS schema_name,
        OBJECT_NAME(s.object_id) AS table_name,
        s.name AS stats_name,
        sp.last_updated,
        sp.rows,
        sp.rows_sampled,
        sp.modification_counter
    FROM sys.stats s
    OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
    WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
)
SELECT
    schema_name,
    table_name,
    stats_name,
    last_updated,
    rows,
    rows_sampled,
    modification_counter,
    CASE
        WHEN rows IS NULL THEN 'Unknown'
        WHEN rows = 0 THEN 'NoRows'
        WHEN modification_counter > (rows * 0.2) THEN 'ConsiderUpdate'
        ELSE 'OK'
    END AS recommendation,
    'UPDATE STATISTICS [' + schema_name + '].[' + table_name + '] [' + stats_name + '] WITH FULLSCAN;' AS suggested_update_sql
FROM stats_info
ORDER BY modification_counter DESC, rows DESC;
