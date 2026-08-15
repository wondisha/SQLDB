/*
Top resource-consuming queries from plan cache.
Requires: VIEW SERVER STATE
*/
SET NOCOUNT ON;

SELECT TOP (50)
    DB_NAME(COALESCE(CAST(pa.value AS INT), 0)) AS database_name,
    qs.execution_count,
    CAST(qs.total_worker_time / 1000.0 AS DECIMAL(18,2)) AS total_cpu_ms,
    CAST((qs.total_worker_time / NULLIF(qs.execution_count,0)) / 1000.0 AS DECIMAL(18,2)) AS avg_cpu_ms,
    CAST(qs.total_elapsed_time / 1000.0 AS DECIMAL(18,2)) AS total_elapsed_ms,
    CAST((qs.total_elapsed_time / NULLIF(qs.execution_count,0)) / 1000.0 AS DECIMAL(18,2)) AS avg_elapsed_ms,
    qs.total_logical_reads,
    qs.total_logical_writes,
    qs.last_execution_time,
    SUBSTRING(st.text,
        (qs.statement_start_offset/2)+1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END - qs.statement_start_offset)/2) + 1
    ) AS statement_text,
    st.text AS batch_text,
    qp.query_plan
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
OUTER APPLY sys.dm_exec_plan_attributes(qs.plan_handle) pa
WHERE pa.attribute = 'dbid'
ORDER BY qs.total_worker_time DESC;
