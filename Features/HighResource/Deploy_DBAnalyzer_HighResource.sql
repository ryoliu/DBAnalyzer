USE master;
GO
IF DB_ID(N'DBAnalyzer') IS NULL EXEC(N'CREATE DATABASE [DBAnalyzer]');
GO
USE DBAnalyzer;
GO
IF OBJECT_ID(N'dbo.HighResourceSqlAnalysisRun',N'U') IS NULL
 CREATE TABLE dbo.HighResourceSqlAnalysisRun(
  analysis_run_id bigint IDENTITY PRIMARY KEY,
  analysis_date date NOT NULL,
  top_n int NOT NULL,
  started_at_utc datetime2(3) NOT NULL,
  completed_at_utc datetime2(3) NULL,
  source_server nvarchar(128) NOT NULL,
  source_time_at_start datetimeoffset(3) NOT NULL,
  status varchar(10) NOT NULL CHECK(status IN('RUNNING','SUCCEEDED','FAILED')),
  captured_row_count bigint NULL,
  unparsed_counter_rows bigint NULL,
  request_count int NULL,
  error_number int NULL,
  error_message nvarchar(4000) NULL);
GO
IF OBJECT_ID(N'dbo.HighResourceSql',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.HighResourceSql(
  high_resource_sql_id bigint IDENTITY PRIMARY KEY,
  analysis_run_id bigint NOT NULL REFERENCES dbo.HighResourceSqlAnalysisRun(analysis_run_id),
  analysis_date date NOT NULL,
  session_id smallint NOT NULL,
  login_time datetime NOT NULL,
  request_id int NOT NULL,
  request_start_time datetime NOT NULL,
  first_observed_time datetime NOT NULL,
  last_observed_time datetime NOT NULL,
  observed_sample_count int NOT NULL,
  max_cpu_ms bigint NULL,
  max_logical_reads bigint NULL,
  cpu_rank bigint NULL,
  logical_reads_rank bigint NULL,
  database_name nvarchar(128) NULL,
  login_name nvarchar(128) NULL,
  host_name nvarchar(128) NULL,
  program_name nvarchar(128) NULL,
  last_status varchar(30) NULL,
  last_wait_info nvarchar(4000) NULL,
  last_sql_text nvarchar(max) NULL,
  last_sql_command nvarchar(max) NULL);
 CREATE UNIQUE INDEX UX_HighResourceSql_Request ON dbo.HighResourceSql
  (analysis_date,session_id,login_time,request_id,request_start_time);
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_AnalyzeWhoIsActiveHighResource
 @AnalysisDate date=NULL,
 @TopN int=20,
 @ReturnResults bit=1,
 @AnalysisRunId bigint=NULL OUTPUT
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 SET @AnalysisRunId=NULL;
 IF @@TRANCOUNT<>0 THROW 58300,'Execute outside an existing transaction.',1;
 SET @AnalysisDate=COALESCE(@AnalysisDate,CONVERT(date,DATEADD(DAY,-1,GETDATE())));
 IF @AnalysisDate>CONVERT(date,GETDATE()) THROW 58301,'AnalysisDate must not be in the future.',1;
 IF @TopN IS NULL OR @TopN<1 THROW 58302,'TopN must be positive.',1;
 DECLARE @FromTime datetime=CONVERT(datetime,@AnalysisDate),
         @ToTime datetime=DATEADD(DAY,1,CONVERT(datetime,@AnalysisDate));
 BEGIN TRY
  INSERT dbo.HighResourceSqlAnalysisRun(analysis_date,top_n,started_at_utc,
   source_server,source_time_at_start,status)
  VALUES(@AnalysisDate,@TopN,SYSUTCDATETIME(),
   CONVERT(nvarchar(128),SERVERPROPERTY('ServerName')),SYSDATETIMEOFFSET(),'RUNNING');
  SET @AnalysisRunId=CONVERT(bigint,SCOPE_IDENTITY());

  -- Convert formatted counters without treating missing values as zero.
  SELECT collection_time,session_id,login_time,request_id,start_time,
   database_name,login_name,host_name,program_name,status,wait_info,
   TRY_CONVERT(bigint,NULLIF(REPLACE(LTRIM(RTRIM(CPU)),',',''),'')) AS cpu_ms,
   TRY_CONVERT(bigint,NULLIF(REPLACE(LTRIM(RTRIM(reads)),',',''),'')) AS logical_reads,
   COALESCE(NULLIF(sql_text.value('(processing-instruction("query"))[1]','nvarchar(max)'),N''),
    NULLIF(sql_text.value('.','nvarchar(max)'),N''),CONVERT(nvarchar(max),sql_text)) AS sql_text,
   COALESCE(NULLIF(sql_command.value('(processing-instruction("query"))[1]','nvarchar(max)'),N''),
    NULLIF(sql_command.value('.','nvarchar(max)'),N''),CONVERT(nvarchar(max),sql_command)) AS sql_command
  INTO #Capture
  FROM MS_PERF_COLLECTION.dbo.WHOISACTIVE
  WHERE collection_time>=@FromTime AND collection_time<@ToTime
   AND session_id>50 AND login_time IS NOT NULL AND request_id IS NOT NULL
   AND status NOT IN('sleeping','dormant','background') AND start_time<=collection_time;
  UPDATE #Capture SET cpu_ms=NULL WHERE cpu_ms<0;
  UPDATE #Capture SET logical_reads=NULL WHERE logical_reads<0;

  BEGIN TRANSACTION;
  DELETE dbo.HighResourceSql WHERE analysis_date=@AnalysisDate;

  -- Counters are cumulative per request. Use MAX, never SUM across samples.
  SELECT session_id,login_time,request_id,start_time,
   MIN(collection_time) AS first_seen,MAX(collection_time) AS last_seen,
   COUNT(DISTINCT collection_time) AS sample_count,
   MAX(cpu_ms) AS max_cpu_ms,MAX(logical_reads) AS max_logical_reads
  INTO #Requests
  FROM #Capture
  GROUP BY session_id,login_time,request_id,start_time;

  -- Rank positive counters separately for CPU and logical reads.
  SELECT *,
   CASE WHEN max_cpu_ms>0 THEN ROW_NUMBER() OVER(ORDER BY max_cpu_ms DESC,
    session_id,login_time,request_id,start_time) END AS cpu_rank,
   CASE WHEN max_logical_reads>0 THEN ROW_NUMBER() OVER(ORDER BY max_logical_reads DESC,
    session_id,login_time,request_id,start_time) END AS logical_reads_rank
  INTO #RankedRequests
  FROM #Requests;

  -- Select the last observed statement and connection details for each request.
  SELECT *,ROW_NUMBER() OVER(
   PARTITION BY session_id,login_time,request_id,start_time
   ORDER BY collection_time DESC) AS sample_rank
  INTO #LatestSamples
  FROM #Capture;

  INSERT dbo.HighResourceSql(analysis_run_id,analysis_date,session_id,login_time,
   request_id,request_start_time,first_observed_time,last_observed_time,observed_sample_count,
   max_cpu_ms,max_logical_reads,cpu_rank,logical_reads_rank,database_name,login_name,
   host_name,program_name,last_status,last_wait_info,last_sql_text,last_sql_command)
  SELECT @AnalysisRunId,@AnalysisDate,r.session_id,r.login_time,r.request_id,r.start_time,
   r.first_seen,r.last_seen,r.sample_count,r.max_cpu_ms,r.max_logical_reads,
   r.cpu_rank,r.logical_reads_rank,l.database_name,l.login_name,l.host_name,
   l.program_name,l.status,l.wait_info,l.sql_text,l.sql_command
  FROM #RankedRequests r JOIN #LatestSamples l ON l.session_id=r.session_id AND l.login_time=r.login_time
   AND l.request_id=r.request_id AND l.start_time=r.start_time AND l.sample_rank=1
  WHERE r.cpu_rank<=@TopN OR r.logical_reads_rank<=@TopN;

  UPDATE dbo.HighResourceSqlAnalysisRun
  SET request_count=@@ROWCOUNT,captured_row_count=(SELECT COUNT_BIG(*) FROM #Capture),
   unparsed_counter_rows=(SELECT COUNT_BIG(*) FROM #Capture WHERE cpu_ms IS NULL OR logical_reads IS NULL),
   completed_at_utc=SYSUTCDATETIME(),status='SUCCEEDED'
  WHERE analysis_run_id=@AnalysisRunId;
  COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
  UPDATE dbo.HighResourceSqlAnalysisRun SET status='FAILED',completed_at_utc=SYSUTCDATETIME(),
   error_number=ERROR_NUMBER(),error_message=ERROR_MESSAGE()
  WHERE analysis_run_id=@AnalysisRunId;
  THROW;
 END CATCH;
 IF @ReturnResults=1
 BEGIN
  SELECT * FROM dbo.HighResourceSqlAnalysisRun WHERE analysis_run_id=@AnalysisRunId;
  SELECT * FROM dbo.HighResourceSql WHERE analysis_run_id=@AnalysisRunId AND cpu_rank<=@TopN
   ORDER BY cpu_rank;
  SELECT * FROM dbo.HighResourceSql WHERE analysis_run_id=@AnalysisRunId AND logical_reads_rank<=@TopN
   ORDER BY logical_reads_rank;
 END;
END;
GO
