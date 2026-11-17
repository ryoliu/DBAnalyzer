USE master;
GO
IF DB_ID(N'TableRowCountTestLab') IS NULL
BEGIN
 EXEC(N'CREATE DATABASE TableRowCountTestLab;');
 EXEC(N'ALTER DATABASE TableRowCountTestLab SET RECOVERY SIMPLE;');
END;
GO
USE TableRowCountTestLab;
GO
IF OBJECT_ID(N'dbo.StartupLoadRun',N'U') IS NULL
 CREATE TABLE dbo.StartupLoadRun(
  load_run_id bigint IDENTITY PRIMARY KEY,
  sqlserver_start_time datetime NOT NULL UNIQUE,
  started_at datetime2(3) NOT NULL,
  completed_at datetime2(3) NULL,
  rows_before bigint NOT NULL,
  rows_inserted int NOT NULL,
  rows_after bigint NULL);
IF OBJECT_ID(N'dbo.SampleRows',N'U') IS NULL
 CREATE TABLE dbo.SampleRows(
  sample_id bigint IDENTITY PRIMARY KEY,
  load_run_id bigint NOT NULL REFERENCES dbo.StartupLoadRun(load_run_id),
  created_at datetime2(3) NOT NULL,
  payload varchar(100) NOT NULL);
GO
CREATE OR ALTER PROCEDURE dbo.usp_LoadStartupTestRows
 @RowsPerStartup int=1000
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 IF @@TRANCOUNT<>0 THROW 58700,'Execute outside an existing transaction.',1;
 IF @RowsPerStartup IS NULL OR @RowsPerStartup<1 OR @RowsPerStartup>100000
  THROW 58701,'RowsPerStartup must be between 1 and 100000.',1;

 DECLARE @Startup datetime=(SELECT sqlserver_start_time FROM sys.dm_os_sys_info),
  @RunId bigint,@Before bigint,@Inserted int=0,@LockResult int;
 BEGIN TRY
  BEGIN TRANSACTION;
  EXEC @LockResult=sys.sp_getapplock @Resource=N'TableRowCountTestLab.StartupLoad',
   @LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=0;
  IF @LockResult<0 THROW 58702,'Another startup test load is running.',1;
  IF EXISTS(SELECT 1 FROM dbo.StartupLoadRun WHERE sqlserver_start_time=@Startup)
  BEGIN
   COMMIT TRANSACTION;
   RETURN;
  END;

  SELECT @Before=COUNT_BIG(*) FROM dbo.SampleRows;
  INSERT dbo.StartupLoadRun(sqlserver_start_time,started_at,rows_before,rows_inserted)
  VALUES(@Startup,SYSDATETIME(),@Before,0);
  SET @RunId=CONVERT(bigint,SCOPE_IDENTITY());
  WHILE @Inserted<@RowsPerStartup
  BEGIN
   INSERT dbo.SampleRows(load_run_id,created_at,payload)
   VALUES(@RunId,SYSDATETIME(),REPLICATE('X',100));
   SET @Inserted=@Inserted+1;
  END;
  UPDATE dbo.StartupLoadRun
  SET completed_at=SYSDATETIME(),rows_inserted=@Inserted,
   rows_after=(SELECT COUNT_BIG(*) FROM dbo.SampleRows)
  WHERE load_run_id=@RunId;
  COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH;
END;
GO
USE msdb;
GO
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 IF EXISTS(
  SELECT 1 FROM dbo.sysjobactivity a JOIN dbo.sysjobs j ON j.job_id=a.job_id
  WHERE j.name=N'_DBAnalyzer-TestRows-Startup'
   AND a.session_id=(SELECT MAX(session_id) FROM dbo.syssessions)
   AND a.run_requested_date IS NOT NULL AND a.stop_execution_date IS NULL)
  THROW 58703,'Startup test job is running or queued. Retry deployment later.',1;

 DECLARE @JobId uniqueidentifier,@ScheduleId int,@Owner sysname=SUSER_SNAME(0x01);
 IF @Owner IS NULL THROW 58704,'The server administrator SID could not be resolved.',1;
 SELECT @JobId=job_id FROM dbo.sysjobs WHERE name=N'_DBAnalyzer-TestRows-Startup';
 IF @JobId IS NULL
 BEGIN
  EXEC dbo.sp_add_job @job_name=N'_DBAnalyzer-TestRows-Startup',@enabled=0,
   @owner_login_name=@Owner,@description=N'Insert one test batch per SQL Server startup, then capture table row counts.',
   @job_id=@JobId OUTPUT;
  EXEC dbo.sp_add_jobserver @job_id=@JobId;
 END;
 IF EXISTS(SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id>2)
  THROW 58705,'Unexpected startup test job steps exist.',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id=1)
  EXEC dbo.sp_add_jobstep @job_id=@JobId,@step_id=1,@step_name=N'Insert startup test rows',@subsystem=N'TSQL',
   @command=N'EXEC dbo.usp_LoadStartupTestRows @RowsPerStartup=1000;';
 EXEC dbo.sp_update_jobstep @job_id=@JobId,@step_id=1,@step_name=N'Insert startup test rows',
  @subsystem=N'TSQL',@database_name=N'TableRowCountTestLab',
  @command=N'EXEC dbo.usp_LoadStartupTestRows @RowsPerStartup=1000;',
  @retry_attempts=3,@retry_interval=1,@on_success_action=3,@on_fail_action=2;
 IF NOT EXISTS(SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id=2)
  EXEC dbo.sp_add_jobstep @job_id=@JobId,@step_id=2,@step_name=N'Capture table row counts',@subsystem=N'TSQL',
   @command=N'EXEC analyzer.usp_CaptureTableRowCount @ReturnResults=0;';
 EXEC dbo.sp_update_jobstep @job_id=@JobId,@step_id=2,@step_name=N'Capture table row counts',
  @subsystem=N'TSQL',@database_name=N'MS_PERF_COLLECTION',
  @command=N'EXEC analyzer.usp_CaptureTableRowCount @ReturnResults=0;',
  @retry_attempts=3,@retry_interval=1,@on_success_action=1,@on_fail_action=2;

 SELECT @ScheduleId=schedule_id FROM dbo.sysschedules WHERE name=N'_DBAnalyzer-TestRows-AgentStart';
 IF @ScheduleId IS NULL
  EXEC dbo.sp_add_schedule @schedule_name=N'_DBAnalyzer-TestRows-AgentStart',
   @enabled=1,@freq_type=64,@schedule_id=@ScheduleId OUTPUT;
 ELSE
  EXEC dbo.sp_update_schedule @schedule_id=@ScheduleId,@enabled=1,@freq_type=64;
 IF NOT EXISTS(SELECT 1 FROM dbo.sysjobschedules WHERE job_id=@JobId AND schedule_id=@ScheduleId)
  EXEC dbo.sp_attach_schedule @job_id=@JobId,@schedule_id=@ScheduleId;
 EXEC dbo.sp_update_job @job_id=@JobId,@enabled=1,@start_step_id=1;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
GO
