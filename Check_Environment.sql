USE master;
GO
IF ISNULL(IS_SRVROLEMEMBER('sysadmin'),0)<>1
 THROW 57000,'A sysadmin login is required.',1;
IF CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<15
 THROW 57001,'SQL Server 2019 or later is required.',1;
IF NOT EXISTS(SELECT 1 FROM sys.dm_server_services
 WHERE servicename LIKE N'SQL Server Agent%' AND status_desc=N'Running')
 THROW 57002,'SQL Server Agent must be running.',1;
IF NOT EXISTS(SELECT 1 FROM sys.databases WHERE name=N'MS_PERF_COLLECTION' AND state_desc=N'ONLINE')
 THROW 57003,'MS_PERF_COLLECTION must already exist and be online.',1;
IF EXISTS(SELECT 1 FROM sys.databases WHERE name=N'MS_PERF_COLLECTION'
 AND (state_desc<>N'ONLINE' OR is_read_only=1 OR compatibility_level<110))
 THROW 57004,'MS_PERF_COLLECTION must be online, writable, and use compatibility level 110 or later.',1;
IF EXISTS(
 SELECT 1 FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id=a.job_id
 WHERE j.name IN(N'_DBAnalyzer-Daily',N'_DBAnalyzer-Blocking-Daily',N'_DBAnalyzer-Blocking-Cleanup',
  N'_DBAnalyzer-LoginFailed-Daily',N'_DBAnalyzer-Blocking-Incremental',
  N'_DBAnalyzer-History-Cleanup',N'_DBAnalyzer-TestRows-Startup')
 AND a.session_id=(SELECT MAX(session_id) FROM msdb.dbo.syssessions)
 AND a.run_requested_date IS NOT NULL AND a.stop_execution_date IS NULL)
 THROW 57005,'An analyzer job is running or queued. Wait and deploy again.',1;
GO
USE MS_PERF_COLLECTION;
GO
IF OBJECT_ID(N'dbo.WHOISACTIVE',N'U') IS NULL
 THROW 57006,'MS_PERF_COLLECTION.dbo.WHOISACTIVE is missing.',1;
IF OBJECT_ID(N'dbo.sp_WhoIsActive',N'P') IS NULL
 THROW 57007,'MS_PERF_COLLECTION.dbo.sp_WhoIsActive is missing.',1;
IF EXISTS(
 SELECT 1 FROM(VALUES(N'collection_time'),(N'session_id'),(N'request_id'),
  (N'login_time'),(N'start_time'),(N'blocking_session_id'),(N'database_name'),
  (N'login_name'),(N'host_name'),(N'program_name'),(N'status'),(N'wait_info'),
  (N'sql_text'),(N'sql_command'),(N'CPU'),(N'reads')) v(column_name)
 WHERE NOT EXISTS(SELECT 1 FROM sys.columns c
  WHERE c.object_id=OBJECT_ID(N'dbo.WHOISACTIVE') AND c.name=v.column_name))
 THROW 57008,'The WhoIsActive source table is missing required columns.',1;
IF EXISTS(SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.WHOISACTIVE')
 AND name IN(N'sql_text',N'sql_command') AND system_type_id<>241)
 THROW 57009,'WhoIsActive sql_text and sql_command must be XML.',1;
IF NOT EXISTS(
 SELECT 1 FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobsteps st ON st.job_id=j.job_id
 JOIN msdb.dbo.sysjobschedules js ON js.job_id=j.job_id
 JOIN msdb.dbo.sysschedules s ON s.schedule_id=js.schedule_id
 WHERE j.enabled=1 AND s.enabled=1 AND st.database_name=N'MS_PERF_COLLECTION'
 AND st.command LIKE N'%sp_WhoIsActive%')
 THROW 57010,'An enabled scheduled WhoIsActive collector is required.',1;
GO
CREATE TABLE #AuditLevel(config_name nvarchar(128),config_value nvarchar(128));
INSERT #AuditLevel EXEC master.dbo.xp_loginconfig N'audit level';
IF NOT EXISTS(SELECT 1 FROM #AuditLevel
 WHERE config_name=N'audit level' AND LOWER(config_value) IN(N'failure',N'all'))
 THROW 57011,'Login auditing must include failed logins.',1;
DROP TABLE #AuditLevel;
USE master;
GO
