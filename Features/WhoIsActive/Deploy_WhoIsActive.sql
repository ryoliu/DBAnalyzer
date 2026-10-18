USE master;
GO
IF ISNULL(IS_SRVROLEMEMBER('sysadmin'),0)<>1
 THROW 58200,'A sysadmin login is required.',1;
IF CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<15
 THROW 58201,'SQL Server 2019 or later is required.',1;
IF NOT EXISTS(SELECT 1 FROM sys.dm_server_services
 WHERE servicename LIKE N'SQL Server Agent%' AND status_desc=N'Running')
 THROW 58202,'SQL Server Agent must be running.',1;
IF DB_ID(N'MS_PERF_COLLECTION') IS NULL
BEGIN
 CREATE DATABASE MS_PERF_COLLECTION;
 ALTER DATABASE MS_PERF_COLLECTION SET RECOVERY SIMPLE;
END;
GO
USE MS_PERF_COLLECTION;
GO
IF OBJECT_ID(N'dbo.WHOISACTIVE',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.WHOISACTIVE(
  [dd hh:mm:ss.mss] varchar(64) NULL,
  [dd hh:mm:ss.mss (avg)] varchar(30) NULL,
  session_id smallint NULL,
  sql_text xml NULL,
  sql_command xml NULL,
  login_name sysname NULL,
  wait_info nvarchar(4000) NULL,
  tasks varchar(36) NULL,
  CPU varchar(36) NULL,
  tempdb_allocations varchar(36) NULL,
  tempdb_current varchar(36) NULL,
  blocking_session_id smallint NULL,
  blocked_session_count varchar(30) NULL,
  reads varchar(36) NULL,
  writes varchar(36) NULL,
  context_switches varchar(36) NULL,
  physical_io varchar(36) NULL,
  physical_reads varchar(36) NULL,
  locks xml NULL,
  used_memory varchar(36) NULL,
  status varchar(30) NULL,
  open_tran_count varchar(30) NULL,
  percent_complete varchar(30) NULL,
  host_name sysname NULL,
  database_name sysname NULL,
  program_name sysname NULL,
  start_time datetime NULL,
  login_time datetime NULL,
  request_id int NULL,
  collection_time datetime NULL);
 CREATE CLUSTERED INDEX IX_COLLECTION_TIME_CLUSTERED ON dbo.WHOISACTIVE(collection_time);
END;
GO
