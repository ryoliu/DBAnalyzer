USE MS_PERF_COLLECTION;
GO
IF OBJECT_ID(N'analyzer.LongRunningSqlAnalysisRun',N'U') IS NULL
 CREATE TABLE analyzer.LongRunningSqlAnalysisRun(
  analysis_run_id bigint IDENTITY PRIMARY KEY,
  analysis_date date NOT NULL,
  min_duration_seconds int NOT NULL,
  started_at_utc datetime2(3) NOT NULL,
  completed_at_utc datetime2(3) NULL,
  source_server nvarchar(128) NOT NULL,
  source_time_at_start datetimeoffset(3) NOT NULL,
  status varchar(10) NOT NULL CHECK(status IN('RUNNING','SUCCEEDED','FAILED')),
  captured_row_count bigint NULL,
  request_count int NULL,
  error_number int NULL,
  error_message nvarchar(4000) NULL);
GO
IF OBJECT_ID(N'analyzer.LongRunningSql',N'U') IS NULL
BEGIN
 CREATE TABLE analyzer.LongRunningSql(
  long_running_sql_id bigint IDENTITY PRIMARY KEY,
  analysis_run_id bigint NOT NULL REFERENCES analyzer.LongRunningSqlAnalysisRun(analysis_run_id),
  analysis_date date NOT NULL,
  session_id smallint NOT NULL,
  login_time datetime NOT NULL,
  request_id int NOT NULL,
  request_start_time datetime NOT NULL,
  first_observed_time datetime NOT NULL,
  last_observed_time datetime NOT NULL,
  observed_sample_count int NOT NULL,
  max_elapsed_seconds decimal(20,3) NOT NULL,
  database_name nvarchar(128) NULL,
  login_name nvarchar(128) NULL,
  host_name nvarchar(128) NULL,
  program_name nvarchar(128) NULL,
  last_status varchar(30) NULL,
  last_wait_info nvarchar(4000) NULL,
  last_blocking_session_id smallint NULL,
  last_sql_text nvarchar(max) NULL,
  last_sql_command nvarchar(max) NULL);
 CREATE UNIQUE INDEX UX_LongRunningSql_Request ON analyzer.LongRunningSql
  (analysis_date,session_id,login_time,request_id,request_start_time);
