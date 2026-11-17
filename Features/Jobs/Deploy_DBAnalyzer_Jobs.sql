USE msdb;
GO
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;

 IF EXISTS(
  SELECT 1 FROM dbo.sysjobactivity a JOIN dbo.sysjobs j ON j.job_id=a.job_id
  WHERE j.name IN(N'_DBAnalyzer-Daily',N'_DBAnalyzer-Blocking-Daily',
   N'_DBAnalyzer-Blocking-Incremental',N'_DBAnalyzer-LoginFailed-Daily')
  AND a.session_id=(SELECT MAX(session_id) FROM dbo.syssessions)
  AND a.run_requested_date IS NOT NULL AND a.stop_execution_date IS NULL)
  THROW 54200,'An analysis job is running or queued. Wait and deploy again.',1;

 DECLARE @JobId uniqueidentifier,@ScheduleId int,@OldScheduleId int,
         @Owner sysname=SUSER_SNAME(0x01),@StepCommand nvarchar(max);
 IF @Owner IS NULL THROW 54201,'The server administrator SID could not be resolved.',1;
 IF (SELECT COUNT(*) FROM dbo.sysjobs WHERE name IN
  (N'_DBAnalyzer-Daily',N'_DBAnalyzer-Blocking-Daily',N'_DBAnalyzer-Blocking-Incremental'))>1
  THROW 54202,'Multiple blocking analysis jobs exist; resolve before deploying.',1;

 SELECT @JobId=job_id FROM dbo.sysjobs WHERE name IN
  (N'_DBAnalyzer-Daily',N'_DBAnalyzer-Blocking-Daily',N'_DBAnalyzer-Blocking-Incremental');
 IF @JobId IS NULL
 BEGIN
  EXEC dbo.sp_add_job @job_name=N'_DBAnalyzer-Daily',@enabled=0,
   @description=N'Daily SQL analysis and current table row-count snapshots.',
   @owner_login_name=@Owner,@job_id=@JobId OUTPUT;
  EXEC dbo.sp_add_jobserver @job_id=@JobId;
 END
 ELSE
  EXEC dbo.sp_update_job @job_id=@JobId,@enabled=0,@new_name=N'_DBAnalyzer-Daily',
   @description=N'Daily SQL analysis and current table row-count snapshots.';

 IF EXISTS(SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id>5)
  THROW 54203,'Unexpected job steps exist; resolve before deploying.',1;

 -- Create missing steps, then configure new and existing steps in one place.
 SET @StepCommand=N'EXEC analyzer.usp_AnalyzeWhoIsActiveBlocking @ReturnResults=0;';
 IF NOT EXISTS(SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id=1)
  EXEC dbo.sp_add_jobstep @job_id=@JobId,@step_id=1,@step_name=N'Analyze blocking',
   @subsystem=N'TSQL',@command=@StepCommand;
 EXEC dbo.sp_update_jobstep @job_id=@JobId,@step_id=1,@step_name=N'Analyze blocking',
  @subsystem=N'TSQL',@database_name=N'MS_PERF_COLLECTION',@command=@StepCommand,
  @retry_attempts=3,@retry_interval=1,@on_success_action=3,@on_fail_action=2;

 SET @StepCommand=N'EXEC analyzer.usp_AnalyzeLoginFailed @ReturnResults=0;';
 IF NOT EXISTS(SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id=2)
  EXEC dbo.sp_add_jobstep @job_id=@JobId,@step_id=2,@step_name=N'Collect failed logins',
   @subsystem=N'TSQL',@command=@StepCommand;
 EXEC dbo.sp_update_jobstep @job_id=@JobId,@step_id=2,@step_name=N'Collect failed logins',
  @subsystem=N'TSQL',@database_name=N'MS_PERF_COLLECTION',@command=@StepCommand,
  @retry_attempts=3,@retry_interval=1,@on_success_action=3,@on_fail_action=2;

 SET @StepCommand=N'EXEC analyzer.usp_AnalyzeWhoIsActiveLongRunning @ReturnResults=0;';
 IF NOT EXISTS(SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id=3)
  EXEC dbo.sp_add_jobstep @job_id=@JobId,@step_id=3,@step_name=N'Analyze long-running SQL',
   @subsystem=N'TSQL',@command=@StepCommand;
 EXEC dbo.sp_update_jobstep @job_id=@JobId,@step_id=3,@step_name=N'Analyze long-running SQL',
  @subsystem=N'TSQL',@database_name=N'MS_PERF_COLLECTION',@command=@StepCommand,
  @retry_attempts=3,@retry_interval=1,@on_success_action=3,@on_fail_action=2;

 SET @StepCommand=N'EXEC analyzer.usp_AnalyzeWhoIsActiveHighResource @ReturnResults=0;';
 IF NOT EXISTS(SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id=4)
  EXEC dbo.sp_add_jobstep @job_id=@JobId,@step_id=4,@step_name=N'Analyze high-resource SQL',
   @subsystem=N'TSQL',@command=@StepCommand;
 EXEC dbo.sp_update_jobstep @job_id=@JobId,@step_id=4,@step_name=N'Analyze high-resource SQL',
  @subsystem=N'TSQL',@database_name=N'MS_PERF_COLLECTION',@command=@StepCommand,
  @retry_attempts=3,@retry_interval=1,@on_success_action=3,@on_fail_action=2;

 SET @StepCommand=N'EXEC analyzer.usp_CaptureTableRowCount @ReturnResults=0;';
 IF NOT EXISTS(SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id=5)
  EXEC dbo.sp_add_jobstep @job_id=@JobId,@step_id=5,@step_name=N'Capture table row counts',
   @subsystem=N'TSQL',@command=@StepCommand;
 EXEC dbo.sp_update_jobstep @job_id=@JobId,@step_id=5,@step_name=N'Capture table row counts',
  @subsystem=N'TSQL',@database_name=N'MS_PERF_COLLECTION',@command=@StepCommand,
  @retry_attempts=3,@retry_interval=1,@on_success_action=1,@on_fail_action=2;

 SELECT @OldScheduleId=js.schedule_id FROM dbo.sysjobschedules js
 JOIN dbo.sysschedules s ON s.schedule_id=js.schedule_id
 WHERE js.job_id=@JobId AND s.name=N'_DBAnalyzer-Blocking-Daily-0200';
 IF @OldScheduleId IS NOT NULL
  EXEC dbo.sp_detach_schedule @job_id=@JobId,@schedule_id=@OldScheduleId,@delete_unused_schedule=1;
 SET @OldScheduleId=NULL;
 SELECT @OldScheduleId=js.schedule_id FROM dbo.sysjobschedules js
 JOIN dbo.sysschedules s ON s.schedule_id=js.schedule_id
 WHERE js.job_id=@JobId AND s.name=N'_DBAnalyzer-Blocking-Every-5-Minutes';
 IF @OldScheduleId IS NOT NULL
  EXEC dbo.sp_detach_schedule @job_id=@JobId,@schedule_id=@OldScheduleId,@delete_unused_schedule=1;

 SELECT @ScheduleId=schedule_id FROM dbo.sysschedules WHERE name=N'_DBAnalyzer-Daily-0200';
 IF @ScheduleId IS NULL
  EXEC dbo.sp_add_schedule @schedule_name=N'_DBAnalyzer-Daily-0200',
   @enabled=1,@freq_type=4,@freq_interval=1,@freq_subday_type=1,@active_start_time=20000,
   @schedule_id=@ScheduleId OUTPUT;
 ELSE
  EXEC dbo.sp_update_schedule @schedule_id=@ScheduleId,@enabled=1,
   @freq_type=4,@freq_interval=1,@freq_subday_type=1,@active_start_time=20000;
 IF NOT EXISTS(SELECT 1 FROM dbo.sysjobschedules WHERE job_id=@JobId AND schedule_id=@ScheduleId)
  EXEC dbo.sp_attach_schedule @job_id=@JobId,@schedule_id=@ScheduleId;

 IF EXISTS(SELECT 1 FROM dbo.sysjobs WHERE name=N'_DBAnalyzer-LoginFailed-Daily')
  EXEC dbo.sp_delete_job @job_name=N'_DBAnalyzer-LoginFailed-Daily',@delete_unused_schedule=1;

 EXEC dbo.sp_update_job @job_id=@JobId,@enabled=1,@start_step_id=1;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
GO
