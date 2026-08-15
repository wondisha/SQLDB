/*
Recent AG-related errors from system_health Extended Events.
Searches error_reported events for common AG/HADR keywords.
*/
SET NOCOUNT ON;

;WITH xe AS (
    SELECT
        CAST(event_data AS XML) AS event_xml
    FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL)
    WHERE object_name = 'error_reported'
), parsed AS (
    SELECT
        DATEADD(HOUR, DATEDIFF(HOUR, GETUTCDATE(), GETDATE()),
            CAST(event_xml.value('(event/@timestamp)[1]', 'datetime2') AS datetime2)
        ) AS local_event_time,
        event_xml.value('(event/data[@name="error_number"]/value)[1]', 'int') AS error_number,
        event_xml.value('(event/data[@name="severity"]/value)[1]', 'int') AS severity,
        event_xml.value('(event/data[@name="message"]/value)[1]', 'nvarchar(4000)') AS message_text
    FROM xe
)
SELECT TOP (200)
    local_event_time,
    error_number,
    severity,
    message_text
FROM parsed
WHERE message_text LIKE '%availability group%'
   OR message_text LIKE '%hadr%'
   OR message_text LIKE '%replica%'
   OR message_text LIKE '%synchroniz%'
ORDER BY local_event_time DESC;
