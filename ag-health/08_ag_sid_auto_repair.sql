/*
AG SID Auto-Repair (AD groups/users + SQL logins)

Capabilities:
- Detect missing or SID-mismatched logins on secondary replicas
- Auto-repair Windows logins/groups (U/G):
    DROP/CREATE login to align SID (Windows SIDs are AD-driven)
- Auto-repair SQL logins (S):
    Generates CREATE LOGIN ... SID + password hash script from primary
- Optional database user remap across user databases

IMPORTANT:
- Default is PREVIEW mode (@Execute = 0).
- Requires linked servers to each secondary replica with RPC OUT enabled.
- Run with sysadmin privileges.
- Test in non-production first.
*/
SET NOCOUNT ON;

DECLARE @Execute BIT = 0;                     -- 0 = preview only, 1 = execute
DECLARE @RepairWindowsPrincipals BIT = 1;     -- AD users/groups
DECLARE @RepairSqlLogins BIT = 1;             -- SQL logins
DECLARE @RemapDatabaseUsers BIT = 1;          -- ALTER USER ... WITH LOGIN ...

-- Map AG replica server name to linked server name
DECLARE @ReplicaServers TABLE
(
    replica_server_name SYSNAME NOT NULL,
    linked_server_name SYSNAME NOT NULL,
    is_primary BIT NOT NULL
);

/*
TODO: Update with your environment.
INSERT INTO @ReplicaServers(replica_server_name, linked_server_name, is_primary)
VALUES
(N'SQLNODE1', N'SQLNODE1_LS', 1),
(N'SQLNODE2', N'SQLNODE2_LS', 0);
*/

IF NOT EXISTS (SELECT 1 FROM @ReplicaServers WHERE is_primary = 1)
BEGIN
    RAISERROR('Populate @ReplicaServers with at least one primary and one secondary mapping.', 16, 1);
    RETURN;
END;

IF OBJECT_ID('dbo.AGSidRepairLog','U') IS NULL
BEGIN
    CREATE TABLE dbo.AGSidRepairLog
    (
        log_id BIGINT IDENTITY(1,1) PRIMARY KEY,
        run_id UNIQUEIDENTIFIER NOT NULL,
        logged_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
        replica_server_name SYSNAME NOT NULL,
        login_name SYSNAME NOT NULL,
        principal_type CHAR(1) NOT NULL,
        action_type NVARCHAR(50) NOT NULL,
        command_text NVARCHAR(MAX) NULL,
        success BIT NULL,
        error_message NVARCHAR(4000) NULL
    );
END;

DECLARE @run_id UNIQUEIDENTIFIER = NEWID();

IF OBJECT_ID('tempdb..#primary_logins') IS NOT NULL DROP TABLE #primary_logins;
CREATE TABLE #primary_logins
(
    login_name SYSNAME NOT NULL,
    type CHAR(1) NOT NULL,
    sid VARBINARY(85) NOT NULL,
    is_disabled BIT NULL,
    default_database_name SYSNAME NULL,
    password_hash VARBINARY(MAX) NULL,
    check_policy BIT NULL,
    check_expiration BIT NULL
);

INSERT INTO #primary_logins(login_name, type, sid, is_disabled, default_database_name, password_hash, check_policy, check_expiration)
SELECT
    sp.name,
    sp.type,
    sp.sid,
    sl.is_disabled,
    sl.default_database_name,
    sl.password_hash,
    sl.is_policy_checked,
    sl.is_expiration_checked
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl
    ON sp.principal_id = sl.principal_id
WHERE sp.type IN ('S','U','G')
  AND sp.name NOT LIKE '##%'
  AND sp.name NOT LIKE 'NT AUTHORITY\%'
  AND sp.name NOT LIKE 'NT SERVICE\%'
  AND sp.name <> 'sa';

IF OBJECT_ID('tempdb..#secondary_logins') IS NOT NULL DROP TABLE #secondary_logins;
CREATE TABLE #secondary_logins
(
    replica_server_name SYSNAME NOT NULL,
    login_name SYSNAME NOT NULL,
    type CHAR(1) NOT NULL,
    sid VARBINARY(85) NULL,
    is_disabled BIT NULL,
    default_database_name SYSNAME NULL
);

