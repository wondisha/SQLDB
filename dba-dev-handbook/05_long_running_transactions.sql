/*
Long-running transactions and active requests.
Requires: VIEW SERVER STATE
*/
SET NOCOUNT ON;

SELECT
    at.transaction_id,
    at.name AS transaction_name,
    at.transaction_begin_time,
    DATEDIFF(MINUTE, at.transaction_begin_time, GETDATE()) AS open_minutes,
    st.session_id,
    es.login_name,
    es.host_name,
    es.program_name,
    er.status,
    er.command,
    er.wait_type,
    er.blocking_session_id,
    DB_NAME(er.database_id) AS database_name
FROM sys.dm_tran_active_transactions at
JOIN sys.dm_tran_session_transactions st
    ON at.transaction_id = st.transaction_id
LEFT JOIN sys.dm_exec_sessions es
    ON st.session_id = es.session_id
LEFT JOIN sys.dm_exec_requests er
    ON st.session_id = er.session_id
ORDER BY open_minutes DESC;
