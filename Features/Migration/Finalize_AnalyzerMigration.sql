-- Run after deploying analyzer modules and updating the daily and cleanup jobs.
USE MS_PERF_COLLECTION;
GO
SET XACT_ABORT ON;
IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id=a.job_id
 WHERE a.session_id=(SELECT MAX(session_id) FROM msdb.dbo.syssessions)
 AND a.run_requested_date IS NOT NULL AND a.stop_execution_date IS NULL
 AND j.name=N'_DBAnalyzer-TestRows-Startup')
 THROW 58861,'The startup test job is running or queued.',1;
IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'_DBAnalyzer-TestRows-Startup')
BEGIN
 DECLARE @JobId uniqueidentifier=(SELECT job_id FROM msdb.dbo.sysjobs WHERE name=N'_DBAnalyzer-TestRows-Startup');
 EXEC msdb.dbo.sp_update_jobstep @job_id=@JobId,@step_id=2,@database_name=N'MS_PERF_COLLECTION',
  @command=N'EXEC analyzer.usp_CaptureTableRowCount @ReturnResults=0;';
 EXEC msdb.dbo.sp_update_job @job_id=@JobId,@enabled=1;
END;
IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobsteps WHERE database_name=N'DBAnalyzer'
 OR command LIKE N'%DBAnalyzer.dbo.%')
 THROW 58862,'A job still references the old database.',1;
IF EXISTS(SELECT 1 FROM sys.sql_expression_dependencies d JOIN sys.objects o ON o.object_id=d.referencing_id
 WHERE o.schema_id=SCHEMA_ID(N'analyzer') AND d.referenced_database_name=N'DBAnalyzer')
 THROW 58863,'An analyzer module still references the old database.',1;
-- Keep the old database as a read-only recovery copy; all active jobs use the target.
IF EXISTS(SELECT 1 FROM master.sys.databases WHERE name=N'DBAnalyzer' AND is_read_only=0)
 ALTER DATABASE DBAnalyzer SET READ_ONLY WITH NO_WAIT;
GO