DECLARE @Replica SYSNAME, @Linked SYSNAME, @sql NVARCHAR(MAX);

DECLARE replica_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT replica_server_name, linked_server_name
FROM @ReplicaServers
WHERE is_primary = 0;

OPEN replica_cursor;
FETCH NEXT FROM replica_cursor INTO @Replica, @Linked;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
    INSERT INTO #secondary_logins(replica_server_name, login_name, type, sid, is_disabled, default_database_name)
    SELECT
        N''' + REPLACE(@Replica,'''','''''') + N''',
        CAST(R.sp_name AS SYSNAME),
        CAST(R.sp_type AS CHAR(1)),
        CAST(R.sp_sid AS VARBINARY(85)),
        CAST(R.is_disabled AS BIT),
        CAST(R.default_database_name AS SYSNAME)
    FROM OPENQUERY(' + QUOTENAME(@Linked) + N',
        ''SELECT sp.name AS sp_name, sp.type AS sp_type, sp.sid AS sp_sid, sl.is_disabled, sl.default_database_name
          FROM master.sys.server_principals sp
          LEFT JOIN master.sys.sql_logins sl ON sp.principal_id = sl.principal_id
          WHERE sp.type IN (''''S'''',''''U'''',''''G'''')
            AND sp.name NOT LIKE ''''##%''''
            AND sp.name NOT LIKE ''''NT AUTHORITY\\%''''
            AND sp.name NOT LIKE ''''NT SERVICE\\%''''
            AND sp.name <> ''''sa'''' '') AS R;
    ';

    BEGIN TRY
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        PRINT 'Failed to query linked server ' + @Linked + ': ' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM replica_cursor INTO @Replica, @Linked;
END

CLOSE replica_cursor;
DEALLOCATE replica_cursor;

IF OBJECT_ID('tempdb..#issues') IS NOT NULL DROP TABLE #issues;
CREATE TABLE #issues
(
    replica_server_name SYSNAME NOT NULL,
    login_name SYSNAME NOT NULL,
    principal_type CHAR(1) NOT NULL,
    status NVARCHAR(50) NOT NULL,
    primary_sid VARBINARY(85) NOT NULL,
    secondary_sid VARBINARY(85) NULL,
    default_database_name SYSNAME NULL,
    is_disabled BIT NULL,
    password_hash VARBINARY(MAX) NULL,
    check_policy BIT NULL,
    check_expiration BIT NULL
);

INSERT INTO #issues
(
    replica_server_name, login_name, principal_type, status,
    primary_sid, secondary_sid, default_database_name, is_disabled,
    password_hash, check_policy, check_expiration
)
SELECT
    s.replica_server_name,
    p.login_name,
    p.type,
    CASE
        WHEN s.login_name IS NULL THEN 'MISSING_ON_SECONDARY'
        WHEN s.sid IS NULL THEN 'MISSING_SID_ON_SECONDARY'
        WHEN p.sid <> s.sid THEN 'SID_MISMATCH'
        ELSE 'MATCH'
    END,
    p.sid,
    s.sid,
    p.default_database_name,
    p.is_disabled,
    p.password_hash,
    p.check_policy,
    p.check_expiration
FROM #primary_logins p
LEFT JOIN #secondary_logins s
  ON p.login_name = s.login_name
WHERE s.login_name IS NULL OR s.sid IS NULL OR p.sid <> s.sid;

-- Preview detected issues
SELECT
    replica_server_name,
    login_name,
    principal_type,
    status,
    CONVERT(VARCHAR(200), primary_sid, 1) AS primary_sid_hex,
    CONVERT(VARCHAR(200), secondary_sid, 1) AS secondary_sid_hex
FROM #issues
ORDER BY replica_server_name, principal_type, status, login_name;

DECLARE
    @Login SYSNAME,
    @Type CHAR(1),
    @Status NVARCHAR(50),
    @PrimarySid VARBINARY(85),
    @DefaultDB SYSNAME,
    @IsDisabled BIT,
    @PwdHash VARBINARY(MAX),
    @CheckPolicy BIT,
    @CheckExp BIT,
    @cmd NVARCHAR(MAX),
    @remoteExec NVARCHAR(MAX);

DECLARE fix_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    replica_server_name, login_name, principal_type, status,
    primary_sid, default_database_name, is_disabled,
    password_hash, check_policy, check_expiration
FROM #issues
ORDER BY replica_server_name, principal_type, status, login_name;

OPEN fix_cursor;
FETCH NEXT FROM fix_cursor INTO @Replica, @Login, @Type, @Status, @PrimarySid, @DefaultDB, @IsDisabled, @PwdHash, @CheckPolicy, @CheckExp;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @cmd = NULL;

    IF @Type IN ('U','G') AND @RepairWindowsPrincipals = 1
    BEGIN
        -- For AD principals, SID is controlled by AD. Repair by recreate when mismatch/missing.
        SET @cmd = N'
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N''' + REPLACE(@Login,'''','''''') + N''')
    DROP LOGIN ' + QUOTENAME(@Login) + N';
CREATE LOGIN ' + QUOTENAME(@Login) + N' FROM WINDOWS
    WITH DEFAULT_DATABASE = ' + QUOTENAME(ISNULL(@DefaultDB,'master')) + N';
' + CASE WHEN ISNULL(@IsDisabled,0)=1 THEN N'ALTER LOGIN ' + QUOTENAME(@Login) + N' DISABLE;' ELSE N'' END;

        IF @Execute = 1
        BEGIN TRY
            SET @remoteExec = N'EXEC(''' + REPLACE(@cmd,'''','''''') + N''') AT ' + QUOTENAME((SELECT TOP 1 linked_server_name FROM @ReplicaServers WHERE replica_server_name = @Replica AND is_primary = 0)) + N';';
            EXEC sp_executesql @remoteExec;

            INSERT INTO dbo.AGSidRepairLog(run_id, replica_server_name, login_name, principal_type, action_type, command_text, success, error_message)
            VALUES(@run_id, @Replica, @Login, @Type, N'RECREATE_WINDOWS_LOGIN', @cmd, 1, NULL);
        END TRY
        BEGIN CATCH
            INSERT INTO dbo.AGSidRepairLog(run_id, replica_server_name, login_name, principal_type, action_type, command_text, success, error_message)
            VALUES(@run_id, @Replica, @Login, @Type, N'RECREATE_WINDOWS_LOGIN', @cmd, 0, ERROR_MESSAGE());
        END CATCH
        ELSE
            INSERT INTO dbo.AGSidRepairLog(run_id, replica_server_name, login_name, principal_type, action_type, command_text, success, error_message)
            VALUES(@run_id, @Replica, @Login, @Type, N'PREVIEW_RECREATE_WINDOWS_LOGIN', @cmd, NULL, NULL);
    END

    IF @Type = 'S' AND @RepairSqlLogins = 1
    BEGIN
        IF @PwdHash IS NULL
        BEGIN
            SET @cmd = N'-- Cannot auto-create SQL login ' + QUOTENAME(@Login) + N' because password_hash is NULL.';
            INSERT INTO dbo.AGSidRepairLog(run_id, replica_server_name, login_name, principal_type, action_type, command_text, success, error_message)
            VALUES(@run_id, @Replica, @Login, @Type, N'SKIP_SQL_LOGIN_NO_HASH', @cmd, 0, N'password_hash is NULL');
        END
        ELSE
        BEGIN
            SET @cmd = N'
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N''' + REPLACE(@Login,'''','''''') + N''')
    DROP LOGIN ' + QUOTENAME(@Login) + N';
