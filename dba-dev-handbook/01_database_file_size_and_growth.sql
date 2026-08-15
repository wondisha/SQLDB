/*
Database and file size overview.
*/
SET NOCOUNT ON;

SELECT
    DB_NAME(mf.database_id) AS database_name,
    mf.type_desc,
    mf.name AS logical_file_name,
    mf.physical_name,
    CAST(mf.size/128.0 AS DECIMAL(18,2)) AS size_mb,
    CASE mf.max_size
        WHEN -1 THEN -1
        ELSE CAST(mf.max_size/128.0 AS DECIMAL(18,2))
    END AS max_size_mb,
    CASE mf.is_percent_growth
        WHEN 1 THEN CAST(mf.growth AS VARCHAR(20)) + '%'
        ELSE CAST(mf.growth/128 AS VARCHAR(20)) + ' MB'
    END AS growth_setting
FROM sys.master_files mf
ORDER BY database_name, mf.type_desc;
