-- Run through Test_HighResourceSQL.ps1; {{schema}} is an isolated tempdb schema.
SET NOCOUNT ON;
DECLARE @Day date=DATEADD(DAY,-1,CONVERT(date,GETDATE()));
DECLARE @Midnight datetime=CONVERT(datetime,@Day),@RunId bigint;

-- Counters are strings. Two samples of request 101 must use MAX, not SUM.
INSERT {{schema}}.WHOISACTIVE(collection_time,session_id,login_time,request_id,start_time,
    status,CPU,reads,database_name,login_name,host_name,program_name,wait_info,sql_text,sql_command)
SELECT DATEADD(SECOND,v.sample_second,@Midnight),v.session_id,
    DATEADD(SECOND,v.login_second,@Midnight),v.request_id,DATEADD(SECOND,v.start_second,@Midnight),
    'running',v.cpu,v.reads,N'TestDatabase',N'TestLogin',N'TestHost',N'TestProgram',N'TestWait',
    CONVERT(xml,CASE WHEN v.sample_second=120 THEN N'<?query SELECT 2;?>' ELSE N'<query>SELECT 1;</query>' END),
    CONVERT(xml,N'<?query EXEC TestCommand;?>')
FROM (VALUES
    (101,-60,1, 0, 60,' 9,000 ','100'),
    (101,-60,1, 0,120,'8,000','90'),
    (102,-60,1, 0, 60,'100','9,000'),
    (103,-60,1, 0, 60,'0','0'),
    (104,-60,1, 0, 60,'invalid','300'),
    (105,-60,1, 0, 60,'-1','-1'),
    (106,-60,1, 0, 60,'9,000','100'),
    (101,-60,1,60,120,'500','500'),
    (101,-120,1,0,60,'400','400'),
    (101,-60,2, 0, 60,'300','300'),
    (107,-60,1, 0, 60,NULL,'250'),
    (108,-60,1, 0, 60,' ','200'),
    (109,-60,1, 0, 60,'9223372036854775808','150')
) v(session_id,login_second,request_id,start_second,sample_second,cpu,reads);

-- Each row below must be excluded despite its large counters.
INSERT {{schema}}.WHOISACTIVE(collection_time,session_id,login_time,request_id,start_time,status,CPU,reads)
SELECT DATEADD(SECOND,v.sample_second,@Midnight),v.session_id,
    DATEADD(SECOND,v.login_second,@Midnight),v.request_id,DATEADD(SECOND,v.start_second,@Midnight),
    v.status,'999,999','999,999'
FROM (VALUES
    (50, -60,1,0,60,'running'),
    (201,-60,1,0,60,'sleeping'),
    (202,-60,1,0,60,'dormant'),
    (203,-60,1,0,60,'background'),
    (204,NULL,1,0,60,'running'),
    (205,-60,NULL,0,60,'running'),
    (206,-60,1,120,60,'running'),
    (207,-60,1,0,-1,'running'),
    (208,-60,1,0,86400,'running')
) v(session_id,login_second,request_id,start_second,sample_second,status);

-- 1. Independent Top 1 lists produce a union of two requests.
EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @AnalysisDate=@Day,@TopN=1,@ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
IF (SELECT COUNT(*) FROM {{schema}}.HighResourceSql)<>2
    THROW 58950,'Top 1 union should contain two requests.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSql WHERE session_id=101
    AND max_cpu_ms=9000 AND max_logical_reads=100 AND cpu_rank=1 AND logical_reads_rank=9
    AND observed_sample_count=2 AND first_observed_time=DATEADD(SECOND,60,@Midnight)
    AND last_observed_time=DATEADD(SECOND,120,@Midnight)
    AND last_sql_text=N'SELECT 2;' AND last_sql_command=N'EXEC TestCommand;'
    AND database_name=N'TestDatabase' AND login_name=N'TestLogin' AND host_name=N'TestHost'
    AND program_name=N'TestProgram' AND last_status='running' AND last_wait_info=N'TestWait')
    THROW 58951,'MAX counters, sample range, tie order, or latest metadata is incorrect.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSql WHERE session_id=102 AND logical_reads_rank=1)
    THROW 58952,'The logical-read winner is incorrect.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSqlAnalysisRun WHERE analysis_run_id=@RunId
    AND status='SUCCEEDED' AND analysis_date=@Day AND top_n=1 AND captured_row_count=13
    AND unparsed_counter_rows=5 AND request_count=2 AND completed_at_utc IS NOT NULL)
    THROW 58953,'The analysis run counts are incorrect.',1;
SELECT 'PASS 1: Top 1 union, MAX counters, latest sample, exclusions, historical boundaries and run counts' test_result;

-- 2. Compare every expected request and both rankings.
DECLARE @Expected TABLE(session_id smallint,login_time datetime,request_id int,request_start_time datetime,
    max_cpu_ms bigint,max_logical_reads bigint,cpu_rank bigint,logical_reads_rank bigint,observed_sample_count int);
INSERT @Expected
SELECT session_id,DATEADD(SECOND,login_second,@Midnight),request_id,DATEADD(SECOND,start_second,@Midnight),
    cpu,reads,cpu_rank,reads_rank,samples
