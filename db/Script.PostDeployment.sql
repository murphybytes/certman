/*
Post-deployment script, run after every publish. It must be safe to re-run.

Creates a contained database user for the environment's Entra users group
(grp_certdb_users_dev or grp_certdb_users_prod), named by the CertdbUsersGroup
SQLCMD variable, and grants it read/write access. This lives here rather than
in the schema model because SQL projects don't allow SQLCMD variables in object
names. Publishing must be done by an Entra identity, e.g. a member of
grp_certdb_admins_<env>.
*/
DECLARE @usersGroup sysname = N'$(CertdbUsersGroup)';
DECLARE @quotedGroup nvarchar(258) = QUOTENAME(@usersGroup);
DECLARE @sql nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @usersGroup)
BEGIN
    SET @sql = N'CREATE USER ' + @quotedGroup + N' FROM EXTERNAL PROVIDER;';
    EXEC sys.sp_executesql @sql;
END

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members AS rm
    JOIN sys.database_principals AS r ON r.principal_id = rm.role_principal_id
    JOIN sys.database_principals AS m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'db_datareader' AND m.name = @usersGroup
)
BEGIN
    SET @sql = N'ALTER ROLE [db_datareader] ADD MEMBER ' + @quotedGroup + N';';
    EXEC sys.sp_executesql @sql;
END

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members AS rm
    JOIN sys.database_principals AS r ON r.principal_id = rm.role_principal_id
    JOIN sys.database_principals AS m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'db_datawriter' AND m.name = @usersGroup
)
BEGIN
    SET @sql = N'ALTER ROLE [db_datawriter] ADD MEMBER ' + @quotedGroup + N';';
    EXEC sys.sp_executesql @sql;
END
GO
