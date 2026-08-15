/*
Enable system_health-based deadlock extraction query.
Reads deadlock graphs captured by Extended Events (default system_health session).
*/
SET NOCOUNT ON;

;WITH DeadlockData AS (
    SELECT
        CAST(event_data AS XML) AS event_xml,
        DATEADD(HOUR, DATEDIFF(HOUR, GETUTCDATE(), GETDATE()),
            CAST(CAST(event_data AS XML).value('(event/@timestamp)[1]', 'datetime2') AS datetime2)
        ) AS local_event_time
    FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL)
    WHERE object_name = 'xml_deadlock_report'
)
SELECT
    local_event_time,
    event_xml AS deadlock_graph_xml
FROM DeadlockData
ORDER BY local_event_time DESC;
