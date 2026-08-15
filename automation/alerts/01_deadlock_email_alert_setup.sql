/*
Deadlock email alert setup via SQL Server Agent Alerts + Database Mail

Prerequisites:
- Database Mail configured
- SQL Agent Operator created
- Replace placeholders before execution:
  1) [DBA_Operator]
  2) [DBA_Profile] (optional depending on your mail setup)

Alert 1205 = deadlock victim error
*/
USE msdb;
GO

-- Ensure operator exists (create if needed)
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'DBA_Operator')
BEGIN
    EXEC msdb.dbo.sp_add_operator
        @name = N'DBA_Operator',
        @enabled = 1,
        @email_address = N'dba-team@example.com';
END
GO

-- Create alert for deadlock victim (error 1205)
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = N'SQLDB - Deadlock Alert 1205')
BEGIN
    EXEC msdb.dbo.sp_add_alert
        @name = N'SQLDB - Deadlock Alert 1205',
        @message_id = 1205,
        @severity = 0,
        @enabled = 1,
        @delay_between_responses = 60,
        @include_event_description_in = 1,
        @notification_message = N'Deadlock detected (error 1205). Review deadlock graph query scripts in monitoring/blocking-deadlocks.';

    EXEC msdb.dbo.sp_add_notification
        @alert_name = N'SQLDB - Deadlock Alert 1205',
        @operator_name = N'DBA_Operator',
        @notification_method = 1; -- email
END
GO
