/*
Health-check dashboard query pack
Run each section independently or together.
*/

/* 1) Instance wait profile */
SELECT TOP (20)
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms,
    CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER(),0) AS DECIMAL(6,2)) AS pct_total_wait
FROM sys.dm_os_wait_stats
WHERE wait_type NOT LIKE 'SLEEP%'
ORDER BY wait_time_ms DESC;

/* 2) Active blockers */
SELECT
    r.session_id,
    r.blocking_session_id,
    r.status,
    r.wait_type,
    r.wait_time,
    r.cpu_time,
    r.total_elapsed_time,
    DB_NAME(r.database_id) AS database_name
FROM sys.dm_exec_requests r
WHERE r.blocking_session_id <> 0
   OR r.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0)
ORDER BY r.blocking_session_id DESC, r.session_id;

/* 3) Backup freshness */
SELECT
    d.name AS database_name,
    MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) AS last_full_backup,
    MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END) AS last_diff_backup,
    MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) AS last_log_backup
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset bs
    ON d.name = bs.database_name
GROUP BY d.name
ORDER BY d.name;

/* 4) Failed jobs in last 24 hours */
SELECT
    j.name AS job_name,
    h.step_name,
    msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_datetime,
    h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
WHERE h.run_status = 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(HOUR, -24, GETDATE())
ORDER BY run_datetime DESC;

/* 5) TempDB top sessions */
SELECT TOP (20)
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    CAST((su.user_objects_alloc_page_count + su.internal_objects_alloc_page_count) * 8.0 / 1024 AS DECIMAL(18,2)) AS allocated_mb
FROM sys.dm_db_session_space_usage su
JOIN sys.dm_exec_sessions s ON su.session_id = s.session_id
ORDER BY allocated_mb DESC;

/* 6) Long running transactions */
SELECT
    at.transaction_id,
    at.transaction_begin_time,
    DATEDIFF(MINUTE, at.transaction_begin_time, GETDATE()) AS open_minutes,
    st.session_id,
    es.login_name,
    es.program_name,
    er.status,
    er.command,
    er.blocking_session_id
FROM sys.dm_tran_active_transactions at
JOIN sys.dm_tran_session_transactions st ON at.transaction_id = st.transaction_id
LEFT JOIN sys.dm_exec_sessions es ON st.session_id = es.session_id
LEFT JOIN sys.dm_exec_requests er ON st.session_id = er.session_id
ORDER BY open_minutes DESC;
