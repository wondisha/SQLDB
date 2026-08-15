/*
AG SID Consistency Check (Primary vs Secondary replicas)
Checks SID consistency for:
- Windows logins/users/groups (type U/G)
- SQL logins (type S)

How it works:
1) Configure linked servers for each AG replica (RPC OUT enabled).
2) Populate @ReplicaServers table with replica server names + linked server names.
3) Run from primary replica.

Output:
- Missing logins on a replica
- SID mismatches on a replica

Notes:
- Excludes built-in/system principals.
- Requires VIEW ANY DEFINITION / security metadata visibility on targets.
*/
SET NOCOUNT ON;

DECLARE @PrimaryServer SYSNAME = @@SERVERNAME;

-- Map AG replica server name to linked server name
DECLARE @ReplicaServers TABLE
(
    replica_server_name SYSNAME NOT NULL,
    linked_server_name SYSNAME NOT NULL,
    is_primary BIT NOT NULL
);

/*
TODO: Update with your environment.
Example:
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

IF OBJECT_ID('tempdb..#primary_logins') IS NOT NULL DROP TABLE #primary_logins;
CREATE TABLE #primary_logins
(
    login_name SYSNAME NOT NULL,
    type CHAR(1) NOT NULL,
    sid VARBINARY(85) NOT NULL,
    is_disabled BIT NOT NULL,
    default_database_name SYSNAME NULL
);

INSERT INTO #primary_logins(login_name, type, sid, is_disabled, default_database_name)
SELECT
    sp.name,
    sp.type,
    sp.sid,
    sl.is_disabled,
    sl.default_database_name
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
        sp.name,
        sp.type,
        sp.sid,
        sl.is_disabled,
        sl.default_database_name
    FROM OPENQUERY(' + QUOTENAME(@Linked) + N',
        ''SELECT sp.name, sp.type, sp.sid, sl.is_disabled, sl.default_database_name
          FROM master.sys.server_principals sp
          LEFT JOIN master.sys.sql_logins sl ON sp.principal_id = sl.principal_id
          WHERE sp.type IN (''''S'''',''''U'''',''''G'''')
            AND sp.name NOT LIKE ''''##%''''
            AND sp.name NOT LIKE ''''NT AUTHORITY\\%''''
            AND sp.name NOT LIKE ''''NT SERVICE\\%''''
            AND sp.name <> ''''sa'''' '') AS R(sp_name, sp_type, sp_sid, is_disabled, default_database_name)
    CROSS APPLY (
        SELECT
            CAST(R.sp_name AS SYSNAME) AS name,
            CAST(R.sp_type AS CHAR(1)) AS type,
            CAST(R.sp_sid AS VARBINARY(85)) AS sid,
            CAST(R.is_disabled AS BIT) AS is_disabled,
            CAST(R.default_database_name AS SYSNAME) AS default_database_name
    ) X;
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

;WITH cmp AS
(
    SELECT
        s.replica_server_name,
        p.login_name,
        p.type AS primary_type,
        s.type AS secondary_type,
        p.sid AS primary_sid,
        s.sid AS secondary_sid,
        p.is_disabled AS primary_disabled,
        s.is_disabled AS secondary_disabled,
        p.default_database_name AS primary_default_db,
        s.default_database_name AS secondary_default_db,
        CASE
            WHEN s.login_name IS NULL THEN 'MISSING_ON_SECONDARY'
            WHEN s.sid IS NULL THEN 'MISSING_SID_ON_SECONDARY'
            WHEN p.sid <> s.sid THEN 'SID_MISMATCH'
            ELSE 'MATCH'
        END AS status
    FROM #primary_logins p
    LEFT JOIN #secondary_logins s
      ON p.login_name = s.login_name
)
SELECT
    replica_server_name,
    login_name,
    primary_type,
    secondary_type,
    status,
    primary_disabled,
    secondary_disabled,
    primary_default_db,
    secondary_default_db,
    CONVERT(VARCHAR(200), primary_sid, 1) AS primary_sid_hex,
    CONVERT(VARCHAR(200), secondary_sid, 1) AS secondary_sid_hex
FROM cmp
WHERE status <> 'MATCH'
ORDER BY replica_server_name, status, login_name;