FROM (VALUES
    (101,-60, 1, 0,9000,100,1,9,2),
    (102,-60, 1, 0,100,9000,6,1,1),
    (104,-60, 1, 0,NULL,300,NULL,5,1),
    (106,-60, 1, 0,9000,100,2,10,1),
    (101,-60, 1,60,500,500,3,2,1),
    (101,-120,1, 0,400,400,4,3,1),
    (101,-60, 2, 0,300,300,5,4,1),
    (107,-60, 1, 0,NULL,250,NULL,6,1),
    (108,-60, 1, 0,NULL,200,NULL,7,1),
    (109,-60, 1, 0,NULL,150,NULL,8,1)
) v(session_id,login_second,request_id,start_second,cpu,reads,cpu_rank,reads_rank,samples);

EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @AnalysisDate=@Day,@TopN=20,@ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
IF EXISTS(SELECT * FROM @Expected EXCEPT
    SELECT session_id,login_time,request_id,request_start_time,max_cpu_ms,max_logical_reads,
        cpu_rank,logical_reads_rank,observed_sample_count FROM {{schema}}.HighResourceSql)
 OR EXISTS(SELECT session_id,login_time,request_id,request_start_time,max_cpu_ms,max_logical_reads,
        cpu_rank,logical_reads_rank,observed_sample_count FROM {{schema}}.HighResourceSql EXCEPT SELECT * FROM @Expected)
 OR (SELECT COUNT(*) FROM {{schema}}.HighResourceSql)<>10
    THROW 58954,'The complete request set or rankings differ from expected values.',1;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSql WHERE session_id=102 AND last_sql_text=N'SELECT 1;')
    THROW 58955,'Element XML text was not extracted.',1;
SELECT 'PASS 2: exact rankings, separate request identities, invalid counters, zero exclusion and XML text' test_result;

-- 3. Repeated execution replaces details and preserves run history.
EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @AnalysisDate=@Day,@TopN=1,@ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @AnalysisDate=@Day,@TopN=1,@ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
IF (SELECT COUNT(*) FROM {{schema}}.HighResourceSql)<>2
 OR EXISTS(SELECT 1 FROM {{schema}}.HighResourceSql WHERE analysis_run_id<>@RunId)
 OR (SELECT COUNT(*) FROM {{schema}}.HighResourceSqlAnalysisRun)<>4
    THROW 58956,'Repeated execution did not replace results correctly.',1;
SELECT 'PASS 3: changing Top N and repeating the same day replaces results without duplicates' test_result;

-- 4. An empty historical day succeeds without changing other dates.
DECLARE @EmptyDay date=DATEADD(DAY,-2,@Day);
EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @AnalysisDate=@EmptyDay,@ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
IF NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSqlAnalysisRun WHERE analysis_run_id=@RunId
    AND status='SUCCEEDED' AND captured_row_count=0 AND request_count=0 AND unparsed_counter_rows=0)
 OR (SELECT COUNT(*) FROM {{schema}}.HighResourceSql)<>2
    THROW 58957,'Empty-day analysis changed another date or returned incorrect counts.',1;
SELECT 'PASS 4: empty source succeeds and preserves other dates' test_result;

-- 5. Invalid inputs must raise the documented error numbers.
DECLARE @TopN int=0;
WHILE @TopN>=-1
BEGIN
    BEGIN TRY
        EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @TopN=@TopN,@ReturnResults=0;
        THROW 58958,'A nonpositive TopN was accepted.',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>58302 THROW;
    END CATCH;
    SET @TopN-=1;
END;
BEGIN TRY
    EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @TopN=NULL,@ReturnResults=0;
    THROW 58958,'A NULL TopN was accepted.',1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>58302 THROW;
END CATCH;
DECLARE @Future date=DATEADD(DAY,1,CONVERT(date,GETDATE()));
BEGIN TRY
    EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @AnalysisDate=@Future,@ReturnResults=0;
    THROW 58958,'A future date was accepted.',1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>58301 THROW;
END CATCH;
BEGIN TRANSACTION;
BEGIN TRY
    EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @ReturnResults=0;
    THROW 58958,'An existing transaction was accepted.',1;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
    IF ERROR_NUMBER()<>58300 THROW;
END CATCH;
IF (SELECT COUNT(*) FROM {{schema}}.HighResourceSql)<>2
 OR (SELECT COUNT(*) FROM {{schema}}.HighResourceSqlAnalysisRun)<>5
    THROW 58959,'Invalid inputs changed existing data.',1;
SELECT 'PASS 5: invalid TopN, future date and existing transaction are rejected without data changes' test_result;

-- 6. Force an insert failure after DELETE to verify transaction rollback.
ALTER TABLE {{schema}}.HighResourceSql ADD CHECK(session_id<>104);
BEGIN TRY
    EXEC {{schema}}.usp_AnalyzeWhoIsActiveHighResource @AnalysisDate=@Day,@TopN=20,@ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
    THROW 58958,'The forced insert failure did not occur.',1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>547 THROW;
END CATCH;
IF (SELECT COUNT(*) FROM {{schema}}.HighResourceSql)<>2
 OR NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSql WHERE session_id=101 AND cpu_rank=1)
 OR NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSql WHERE session_id=102 AND logical_reads_rank=1)
 OR NOT EXISTS(SELECT 1 FROM {{schema}}.HighResourceSqlAnalysisRun
    WHERE analysis_run_id=(SELECT MAX(analysis_run_id) FROM {{schema}}.HighResourceSqlAnalysisRun)
    AND status='FAILED' AND error_number=547 AND completed_at_utc IS NOT NULL)
    THROW 58959,'A failed analysis did not preserve the previous results or record the failure.',1;
SELECT 'PASS 6: insert failure rolls back result replacement and records FAILED status' test_result;