END;
GO
CREATE OR ALTER PROCEDURE analyzer.usp_AnalyzeWhoIsActiveLongRunning
 @AnalysisDate date=NULL,
 @MinDurationSeconds int=300,
 @ReturnResults bit=1,
 @AnalysisRunId bigint=NULL OUTPUT
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 SET @AnalysisRunId=NULL;
 IF @@TRANCOUNT<>0 THROW 58000,'Execute outside an existing transaction.',1;
 DECLARE @RunTime datetime = GETDATE();
 SET @AnalysisDate=COALESCE(@AnalysisDate,CONVERT(date,@RunTime));
 IF @AnalysisDate>CONVERT(date,@RunTime) THROW 58001,'AnalysisDate must not be in the future.',1;
 IF @MinDurationSeconds IS NULL OR @MinDurationSeconds<1
  THROW 58002,'MinDurationSeconds must be positive.',1;
 DECLARE @FromTime datetime=CONVERT(datetime,@AnalysisDate),
         @ToTime datetime=DATEADD(DAY,1,CONVERT(datetime,@AnalysisDate));
 IF @ToTime>@RunTime SET @ToTime=@RunTime;
 BEGIN TRY
  INSERT analyzer.LongRunningSqlAnalysisRun(analysis_date,min_duration_seconds,
   started_at_utc,source_server,source_time_at_start,status)
  VALUES(@AnalysisDate,@MinDurationSeconds,SYSUTCDATETIME(),
   CONVERT(nvarchar(128),SERVERPROPERTY('ServerName')),SYSDATETIMEOFFSET(),'RUNNING');
  SET @AnalysisRunId=CONVERT(bigint,SCOPE_IDENTITY());

  -- Exclude idle sessions and system background activity.
  SELECT collection_time,session_id,login_time,request_id,start_time,
   database_name,login_name,host_name,program_name,status,wait_info,blocking_session_id,
   DATEDIFF_BIG(MILLISECOND,start_time,collection_time) AS elapsed_ms,
   COALESCE(NULLIF(sql_text.value('(processing-instruction("query"))[1]','nvarchar(max)'),N''),
    NULLIF(sql_text.value('.','nvarchar(max)'),N''),CONVERT(nvarchar(max),sql_text)) AS sql_text,
   COALESCE(NULLIF(sql_command.value('(processing-instruction("query"))[1]','nvarchar(max)'),N''),
    NULLIF(sql_command.value('.','nvarchar(max)'),N''),CONVERT(nvarchar(max),sql_command)) AS sql_command
  INTO #Capture
  FROM dbo.WHOISACTIVE
  WHERE collection_time>=@FromTime AND collection_time<@ToTime
   AND session_id>50 AND login_time IS NOT NULL AND request_id IS NOT NULL
   AND status NOT IN('sleeping','dormant','background') AND start_time<=collection_time;

  BEGIN TRANSACTION;
  DELETE analyzer.LongRunningSql WHERE analysis_date=@AnalysisDate;

  -- Summarize each request and keep those reaching the duration threshold.
  SELECT session_id,login_time,request_id,start_time,
   MIN(collection_time) AS first_seen,MAX(collection_time) AS last_seen,
   COUNT(DISTINCT collection_time) AS sample_count,MAX(elapsed_ms) AS max_elapsed_ms
  INTO #Requests
  FROM #Capture
  GROUP BY session_id,login_time,request_id,start_time
  HAVING MAX(elapsed_ms)>=CONVERT(bigint,@MinDurationSeconds)*1000;

  -- Rank samples so the latest request details can be selected once.
  SELECT *,ROW_NUMBER() OVER(
   PARTITION BY session_id,login_time,request_id,start_time
   ORDER BY collection_time DESC) AS sample_rank
  INTO #LatestSamples
  FROM #Capture;

  INSERT analyzer.LongRunningSql(analysis_run_id,analysis_date,session_id,login_time,
   request_id,request_start_time,first_observed_time,last_observed_time,
   observed_sample_count,max_elapsed_seconds,database_name,login_name,host_name,
   program_name,last_status,last_wait_info,last_blocking_session_id,last_sql_text,last_sql_command)
  SELECT @AnalysisRunId,@AnalysisDate,r.session_id,r.login_time,r.request_id,r.start_time,
   r.first_seen,r.last_seen,r.sample_count,CONVERT(decimal(20,3),r.max_elapsed_ms/1000.0),
   l.database_name,l.login_name,l.host_name,l.program_name,l.status,l.wait_info,
   l.blocking_session_id,l.sql_text,l.sql_command
  FROM #Requests r JOIN #LatestSamples l ON l.session_id=r.session_id AND l.login_time=r.login_time
   AND l.request_id=r.request_id AND l.start_time=r.start_time AND l.sample_rank=1;

  UPDATE analyzer.LongRunningSqlAnalysisRun
  SET request_count=@@ROWCOUNT,captured_row_count=(SELECT COUNT_BIG(*) FROM #Capture),
   completed_at_utc=SYSUTCDATETIME(),status='SUCCEEDED'
  WHERE analysis_run_id=@AnalysisRunId;
  COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
  UPDATE analyzer.LongRunningSqlAnalysisRun SET status='FAILED',completed_at_utc=SYSUTCDATETIME(),
   error_number=ERROR_NUMBER(),error_message=ERROR_MESSAGE()
  WHERE analysis_run_id=@AnalysisRunId;
  THROW;
 END CATCH;
 IF @ReturnResults=1
 BEGIN
  SELECT * FROM analyzer.LongRunningSqlAnalysisRun WHERE analysis_run_id=@AnalysisRunId;
  SELECT * FROM analyzer.LongRunningSql WHERE analysis_run_id=@AnalysisRunId
   ORDER BY max_elapsed_seconds DESC;
 END;
END;
GO
