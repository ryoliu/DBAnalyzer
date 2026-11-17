-- Run through Test_LongRunningSQL.ps1 in an isolated tempdb schema.
SET NOCOUNT ON;
DECLARE @Day date=DATEADD(DAY,-1,CONVERT(date,GETDATE())),@RunId bigint;
DECLARE @Midnight datetime=CONVERT(datetime,@Day);

-- Request 101 has four rows but only three distinct collection times.
INSERT {{schema}}.WHOISACTIVE(collection_time,session_id,login_time,request_id,start_time,
    status,wait_info,blocking_session_id,database_name,login_name,host_name,program_name,sql_text,sql_command)
SELECT DATEADD(MILLISECOND,v.sample_ms,@Midnight),v.session_id,
    DATEADD(SECOND,v.login_second,@Midnight),v.request_id,DATEADD(SECOND,v.start_second,@Midnight),
    CASE WHEN v.sample_ms=345393 THEN 'suspended' ELSE 'running' END,
    CASE WHEN v.sample_ms=345393 THEN N'LCK_M_S' ELSE NULL END,
    CASE WHEN v.sample_ms=345393 THEN 200 ELSE NULL END,
    N'TestDatabase',N'TestLogin',N'TestHost',N'TestProgram',
    CONVERT(xml,CASE WHEN v.sample_ms=345393 THEN N'<?query SELECT 2;?>' ELSE N'<query>SELECT 1;</query>' END),
    CONVERT(xml,N'<?query EXEC TestCommand;?>')
FROM (VALUES
    (101,-600, 1, 0,29000),
    (101,-600, 1, 0,29000),
    (101,-600, 1, 0,30000),
    (101,-600, 1, 0,345393),
    (102,-600, 1, 0,29997),
    (103,-600, 1, 0,30000),
    (104,-1200,1,-600,0),
    (101,-600, 2, 0,360000),
    (101,-1200,1, 0,400000),
    (101,-600, 1,60,420000),
    (105,-600, 1, 0,86399000)
) v(session_id,login_second,request_id,start_second,sample_ms);

-- These rows must be excluded regardless of duration.
INSERT {{schema}}.WHOISACTIVE(collection_time,session_id,login_time,request_id,start_time,status)
SELECT DATEADD(SECOND,v.sample_second,@Midnight),v.session_id,
    DATEADD(SECOND,v.login_second,@Midnight),v.request_id,DATEADD(SECOND,v.start_second,@Midnight),v.status
FROM (VALUES
    (50, -1200,1,0,600,'running'),
    (201,-1200,1,0,600,'sleeping'),
    (202,-1200,1,0,600,'dormant'),
    (203,-1200,1,0,600,'background'),
    (204,NULL, 1,0,600,'running'),
    (205,-1200,NULL,0,600,'running'),
    (206,-1200,1,900,600,'running'),
    (207,-1200,1,-600,-1,'running'),
    (208,-1200,1,0,86400,'running')
) v(session_id,login_second,request_id,start_second,sample_second,status);

-- 1. Default 30-second threshold and exact expected request set.
EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @AnalysisDate=@Day,@ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
DECLARE @Expected TABLE(session_id smallint,login_time datetime,request_id int,request_start_time datetime,
    max_elapsed_seconds decimal(20,3),observed_sample_count int);