CREATE LOGIN ' + QUOTENAME(@Login) + N'
    WITH PASSWORD = ' + CONVERT(NVARCHAR(MAX), @PwdHash, 1) + N' HASHED,
         SID = ' + CONVERT(NVARCHAR(200), @PrimarySid, 1) + N',
         CHECK_POLICY = ' + CASE WHEN ISNULL(@CheckPolicy,0)=1 THEN N'ON' ELSE N'OFF' END + N',
         CHECK_EXPIRATION = ' + CASE WHEN ISNULL(@CheckExp,0)=1 THEN N'ON' ELSE N'OFF' END + N',
         DEFAULT_DATABASE = ' + QUOTENAME(ISNULL(@DefaultDB,'master')) + N';
' + CASE WHEN ISNULL(@IsDisabled,0)=1 THEN N'ALTER LOGIN ' + QUOTENAME(@Login) + N' DISABLE;' ELSE N'' END;

            IF @Execute = 1
            BEGIN TRY
                SET @remoteExec = N'EXEC(''' + REPLACE(@cmd,'''','''''') + N''') AT ' + QUOTENAME((SELECT TOP 1 linked_server_name FROM @ReplicaServers WHERE replica_server_name = @Replica AND is_primary = 0)) + N';';
                EXEC sp_executesql @remoteExec;

                INSERT INTO dbo.AGSidRepairLog(run_id, replica_server_name, login_name, principal_type, action_type, command_text, success, error_message)
                VALUES(@run_id, @Replica, @Login, @Type, N'RECREATE_SQL_LOGIN_WITH_SID', @cmd, 1, NULL);
            END TRY
            BEGIN CATCH
                INSERT INTO dbo.AGSidRepairLog(run_id, replica_server_name, login_name, principal_type, action_type, command_text, success, error_message)
                VALUES(@run_id, @Replica, @Login, @Type, N'RECREATE_SQL_LOGIN_WITH_SID', @cmd, 0, ERROR_MESSAGE());
            END CATCH
            ELSE
                INSERT INTO dbo.AGSidRepairLog(run_id, replica_server_name, login_name, principal_type, action_type, command_text, success, error_message)
                VALUES(@run_id, @Replica, @Login, @Type, N'PREVIEW_RECREATE_SQL_LOGIN_WITH_SID', @cmd, NULL, NULL);
        END
    END

    FETCH NEXT FROM fix_cursor INTO @Replica, @Login, @Type, @Status, @PrimarySid, @DefaultDB, @IsDisabled, @PwdHash, @CheckPolicy, @CheckExp;
