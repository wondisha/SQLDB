/*
Missing index recommendations (review manually before implementing).
Requires: VIEW SERVER STATE
*/
SET NOCOUNT ON;

SELECT
    DB_NAME(mid.database_id) AS database_name,
    OBJECT_SCHEMA_NAME(mid.object_id, mid.database_id) AS schema_name,
    OBJECT_NAME(mid.object_id, mid.database_id) AS table_name,
    migs.user_seeks,
    migs.user_scans,
    CAST(migs.avg_total_user_cost AS DECIMAL(18,2)) AS avg_total_user_cost,
    CAST(migs.avg_user_impact AS DECIMAL(18,2)) AS avg_user_impact_pct,
    (migs.user_seeks + migs.user_scans) * migs.avg_total_user_cost * (migs.avg_user_impact/100.0) AS improvement_measure,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    'CREATE INDEX IX_' + REPLACE(OBJECT_NAME(mid.object_id, mid.database_id), ' ', '') +
    '_' + CAST(mid.index_handle AS VARCHAR(20)) +
    ' ON ' + mid.statement +
    ' (' + ISNULL(mid.equality_columns, '') +
    CASE WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL THEN ',' ELSE '' END +
    ISNULL(mid.inequality_columns, '') + ')' +
    ISNULL(' INCLUDE (' + mid.included_columns + ')', '') AS proposed_create_index_sql
FROM sys.dm_db_missing_index_group_stats AS migs
JOIN sys.dm_db_missing_index_groups AS mig
    ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details AS mid
    ON mig.index_handle = mid.index_handle
WHERE mid.database_id = DB_ID()
ORDER BY improvement_measure DESC;