INSERT @Expected
SELECT session_id,DATEADD(SECOND,login_second,@Midnight),request_id,DATEADD(SECOND,start_second,@Midnight),elapsed,samples
FROM (VALUES
    (101,-600, 1, 0,345.393,3),
    (103,-600, 1, 0,30.000,1),
    (104,-1200,1,-600,600.000,1),
    (101,-600, 2, 0,360.000,1),
    (101,-1200,1, 0,400.000,1),
    (101,-600, 1,60,360.000,1),
    (105,-600, 1, 0,86399.000,1)
) v(session_id,login_second,request_id,start_second,elapsed,samples);
IF (SELECT COUNT(*) FROM {{schema}}.LongRunningSql)<>7
 OR EXISTS(SELECT * FROM @Expected EXCEPT
    SELECT session_id,login_time,request_id,request_start_time,max_elapsed_seconds,observed_sample_count
    FROM {{schema}}.LongRunningSql)
 OR EXISTS(SELECT session_id,login_time,request_id,request_start_time,max_elapsed_seconds,observed_sample_count
    FROM {{schema}}.LongRunningSql EXCEPT SELECT * FROM @Expected)
    THROW 58960,'Request grouping, duration threshold, sample counts or exclusions are incorrect.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSqlAnalysisRun WHERE analysis_run_id=@RunId
    AND analysis_date=@Day AND min_duration_seconds=30 AND captured_row_count=11
    AND request_count=7 AND status='SUCCEEDED' AND completed_at_utc IS NOT NULL)
    THROW 58961,'Analysis run counts or status are incorrect.',1;
SELECT 'PASS 1: 29.997 excluded, 30 included, exact durations, request identities, duplicate samples and date boundaries' test_result;

-- 2. First observation includes samples before reaching the threshold.
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSql WHERE session_id=101 AND request_id=1
    AND login_time=DATEADD(SECOND,-600,@Midnight) AND request_start_time=@Midnight
    AND first_observed_time=DATEADD(SECOND,29,@Midnight)
    AND last_observed_time=DATEADD(MILLISECOND,345393,@Midnight)
    AND last_status='suspended' AND last_wait_info=N'LCK_M_S' AND last_blocking_session_id=200
    AND database_name=N'TestDatabase' AND login_name=N'TestLogin' AND host_name=N'TestHost'
    AND program_name=N'TestProgram' AND last_sql_text=N'SELECT 2;' AND last_sql_command=N'EXEC TestCommand;')
 OR NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSql WHERE session_id=103 AND last_sql_text=N'SELECT 1;')
    THROW 58962,'The observation range or latest sample details are incorrect.',1;
SELECT 'PASS 2: pre-threshold samples, latest SQL and connection details, blocking wait and XML text' test_result;

-- 3. Changing the threshold and repeating the date replaces details.
EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @AnalysisDate=@Day,@MinDurationSeconds=400,@ReturnResults=0;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @AnalysisDate=@Day,@MinDurationSeconds=400,@ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
IF (SELECT COUNT(*) FROM {{schema}}.LongRunningSql)<>3
 OR EXISTS(SELECT 1 FROM {{schema}}.LongRunningSql WHERE analysis_run_id<>@RunId OR max_elapsed_seconds<400)
 OR (SELECT COUNT(*) FROM {{schema}}.LongRunningSqlAnalysisRun)<>3
    THROW 58963,'Repeated analysis did not replace results or preserve run history.',1;
SELECT 'PASS 3: changing threshold and same-day rerun replace results without duplicates' test_result;

-- 4. Empty dates succeed and leave the previous report intact.
DECLARE @EmptyDay date=DATEADD(DAY,-2,@Day);
EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @AnalysisDate=@EmptyDay,@ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSqlAnalysisRun WHERE analysis_run_id=@RunId
    AND status='SUCCEEDED' AND captured_row_count=0 AND request_count=0)
 OR (SELECT COUNT(*) FROM {{schema}}.LongRunningSql)<>3
    THROW 58964,'Empty-date analysis changed existing results or returned incorrect counts.',1;
SELECT 'PASS 4: empty date succeeds and preserves other dates' test_result;

-- 5. Invalid parameters and an existing transaction must be rejected.
DECLARE @Minimum int=0;
WHILE @Minimum>=-1
BEGIN
    BEGIN TRY
        EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @MinDurationSeconds=@Minimum,@ReturnResults=0;
        THROW 58965,'A nonpositive duration was accepted.',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>58002 THROW;
    END CATCH;
    SET @Minimum-=1;