END

CLOSE fix_cursor;
DEALLOCATE fix_cursor;

-- Optional user remap across all online user databases (local instance)
IF @RemapDatabaseUsers = 1
BEGIN
    DECLARE @db SYSNAME, @mapSql NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state_desc = 'ONLINE'
      AND source_database_id IS NULL;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @mapSql = N'
USE ' + QUOTENAME(@db) + N';
DECLARE @stmt NVARCHAR(MAX) = N'''';
SELECT @stmt = @stmt + N''ALTER USER '' + QUOTENAME(dp.name) + N'' WITH LOGIN = '' + QUOTENAME(sp.name) + N'';'' + CHAR(10)
FROM sys.database_principals dp
JOIN master.sys.server_principals sp
  ON dp.sid = sp.sid
WHERE dp.type IN (''''S'''',''''U'''',''''G'''')
  AND dp.authentication_type IN (1,3)
  AND dp.principal_id > 4
  AND dp.name NOT IN (''''dbo'''',''''guest'''',''''INFORMATION_SCHEMA'''',''''sys'''');
PRINT @stmt;
EXEC sp_executesql @stmt;
';

        BEGIN TRY
            IF @Execute = 1
                EXEC sp_executesql @mapSql;

            INSERT INTO dbo.AGSidRepairLog(run_id, replica_server_name, login_name, principal_type, action_type, command_text, success, error_message)
            VALUES(@run_id, @@SERVERNAME, N'<DB_USER_REMAP:' + @db + N'>', N'X', N'REMAP_DB_USERS', @mapSql, CASE WHEN @Execute=1 THEN 1 ELSE NULL END, NULL);
        END TRY
        BEGIN CATCH
            INSERT INTO dbo.AGSidRepairLog(run_id, replica_server_name, login_name, principal_type, action_type, command_text, success, error_message)
            VALUES(@run_id, @@SERVERNAME, N'<DB_USER_REMAP:' + @db + N'>', N'X', N'REMAP_DB_USERS', @mapSql, 0, ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @db;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SELECT *
FROM dbo.AGSidRepairLog
WHERE run_id = @run_id
ORDER BY log_id;
