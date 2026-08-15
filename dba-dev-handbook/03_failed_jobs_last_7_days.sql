/*
Failed SQL Agent jobs (last 7 days).
Requires SQL Server Agent and access to msdb.
*/
SET NOCOUNT ON;

SELECT
    j.name AS job_name,
    h.step_id,
    h.step_name,
    msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_datetime,
    h.run_duration,
    h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j
    ON h.job_id = j.job_id
WHERE h.run_status = 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(DAY, -7, GETDATE())
ORDER BY run_datetime DESC;
