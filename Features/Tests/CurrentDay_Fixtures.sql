-- Executed by Test_CurrentDay.ps1 in an isolated tempdb schema.
DECLARE @Today date=CONVERT(date,GETDATE()), @Past date=DATEADD(DAY,-1,CONVERT(date,GETDATE()));
UPDATE {{schema}}.Clock SET run_time=DATEADD(HOUR,10,CONVERT(datetime,@Today));
INSERT {{schema}}.WHOISACTIVE(collection_time,session_id,request_id,login_time,start_time,
 blocking_session_id,status,CPU,reads,database_name,login_name,sql_text,sql_command)
SELECT times.sample_time,actors.session_id,1,DATEADD(HOUR,-3,CONVERT(datetime,@Today)),
 DATEADD(HOUR,-2,CONVERT(datetime,@Today)),actors.blocker,
 CASE WHEN actors.blocker IS NULL THEN 'running' ELSE 'suspended' END,'100','1,000',N'Fixture',N'Fixture',
 CONVERT(xml,N'<query>SELECT 1;</query>'),CONVERT(xml,N'<query>SELECT 1;</query>')
FROM (VALUES
 (DATEADD(MINUTE,-1,CONVERT(datetime,@Today)),0),
 (CONVERT(datetime,@Today),0),
 (DATEADD(MINUTE,599,CONVERT(datetime,@Today)),0),
 (DATEADD(MINUTE,600,CONVERT(datetime,@Today)),100),
 (DATEADD(MINUTE,601,CONVERT(datetime,@Today)),200)) times(sample_time,actor_offset)
CROSS APPLY (VALUES(101+times.actor_offset,CONVERT(int,NULL)),(102+times.actor_offset,101+times.actor_offset)) actors(session_id,blocker);
INSERT {{schema}}.SourceLog VALUES
 (0,DATEADD(MINUTE,-1,CONVERT(datetime,@Today)),N'Logon',N'Login failed for user ''Past''.'),
 (0,CONVERT(datetime,@Today),N'Logon',N'Login failed for user ''Midnight''.'),
 (0,DATEADD(MINUTE,599,CONVERT(datetime,@Today)),N'Logon',N'Login failed for user ''Before''.'),
 (0,DATEADD(MINUTE,600,CONVERT(datetime,@Today)),N'Logon',N'Login failed for user ''Boundary''.'),
 (0,DATEADD(MINUTE,601,CONVERT(datetime,@Today)),N'Logon',N'Login failed for user ''Future''.'),
 (1,DATEADD(SECOND,-1,CONVERT(datetime,@Past)),N'Server',N'Coverage witness');

-- Explicit historical dates still cover the complete day.
EXEC {{schema}}.usp_AnalyzeWhoIsActiveBlocking @AnalysisDate=@Past,@ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @AnalysisDate=@Past,@ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @AnalysisDate=@Past,@ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeLoginFailed @AnalysisDate=@Past,@ReturnResults=0;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.BlockingAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.BlockingAnalysisRun) AND analysis_date=@Past AND status='SUCCEEDED' AND captured_row_count=2) THROW 58920,'Unexpected analysis date or source range: BlockingAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSqlAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.LongRunningSqlAnalysisRun) AND analysis_date=@Past AND status='SUCCEEDED' AND captured_row_count=2) THROW 58920,'Unexpected analysis date or source range: LongRunningSqlAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSqlAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.HighResourceSqlAnalysisRun) AND analysis_date=@Past AND status='SUCCEEDED' AND captured_row_count=2) THROW 58920,'Unexpected analysis date or source range: HighResourceSqlAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LoginFailedAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.LoginFailedAnalysisRun) AND analysis_date=@Past AND status='SUCCEEDED' AND failed_login_count=1) THROW 58920,'Unexpected analysis date or source range: LoginFailedAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.BlockingAnalysisRun WHERE analysis_date=@Past AND requested_to_time=CONVERT(datetime,@Today)) THROW 58921,'Historical end boundary changed.',1;

-- Default dates use today and exclude observations exactly at or beyond the captured time.
EXEC {{schema}}.usp_AnalyzeWhoIsActiveBlocking @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeLoginFailed @ReturnResults=0;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.BlockingAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.BlockingAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND captured_row_count=4) THROW 58920,'Unexpected analysis date or source range: BlockingAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSqlAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.LongRunningSqlAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND captured_row_count=4) THROW 58920,'Unexpected analysis date or source range: LongRunningSqlAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSqlAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.HighResourceSqlAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND captured_row_count=4) THROW 58920,'Unexpected analysis date or source range: HighResourceSqlAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LoginFailedAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.LoginFailedAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND failed_login_count=2) THROW 58920,'Unexpected analysis date or source range: LoginFailedAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.BlockingAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.BlockingAnalysisRun)
 AND requested_from_time=CONVERT(datetime,@Today) AND requested_to_time=DATEADD(HOUR,10,CONVERT(datetime,@Today)))
 THROW 58922,'The current-day cutoff was not frozen.',1;
IF EXISTS(SELECT 1 FROM {{schema}}.HighResourceSql WHERE analysis_date=@Today AND session_id>=200)
 OR EXISTS(SELECT 1 FROM {{schema}}.LoginFailed WHERE analysis_date=@Today AND login_name IN(N'Boundary',N'Future'))
 THROW 58923,'Future or exact-cutoff observations were included.',1;
IF (SELECT COUNT(*) FROM {{schema}}.LongRunningSql WHERE analysis_date=@Today)<>2
 OR EXISTS(SELECT 1 FROM {{schema}}.LongRunningSql WHERE analysis_date=@Today AND request_start_time>=CONVERT(datetime,@Today))
 THROW 58924,'Cross-midnight requests were lost.',1;

