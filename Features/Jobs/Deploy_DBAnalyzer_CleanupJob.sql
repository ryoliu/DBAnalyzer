USE msdb;
GO
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 IF EXISTS (
  SELECT 1 FROM dbo.sysjobactivity a JOIN dbo.sysjobs j ON j.job_id = a.job_id
  WHERE j.name IN (N'_DBAnalyzer-History-Cleanup', N'_DBAnalyzer-Blocking-Cleanup')
   AND a.session_id = (SELECT MAX(session_id) FROM dbo.syssessions)
   AND a.run_requested_date IS NOT NULL AND a.stop_execution_date IS NULL)
  THROW 58510, 'A cleanup job is running or queued. Retry later.', 1;
 IF (SELECT COUNT(*) FROM dbo.sysjobs
  WHERE name IN (N'_DBAnalyzer-History-Cleanup', N'_DBAnalyzer-Blocking-Cleanup')) > 1
  THROW 58511, 'Multiple cleanup jobs exist. Resolve before deploying.', 1;

 DECLARE @JobId uniqueidentifier, @ScheduleId int, @Owner sysname = SUSER_SNAME(0x01),
         @Command nvarchar(max) = N'EXEC dbo.usp_PurgeDBAnalyzerHistory @RetentionDays=30, @PreviewOnly=0;';
 SELECT @JobId = job_id FROM dbo.sysjobs
 WHERE name IN (N'_DBAnalyzer-History-Cleanup', N'_DBAnalyzer-Blocking-Cleanup');
 IF @JobId IS NULL
 BEGIN
  EXEC dbo.sp_add_job @job_name=N'_DBAnalyzer-History-Cleanup', @enabled=0,
   @description=N'Keep 30 calendar dates including today across DBAnalyzer history tables.',
   @owner_login_name=@Owner, @job_id=@JobId OUTPUT;
  EXEC dbo.sp_add_jobserver @job_id=@JobId;
 END
 ELSE
  EXEC dbo.sp_update_job @job_id=@JobId, @new_name=N'_DBAnalyzer-History-Cleanup',
   @description=N'Keep 30 calendar dates including today across DBAnalyzer history tables.';

 IF EXISTS (SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id>1)
  THROW 58512, 'Unexpected cleanup job steps exist. Resolve before deploying.', 1;
 IF NOT EXISTS (SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@JobId AND step_id=1)
  EXEC dbo.sp_add_jobstep @job_id=@JobId, @step_id=1, @step_name=N'Purge DBAnalyzer history',
   @subsystem=N'TSQL', @database_name=N'DBAnalyzer', @command=@Command;
 EXEC dbo.sp_update_jobstep @job_id=@JobId, @step_id=1, @step_name=N'Purge DBAnalyzer history',
  @subsystem=N'TSQL', @database_name=N'DBAnalyzer', @command=@Command,
  @retry_attempts=3, @retry_interval=1, @on_success_action=1, @on_fail_action=2;

 IF (SELECT COUNT(*) FROM dbo.sysschedules WHERE name IN
  (N'_DBAnalyzer-History-Cleanup-Daily-0310', N'_DBAnalyzer-Blocking-Cleanup-Daily-0310')) > 1
  THROW 58513, 'Multiple cleanup schedules exist. Resolve before deploying.', 1;
 SELECT @ScheduleId=schedule_id FROM dbo.sysschedules WHERE name IN
  (N'_DBAnalyzer-History-Cleanup-Daily-0310', N'_DBAnalyzer-Blocking-Cleanup-Daily-0310');
 IF EXISTS (SELECT 1 FROM dbo.sysjobschedules WHERE schedule_id=@ScheduleId AND job_id<>@JobId)
  THROW 58514, 'The cleanup schedule is shared with another job.', 1;
 IF EXISTS (SELECT 1 FROM dbo.sysjobschedules WHERE job_id=@JobId
  AND (@ScheduleId IS NULL OR schedule_id<>@ScheduleId))
  THROW 58515, 'Unexpected cleanup schedules exist. Resolve before deploying.', 1;
 IF @ScheduleId IS NULL
  EXEC dbo.sp_add_schedule @schedule_name=N'_DBAnalyzer-History-Cleanup-Daily-0310',
   @enabled=1, @freq_type=4, @freq_interval=1, @freq_subday_type=1, @active_start_time=31000,
   @schedule_id=@ScheduleId OUTPUT;
 ELSE
  EXEC dbo.sp_update_schedule @schedule_id=@ScheduleId,
   @new_name=N'_DBAnalyzer-History-Cleanup-Daily-0310', @enabled=1,
   @freq_type=4, @freq_interval=1, @freq_subday_type=1, @freq_subday_interval=0,
   @active_start_time=31000, @active_end_time=235959;
 IF NOT EXISTS (SELECT 1 FROM dbo.sysjobschedules WHERE job_id=@JobId AND schedule_id=@ScheduleId)
  EXEC dbo.sp_attach_schedule @job_id=@JobId, @schedule_id=@ScheduleId;
 EXEC dbo.sp_update_job @job_id=@JobId, @enabled=1, @start_step_id=1;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
GO