END;
BEGIN TRY
    EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @MinDurationSeconds=NULL,@ReturnResults=0;
    THROW 58965,'A NULL duration was accepted.',1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>58002 THROW;
END CATCH;
DECLARE @Future date=DATEADD(DAY,1,CONVERT(date,GETDATE()));
BEGIN TRY
    EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @AnalysisDate=@Future,@ReturnResults=0;
    THROW 58965,'A future date was accepted.',1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>58001 THROW;
END CATCH;
BEGIN TRANSACTION;
BEGIN TRY
    EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @ReturnResults=0;
    THROW 58965,'An existing transaction was accepted.',1;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
    IF ERROR_NUMBER()<>58000 THROW;
END CATCH;
IF (SELECT COUNT(*) FROM {{schema}}.LongRunningSql)<>3
 OR (SELECT COUNT(*) FROM {{schema}}.LongRunningSqlAnalysisRun)<>4
    THROW 58966,'Invalid inputs changed stored data.',1;
SELECT 'PASS 5: invalid duration, future date and existing transaction rejected without data changes' test_result;

-- 6. A failed replacement must restore the previous report.
DECLARE @PreviousRunId bigint=(SELECT MAX(analysis_run_id) FROM {{schema}}.LongRunningSql);
ALTER TABLE {{schema}}.LongRunningSql ADD CHECK(session_id<>103);
BEGIN TRY
    EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @AnalysisDate=@Day,@ReturnResults=0;
    THROW 58965,'The forced insert failure did not occur.',1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>547 THROW;
END CATCH;
IF (SELECT COUNT(*) FROM {{schema}}.LongRunningSql)<>3
 OR EXISTS(SELECT 1 FROM {{schema}}.LongRunningSql WHERE analysis_run_id<>@PreviousRunId)
 OR NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSqlAnalysisRun
    WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.LongRunningSqlAnalysisRun)
    AND status='FAILED' AND error_number=547 AND completed_at_utc IS NOT NULL)
    THROW 58967,'Failure did not restore the previous report or record FAILED status.',1;
SELECT 'PASS 6: failed insert rolls back replacement and records FAILED status' test_result;

-- 7. Freeze the clock at 00:10 to verify today's default and exact cutoff.
DECLARE @Today datetime=CONVERT(datetime,CONVERT(date,GETDATE()));
UPDATE {{schema}}.Clock SET run_time=DATEADD(SECOND,600,@Today);
INSERT {{schema}}.WHOISACTIVE(collection_time,session_id,login_time,request_id,start_time,status)
SELECT DATEADD(SECOND,v.sample_second,@Today),v.session_id,DATEADD(SECOND,-1200,@Today),1,
    DATEADD(SECOND,-600,@Today),'running'
FROM (VALUES(301,0),(302,599),(303,600),(304,601)) v(session_id,sample_second);
EXEC {{schema}}.usp_AnalyzeWhoIsActiveLongRunning @ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
-- Session 208 is the prior fixture's next-midnight observation, now in today's range.
IF NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSqlAnalysisRun WHERE analysis_run_id=@RunId
    AND analysis_date=CONVERT(date,@Today) AND captured_row_count=3 AND request_count=3 AND status='SUCCEEDED')
 OR NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSql WHERE analysis_run_id=@RunId AND session_id=301 AND max_elapsed_seconds=600)
 OR NOT EXISTS(SELECT 1 FROM {{schema}}.LongRunningSql WHERE analysis_run_id=@RunId AND session_id=302 AND max_elapsed_seconds=1199)
 OR EXISTS(SELECT 1 FROM {{schema}}.LongRunningSql WHERE analysis_run_id=@RunId AND session_id IN(303,304))
 OR (SELECT COUNT(*) FROM {{schema}}.LongRunningSql WHERE analysis_date=@Day)<>3
    THROW 58968,'Default date, midnight inclusion, cutoff exclusion or historical preservation is incorrect.',1;
SELECT 'PASS 7: current-day default, midnight inclusion, frozen cutoff and cross-midnight duration' test_result;
