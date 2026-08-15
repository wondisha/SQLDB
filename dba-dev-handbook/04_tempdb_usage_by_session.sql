/*
TempDB usage by session.
Useful for troubleshooting TempDB pressure.
Requires: VIEW SERVER STATE
*/
SET NOCOUNT ON;

SELECT
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    CAST((su.user_objects_alloc_page_count + su.internal_objects_alloc_page_count) * 8.0 / 1024 AS DECIMAL(18,2)) AS allocated_mb,
    CAST((su.user_objects_dealloc_page_count + su.internal_objects_dealloc_page_count) * 8.0 / 1024 AS DECIMAL(18,2)) AS deallocated_mb
FROM sys.dm_db_session_space_usage su
JOIN sys.dm_exec_sessions s
    ON su.session_id = s.session_id
ORDER BY allocated_mb DESC;