-- Repeating the same cutoff must replace, rather than accumulate, results.
EXEC {{schema}}.usp_AnalyzeWhoIsActiveBlocking @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeLoginFailed @ReturnResults=0;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.BlockingAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.BlockingAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND captured_row_count=4) THROW 58920,'Unexpected analysis date or source range: BlockingAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSqlAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.LongRunningSqlAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND captured_row_count=4) THROW 58920,'Unexpected analysis date or source range: LongRunningSqlAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSqlAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.HighResourceSqlAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND captured_row_count=4) THROW 58920,'Unexpected analysis date or source range: HighResourceSqlAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LoginFailedAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.LoginFailedAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND failed_login_count=2) THROW 58920,'Unexpected analysis date or source range: LoginFailedAnalysisRun.',1;
IF (SELECT COUNT(*) FROM {{schema}}.LongRunningSql WHERE analysis_date=@Today)<>2 OR (SELECT COUNT(*) FROM {{schema}}.LoginFailed WHERE analysis_date=@Today)<>2 THROW 58925,'Repeated execution accumulated data.',1;

-- Advancing the cutoff includes new observations without losing earlier data.
UPDATE {{schema}}.Clock SET run_time=DATEADD(MINUTE,610,CONVERT(datetime,@Today));
EXEC {{schema}}.usp_AnalyzeWhoIsActiveBlocking @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeLoginFailed @ReturnResults=0;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.BlockingAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.BlockingAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND captured_row_count=8) THROW 58920,'Unexpected analysis date or source range: BlockingAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSqlAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.LongRunningSqlAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND captured_row_count=8) THROW 58920,'Unexpected analysis date or source range: LongRunningSqlAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSqlAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.HighResourceSqlAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND captured_row_count=8) THROW 58920,'Unexpected analysis date or source range: HighResourceSqlAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LoginFailedAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.LoginFailedAnalysisRun) AND analysis_date=@Today AND status='SUCCEEDED' AND failed_login_count=4) THROW 58920,'Unexpected analysis date or source range: LoginFailedAnalysisRun.',1;
IF (SELECT COUNT(*) FROM {{schema}}.LongRunningSql WHERE analysis_date=@Today)<>6
 OR (SELECT COUNT(*) FROM {{schema}}.HighResourceSql WHERE analysis_date=@Today)<>6
 OR (SELECT COUNT(*) FROM {{schema}}.LoginFailed WHERE analysis_date=@Today)<>4
 THROW 58926,'Advancing the current-day window lost or duplicated results.',1;

-- At the next midnight, the default date rolls forward and earlier reports remain.
DECLARE @NextDay date=DATEADD(DAY,1,@Today);
UPDATE {{schema}}.Clock SET run_time=CONVERT(datetime,@NextDay);
EXEC {{schema}}.usp_AnalyzeWhoIsActiveBlocking @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeLoginFailed @ReturnResults=0;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.BlockingAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.BlockingAnalysisRun) AND analysis_date=@NextDay AND status='SUCCEEDED' AND captured_row_count=0) THROW 58920,'Unexpected analysis date or source range: BlockingAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSqlAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.LongRunningSqlAnalysisRun) AND analysis_date=@NextDay AND status='SUCCEEDED' AND captured_row_count=0) THROW 58920,'Unexpected analysis date or source range: LongRunningSqlAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSqlAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.HighResourceSqlAnalysisRun) AND analysis_date=@NextDay AND status='SUCCEEDED' AND captured_row_count=0) THROW 58920,'Unexpected analysis date or source range: HighResourceSqlAnalysisRun.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LoginFailedAnalysisRun WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.LoginFailedAnalysisRun) AND analysis_date=@NextDay AND status='SUCCEEDED' AND failed_login_count=0) THROW 58920,'Unexpected analysis date or source range: LoginFailedAnalysisRun.',1;
IF (SELECT COUNT(*) FROM {{schema}}.LoginFailed WHERE analysis_date=@Today)<>4
 OR (SELECT COUNT(*) FROM {{schema}}.LongRunningSql WHERE analysis_date=@Today)<>6
 OR (SELECT COUNT(*) FROM {{schema}}.LoginFailed WHERE analysis_date=@Past)<>1
 OR (SELECT COUNT(*) FROM {{schema}}.LongRunningSql WHERE analysis_date=@Past)<>2
 THROW 58927,'Midnight rollover changed earlier dates.',1;
DECLARE @Future date=DATEADD(DAY,1,@NextDay);
BEGIN TRY
 EXEC {{schema}}.usp_AnalyzeWhoIsActiveBlocking @AnalysisDate=@Future,@ReturnResults=0;
 THROW 58928,'A future date was accepted.',1;
END TRY
BEGIN CATCH
 IF ERROR_NUMBER()<>54001 THROW;
END CATCH;
BEGIN TRY
 EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @AnalysisDate=@Future,@ReturnResults=0;
 THROW 58928,'A future date was accepted.',1;
END TRY
BEGIN CATCH
 IF ERROR_NUMBER()<>58001 THROW;
END CATCH;
BEGIN TRY
 EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @AnalysisDate=@Future,@ReturnResults=0;
 THROW 58928,'A future date was accepted.',1;
END TRY
BEGIN CATCH
 IF ERROR_NUMBER()<>58301 THROW;
END CATCH;
BEGIN TRY
 EXEC {{schema}}.usp_AnalyzeLoginFailed @AnalysisDate=@Future,@ReturnResults=0;
 THROW 58928,'A future date was accepted.',1;
END TRY
BEGIN CATCH
 IF ERROR_NUMBER()<>56001 THROW;
END CATCH;
DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS;
