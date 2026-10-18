USE msdb;
GO
-- Preserve an existing collector and its settings.
IF EXISTS(SELECT 1 FROM dbo.sysjobsteps
 WHERE database_name=N'MS_PERF_COLLECTION' AND command LIKE N'%sp_WhoIsActive%')
 RETURN;

SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @JobId uniqueidentifier,@Owner sysname=SUSER_SNAME(0x01);
 EXEC dbo.sp_add_job @job_name=N'_WhoIsActive 11 Collection Jobs',@enabled=0,
  @description=N'Collect WhoIsActive every minute and retain seven days.',
  @owner_login_name=@Owner,@job_id=@JobId OUTPUT;
 EXEC dbo.sp_add_jobstep @job_id=@JobId,@step_id=1,@step_name=N'Collect WhoIsActive',
  @subsystem=N'TSQL',@database_name=N'MS_PERF_COLLECTION',
  @command=N'EXEC dbo.sp_WhoIsActive
   @show_sleeping_spids=1,@show_system_spids=1,@get_task_info=2,
   @get_locks=1,@find_block_leaders=1,@get_outer_command=1,
   @get_full_inner_text=1,@get_avg_time=1,@format_output=1,
   @sort_order=''[start_time] ASC'',@destination_table=''dbo.WHOISACTIVE'';',
  @on_success_action=3,@on_fail_action=2;
 EXEC dbo.sp_add_jobstep @job_id=@JobId,@step_id=2,@step_name=N'Purge old samples',
  @subsystem=N'TSQL',@database_name=N'MS_PERF_COLLECTION',
  @command=N'DELETE dbo.WHOISACTIVE WHERE collection_time<DATEADD(DAY,-7,GETDATE());',
  @on_success_action=1,@on_fail_action=2;
 EXEC dbo.sp_add_jobschedule @job_id=@JobId,@name=N'WhoIsActive Collection Every Minute',
  @enabled=1,@freq_type=4,@freq_interval=1,@freq_subday_type=4,@freq_subday_interval=1,
  @active_start_time=0,@active_end_time=235959;
 EXEC dbo.sp_add_jobserver @job_id=@JobId;
 EXEC dbo.sp_update_job @job_id=@JobId,@enabled=1,@start_step_id=1;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
GO
