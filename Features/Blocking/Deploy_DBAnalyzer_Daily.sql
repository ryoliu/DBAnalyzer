USE master;
GO
IF DB_ID(N'DBAnalyzer') IS NULL EXEC(N'CREATE DATABASE [DBAnalyzer]');
GO
USE DBAnalyzer;
GO
IF OBJECT_ID(N'dbo.BlockingAnalysisRun',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.BlockingAnalysisRun(
 analysis_run_id bigint IDENTITY PRIMARY KEY,
 started_at_utc datetime2(3) NOT NULL, completed_at_utc datetime2(3) NULL,
 source_server nvarchar(128) NOT NULL, source_time_at_start datetimeoffset(3) NOT NULL,
 requested_from_time datetime NULL, requested_to_time datetime NULL,
 max_sample_gap_seconds int NOT NULL, status varchar(10) NOT NULL,
 captured_row_count bigint NULL,captured_sample_count int NULL,
 first_sample datetime NULL,last_sample datetime NULL,
 blocked_request_observations bigint NULL,incident_count int NULL,
 error_number int NULL,error_message nvarchar(4000) NULL,
 CHECK(status IN ('RUNNING','SUCCEEDED','FAILED')));
END;
GO
IF OBJECT_ID(N'dbo.BlockingIncident',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.BlockingIncident(
 analysis_run_id bigint NOT NULL REFERENCES dbo.BlockingAnalysisRun(analysis_run_id),
 incident_id bigint NOT NULL,start_time datetime NOT NULL,end_time datetime NULL,
 last_observed_time datetime NOT NULL,observed_duration_seconds decimal(20,6) NOT NULL,
 boundary_observed_at datetime NULL,end_status varchar(24) NOT NULL,
 starts_at_window_boundary bit NOT NULL,blocker_session_id int NOT NULL,
 blocker_login_time datetime NULL,resolution_status varchar(24) NOT NULL,
 observed_sample_count int NOT NULL,victim_count int NOT NULL,victim_sessions nvarchar(max) NULL,
 blocker_database_name nvarchar(128) NULL,blocker_login_name nvarchar(128) NULL,
 blocker_host_name nvarchar(128) NULL,blocker_program_name nvarchar(128) NULL,
 blocker_sql nvarchar(max) NULL,blocker_batch nvarchar(max) NULL,
 PRIMARY KEY(analysis_run_id,incident_id));
 CREATE INDEX IX_BlockingIncident_Start ON dbo.BlockingIncident(start_time,blocker_session_id);
END;
GO
IF OBJECT_ID(N'dbo.BlockingDetail',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.BlockingDetail(
 blocking_detail_id bigint IDENTITY PRIMARY KEY,analysis_run_id bigint NOT NULL,
 incident_id bigint NOT NULL,collection_time datetime NOT NULL,
 root_blocker_session_id int NOT NULL,root_blocker_login_time datetime NULL,
 direct_blocker_session_id int NOT NULL,direct_blocker_login_time datetime NULL,
 victim_session_id int NOT NULL,victim_login_time datetime NULL,victim_request_id int NULL,
 victim_request_start_time datetime NULL,victim_database_name nvarchar(128) NULL,
 victim_login_name nvarchar(128) NULL,victim_host_name nvarchar(128) NULL,
 victim_program_name nvarchar(128) NULL,victim_status varchar(30) NULL,wait_info nvarchar(4000) NULL,
 blocking_chain varchar(max) NOT NULL,resolution_status varchar(24) NOT NULL,
 victim_sql nvarchar(max) NULL,victim_batch nvarchar(max) NULL,
 direct_blocker_sql nvarchar(max) NULL,direct_blocker_batch nvarchar(max) NULL,
 root_blocker_sql nvarchar(max) NULL,root_blocker_batch nvarchar(max) NULL,
 FOREIGN KEY(analysis_run_id,incident_id) REFERENCES dbo.BlockingIncident(analysis_run_id,incident_id));
 CREATE INDEX IX_BlockingDetail_Incident ON dbo.BlockingDetail(analysis_run_id,incident_id,collection_time);
END;
GO

IF COL_LENGTH('dbo.BlockingAnalysisRun','run_mode') IS NULL
 ALTER TABLE dbo.BlockingAnalysisRun ADD run_mode varchar(12) NOT NULL DEFAULT('LEGACY');
GO
IF COL_LENGTH('dbo.BlockingAnalysisRun','analysis_date') IS NULL
 ALTER TABLE dbo.BlockingAnalysisRun ADD analysis_date date NULL,
 is_current_daily bit NOT NULL CONSTRAINT DF_Run_CurrentDaily DEFAULT(0);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.BlockingAnalysisRun') AND name='UX_Run_DailyDate')
 CREATE UNIQUE INDEX UX_Run_DailyDate ON dbo.BlockingAnalysisRun(analysis_date) WHERE is_current_daily=1;
GO
CREATE OR ALTER VIEW dbo.vBlockingIncident
AS
 SELECT i.*,r.analysis_date FROM dbo.BlockingIncident i
 JOIN dbo.BlockingAnalysisRun r ON r.analysis_run_id=i.analysis_run_id
 WHERE r.run_mode='DAILY' AND r.is_current_daily=1;
GO
CREATE OR ALTER VIEW dbo.vBlockingDetail
AS
 SELECT d.*,r.analysis_date FROM dbo.BlockingDetail d
 JOIN dbo.BlockingAnalysisRun r ON r.analysis_run_id=d.analysis_run_id
 WHERE r.run_mode='DAILY' AND r.is_current_daily=1;
GO

CREATE OR ALTER PROCEDURE dbo.usp_AnalyzeWhoIsActiveBlocking
 @AnalysisDate date = NULL,
 @ReturnResults bit = 1,
 @AnalysisRunId bigint = NULL OUTPUT
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 SET @AnalysisRunId=NULL;
 IF @@TRANCOUNT<>0 THROW 54000,'Execute outside an existing transaction.',1;
 SET @AnalysisDate=COALESCE(@AnalysisDate,CONVERT(date,DATEADD(DAY,-1,GETDATE())));
 IF @AnalysisDate>CONVERT(date,GETDATE()) THROW 54001,'AnalysisDate must not be in the future.',1;
 DECLARE @FromTime datetime=CONVERT(datetime,@AnalysisDate),
         @ToTime datetime=DATEADD(DAY,1,CONVERT(datetime,@AnalysisDate)),
         @MaxSampleGapSeconds int=90;
 BEGIN TRY
  INSERT dbo.BlockingAnalysisRun(started_at_utc,source_server,source_time_at_start,
      requested_from_time,requested_to_time,max_sample_gap_seconds,status,run_mode,analysis_date)
  VALUES(SYSUTCDATETIME(),CONVERT(nvarchar(128),SERVERPROPERTY('ServerName')),SYSDATETIMEOFFSET(),
      @FromTime,@ToTime,@MaxSampleGapSeconds,'RUNNING','DAILY',@AnalysisDate);
  SET @AnalysisRunId=CONVERT(bigint,SCOPE_IDENTITY());
DROP TABLE IF EXISTS #Capture;
DROP TABLE IF EXISTS #Samples;
DROP TABLE IF EXISTS #Sessions;
DROP TABLE IF EXISTS #Edges;
DROP TABLE IF EXISTS #Resolved;
DROP TABLE IF EXISTS #RootSamples;
DROP TABLE IF EXISTS #IncidentSamples;
DROP TABLE IF EXISTS #Incidents;
DROP TABLE IF EXISTS #Victims;

-- Copy once so later collection activity cannot change the analysis input.
-- Do not use NOLOCK: incomplete or duplicated samples can corrupt grouping.
SELECT collection_time, session_id, request_id, login_time, start_time,
       blocking_session_id, database_name, login_name, host_name, program_name,
       status, wait_info,
       COALESCE(NULLIF(sql_text.value('(processing-instruction("query"))[1]', 'nvarchar(max)'), N''),
                NULLIF(sql_text.value('.', 'nvarchar(max)'), N''),
                CONVERT(nvarchar(max), sql_text)) AS sql_text,
       COALESCE(NULLIF(sql_command.value('(processing-instruction("query"))[1]', 'nvarchar(max)'), N''),
                NULLIF(sql_command.value('.', 'nvarchar(max)'), N''),
                CONVERT(nvarchar(max), sql_command)) AS sql_command
INTO #Capture
FROM MS_PERF_COLLECTION.dbo.WHOISACTIVE
WHERE collection_time >= @FromTime AND collection_time < @ToTime
OPTION (RECOMPILE);

IF EXISTS(SELECT 1 FROM #Capture
 GROUP BY collection_time,session_id,login_time,request_id HAVING COUNT(*)>1)
 THROW 54003,'Duplicate source request observations.',1;

CREATE CLUSTERED INDEX CX_Capture ON #Capture(collection_time, session_id);

SELECT collection_time,
       ROW_NUMBER() OVER (ORDER BY collection_time) AS sample_no
INTO #Samples
FROM (SELECT DISTINCT collection_time FROM #Capture) AS s;
CREATE UNIQUE CLUSTERED INDEX CX_Samples ON #Samples(collection_time);

-- One representative request per session is used only to walk the chain.
-- All blocked requests remain in #Edges and in the detail result.
;WITH Ranked AS
(
    SELECT *, ROW_NUMBER() OVER
       (PARTITION BY collection_time, session_id
        ORDER BY CASE WHEN ISNULL(blocking_session_id, 0) <> 0 THEN 0 ELSE 1 END,
                 request_id, start_time) AS rn
    FROM #Capture
)
SELECT * INTO #Sessions FROM Ranked WHERE rn = 1;
CREATE UNIQUE CLUSTERED INDEX CX_Sessions ON #Sessions(collection_time, session_id);

SELECT IDENTITY(bigint, 1, 1) AS edge_id, c.*, s.sample_no
INTO #Edges
FROM #Capture AS c
JOIN #Samples AS s ON s.collection_time = c.collection_time
WHERE ISNULL(c.blocking_session_id, 0) <> 0;
CREATE UNIQUE CLUSTERED INDEX CX_Edges ON #Edges(edge_id);

;WITH Chain AS
(
    SELECT e.edge_id, e.collection_time,
           CONVERT(int, e.blocking_session_id) AS current_blocker,
           CONVERT(varchar(max), '/' + CONVERT(varchar(12), e.session_id) + '/') AS visited,
           CONVERT(varchar(max), CONVERT(varchar(12), e.session_id) + ' <- '
                   + CONVERT(varchar(12), e.blocking_session_id)) AS blocking_chain,
           0 AS depth
    FROM #Edges AS e
    UNION ALL
    SELECT c.edge_id, c.collection_time, CONVERT(int, p.blocking_session_id),
           CONVERT(varchar(max), c.visited + CONVERT(varchar(12), c.current_blocker) + '/'),
           CONVERT(varchar(max), c.blocking_chain + ' <- '
                   + CONVERT(varchar(12), p.blocking_session_id)), c.depth + 1
    FROM Chain AS c
    JOIN #Sessions AS p
      ON p.collection_time = c.collection_time AND p.session_id = c.current_blocker
    WHERE c.current_blocker > 0
      AND ISNULL(p.blocking_session_id, 0) <> 0
      AND CHARINDEX('/' + CONVERT(varchar(12), c.current_blocker) + '/', c.visited) = 0
      AND c.depth < 127
), LastNode AS
(
    SELECT *, ROW_NUMBER() OVER (PARTITION BY edge_id ORDER BY depth DESC) AS rn
    FROM Chain
)
SELECT c.edge_id, c.current_blocker AS root_blocker_session_id,
       p.login_time AS root_blocker_login_time,
       c.blocking_chain,
       CONVERT(varchar(24), CASE
           WHEN CHARINDEX('/' + CONVERT(varchar(12), c.current_blocker) + '/', c.visited) > 0
               THEN 'CYCLE'
           WHEN c.depth >= 127 AND ISNULL(p.blocking_session_id, 0) <> 0 THEN 'DEPTH_LIMIT'
           WHEN c.current_blocker < 0 THEN 'SPECIAL_BLOCKER'
           WHEN p.session_id IS NULL THEN 'BLOCKER_NOT_CAPTURED'
           ELSE 'RESOLVED' END) AS resolution_status
INTO #Resolved
FROM LastNode AS c
LEFT JOIN #Sessions AS p
  ON p.collection_time = c.collection_time AND p.session_id = c.current_blocker
WHERE c.rn = 1
OPTION (MAXRECURSION 128);
CREATE UNIQUE CLUSTERED INDEX CX_Resolved ON #Resolved(edge_id);

SELECT DISTINCT e.collection_time, e.sample_no,
       r.root_blocker_session_id, r.root_blocker_login_time, r.resolution_status
INTO #RootSamples
FROM #Edges AS e
JOIN #Resolved AS r ON r.edge_id = e.edge_id;

-- Split if the root disappears in any captured sample, the sampling gap is
-- too large, the root login changes, or chain resolution changes.
;WITH Previous AS
(
    SELECT *,
       LAG(sample_no) OVER
           (PARTITION BY root_blocker_session_id, root_blocker_login_time, resolution_status
            ORDER BY sample_no) AS previous_sample_no,
       LAG(collection_time) OVER
           (PARTITION BY root_blocker_session_id, root_blocker_login_time, resolution_status
            ORDER BY sample_no) AS previous_collection_time
    FROM #RootSamples
), Boundaries AS
(
    SELECT *, CASE
       WHEN previous_sample_no IS NULL OR sample_no <> previous_sample_no + 1
         OR collection_time > DATEADD(SECOND, @MaxSampleGapSeconds, previous_collection_time)
       THEN 1 ELSE 0 END AS new_incident
    FROM Previous
), Islands AS
(
    SELECT *, SUM(new_incident) OVER
       (PARTITION BY root_blocker_session_id, root_blocker_login_time, resolution_status
        ORDER BY sample_no ROWS UNBOUNDED PRECEDING) AS island_no
    FROM Boundaries
)
SELECT *, DENSE_RANK() OVER
    (ORDER BY root_blocker_session_id, root_blocker_login_time, resolution_status, island_no) AS incident_id
INTO #IncidentSamples
FROM Islands;

SELECT incident_id, root_blocker_session_id, root_blocker_login_time, resolution_status,
       MIN(collection_time) AS start_time, MAX(collection_time) AS last_observed_time,
       MIN(sample_no) AS first_sample_no, MAX(sample_no) AS last_sample_no,
       COUNT(*) AS observed_sample_count
INTO #Incidents
FROM #IncidentSamples
GROUP BY incident_id, root_blocker_session_id, root_blocker_login_time, resolution_status;

SELECT DISTINCT i.incident_id, e.session_id, e.login_time
INTO #Victims
FROM #IncidentSamples AS i
JOIN #Edges AS e ON e.collection_time = i.collection_time
JOIN #Resolved AS r ON r.edge_id = e.edge_id
 AND r.root_blocker_session_id = i.root_blocker_session_id
 AND (r.root_blocker_login_time = i.root_blocker_login_time
      OR (r.root_blocker_login_time IS NULL AND i.root_blocker_login_time IS NULL))
 AND r.resolution_status = i.resolution_status;

-- Summarize victims once per incident before joining the incident report.
SELECT incident_id, COUNT(*) AS victim_count,
       STRING_AGG(CONVERT(nvarchar(max), CONCAT(session_id, N'@',
           COALESCE(CONVERT(nvarchar(23), login_time, 121), N'unknown'))), N', ')
           WITHIN GROUP (ORDER BY session_id, login_time) AS victim_sessions
INTO #VictimSummary
FROM #Victims
GROUP BY incident_id;

-- Result 1: one row per incident. end_time is unknown for right-censored
-- incidents. Duration is the observed span, not the true blocking duration.
SELECT i.incident_id,
       i.start_time,
       CASE WHEN next_sample.collection_time <= DATEADD(SECOND, @MaxSampleGapSeconds, i.last_observed_time)
            THEN i.last_observed_time END AS end_time,
       i.last_observed_time,
       DATEDIFF_BIG(MILLISECOND, i.start_time, i.last_observed_time) / 1000.0 AS observed_duration_seconds,
       CASE WHEN next_sample.collection_time <= DATEADD(SECOND, @MaxSampleGapSeconds, i.last_observed_time)
            THEN next_sample.collection_time END AS boundary_observed_at,
       CASE WHEN next_sample.collection_time IS NULL THEN 'OPEN_OR_WINDOW_END'
            WHEN next_sample.collection_time > DATEADD(SECOND, @MaxSampleGapSeconds, i.last_observed_time)
                THEN 'SAMPLING_GAP'
            ELSE 'GROUP_ENDED' END AS end_status,
       CONVERT(bit, CASE WHEN i.first_sample_no = 1 THEN 1 ELSE 0 END) AS starts_at_window_boundary,
       i.root_blocker_session_id AS blocker_session_id,
       i.root_blocker_login_time AS blocker_login_time,
       i.resolution_status,
       i.observed_sample_count,
       ISNULL(v.victim_count, 0) AS victim_count, v.victim_sessions,
       b.database_name AS blocker_database_name,
       b.login_name AS blocker_login_name, b.host_name AS blocker_host_name,
       b.program_name AS blocker_program_name,
       b.sql_text AS blocker_sql, b.sql_command AS blocker_batch
INTO #IncidentResults
FROM #Incidents AS i
LEFT JOIN #Samples AS next_sample ON next_sample.sample_no = i.last_sample_no + 1
LEFT JOIN #VictimSummary AS v ON v.incident_id = i.incident_id
LEFT JOIN #Sessions AS b
  ON b.collection_time = i.start_time AND b.session_id = i.root_blocker_session_id
;

-- Result 2: every observed victim request, direct blocker, root and SQL.
-- A <- B <- C means A is blocked by B, which is blocked by C.
SELECT i.incident_id, e.collection_time,
       r.root_blocker_session_id, r.root_blocker_login_time,
       e.blocking_session_id AS direct_blocker_session_id,
       d.login_time AS direct_blocker_login_time,
       e.session_id AS victim_session_id, e.login_time AS victim_login_time,
       e.request_id AS victim_request_id, e.start_time AS victim_request_start_time,
       e.database_name AS victim_database_name, e.login_name AS victim_login_name,
       e.host_name AS victim_host_name, e.program_name AS victim_program_name,
       e.status AS victim_status, e.wait_info,
       r.blocking_chain, r.resolution_status,
       e.sql_text AS victim_sql, e.sql_command AS victim_batch,
       d.sql_text AS direct_blocker_sql, d.sql_command AS direct_blocker_batch,
       b.sql_text AS root_blocker_sql, b.sql_command AS root_blocker_batch
INTO #DetailResults
FROM #Edges AS e
JOIN #Resolved AS r ON r.edge_id = e.edge_id
JOIN #IncidentSamples AS i
  ON i.collection_time = e.collection_time
 AND i.root_blocker_session_id = r.root_blocker_session_id
 AND (i.root_blocker_login_time = r.root_blocker_login_time
      OR (i.root_blocker_login_time IS NULL AND r.root_blocker_login_time IS NULL))
 AND i.resolution_status = r.resolution_status
LEFT JOIN #Sessions AS d
  ON d.collection_time = e.collection_time AND d.session_id = e.blocking_session_id
LEFT JOIN #Sessions AS b
  ON b.collection_time = e.collection_time AND b.session_id = r.root_blocker_session_id
;



  -- Replace only this date. A failed replacement leaves the old report intact.
  BEGIN TRANSACTION;
  DELETE d FROM dbo.BlockingDetail d
   JOIN dbo.BlockingAnalysisRun r ON r.analysis_run_id=d.analysis_run_id
   WHERE r.run_mode='DAILY' AND r.analysis_date=@AnalysisDate AND r.is_current_daily=1;
  DELETE i FROM dbo.BlockingIncident i
   JOIN dbo.BlockingAnalysisRun r ON r.analysis_run_id=i.analysis_run_id
   WHERE r.run_mode='DAILY' AND r.analysis_date=@AnalysisDate AND r.is_current_daily=1;
  UPDATE dbo.BlockingAnalysisRun SET is_current_daily=0
   WHERE run_mode='DAILY' AND analysis_date=@AnalysisDate AND is_current_daily=1;
  INSERT dbo.BlockingIncident(
   analysis_run_id, incident_id, start_time, end_time,
   last_observed_time, observed_duration_seconds, boundary_observed_at, end_status,
   starts_at_window_boundary, blocker_session_id, blocker_login_time, resolution_status,
   observed_sample_count, victim_count, victim_sessions, blocker_database_name,
   blocker_login_name, blocker_host_name, blocker_program_name, blocker_sql,
   blocker_batch)
  SELECT
   @AnalysisRunId, incident_id, start_time, end_time,
   last_observed_time, observed_duration_seconds, boundary_observed_at, end_status,
   starts_at_window_boundary, blocker_session_id, blocker_login_time, resolution_status,
   observed_sample_count, victim_count, victim_sessions, blocker_database_name,
   blocker_login_name, blocker_host_name, blocker_program_name, blocker_sql,
   blocker_batch
  FROM #IncidentResults;
  INSERT dbo.BlockingDetail(
   analysis_run_id, incident_id, collection_time, root_blocker_session_id,
   root_blocker_login_time, direct_blocker_session_id, direct_blocker_login_time, victim_session_id,
   victim_login_time, victim_request_id, victim_request_start_time, victim_database_name,
   victim_login_name, victim_host_name, victim_program_name, victim_status,
   wait_info, blocking_chain, resolution_status, victim_sql,
   victim_batch, direct_blocker_sql, direct_blocker_batch, root_blocker_sql,
   root_blocker_batch)
  SELECT
   @AnalysisRunId, incident_id, collection_time, root_blocker_session_id,
   root_blocker_login_time, direct_blocker_session_id, direct_blocker_login_time, victim_session_id,
   victim_login_time, victim_request_id, victim_request_start_time, victim_database_name,
   victim_login_name, victim_host_name, victim_program_name, victim_status,
   wait_info, blocking_chain, resolution_status, victim_sql,
   victim_batch, direct_blocker_sql, direct_blocker_batch, root_blocker_sql,
   root_blocker_batch
  FROM #DetailResults;
  UPDATE dbo.BlockingAnalysisRun
   SET status='SUCCEEDED',completed_at_utc=SYSUTCDATETIME(),is_current_daily=1,
       captured_row_count=(SELECT COUNT_BIG(*) FROM #Capture),
       captured_sample_count=(SELECT COUNT(*) FROM #Samples),
       first_sample=(SELECT MIN(collection_time) FROM #Samples),
       last_sample=(SELECT MAX(collection_time) FROM #Samples),
       blocked_request_observations=(SELECT COUNT_BIG(*) FROM #DetailResults),
       incident_count=(SELECT COUNT(*) FROM #IncidentResults)
   WHERE analysis_run_id=@AnalysisRunId;
  COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
  IF @AnalysisRunId IS NOT NULL
   UPDATE dbo.BlockingAnalysisRun
    SET status='FAILED',completed_at_utc=SYSUTCDATETIME(),
        error_number=ERROR_NUMBER(),error_message=ERROR_MESSAGE()
    WHERE analysis_run_id=@AnalysisRunId;
  THROW;
 END CATCH;
 IF @ReturnResults=1
 BEGIN
  SELECT * FROM dbo.BlockingAnalysisRun WHERE analysis_run_id=@AnalysisRunId;
  SELECT * FROM dbo.vBlockingIncident WHERE analysis_run_id=@AnalysisRunId ORDER BY start_time,incident_id;
  SELECT * FROM dbo.vBlockingDetail WHERE analysis_run_id=@AnalysisRunId ORDER BY incident_id,collection_time,victim_session_id;
 END;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_PurgeBlockingAnalysis
 @RetentionDays int=30
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 IF @@TRANCOUNT<>0 THROW 54100,'Execute outside an existing transaction.',1;
 IF @RetentionDays IS NULL OR @RetentionDays<1 THROW 54101,'RetentionDays must be positive.',1;
 DECLARE @CutoffDate date=DATEADD(DAY,-@RetentionDays,CONVERT(date,GETDATE()));
 BEGIN TRY
  BEGIN TRANSACTION;
  DELETE d FROM dbo.BlockingDetail d JOIN dbo.BlockingAnalysisRun r ON r.analysis_run_id=d.analysis_run_id
   WHERE r.run_mode='DAILY' AND r.analysis_date<@CutoffDate;
  DELETE i FROM dbo.BlockingIncident i JOIN dbo.BlockingAnalysisRun r ON r.analysis_run_id=i.analysis_run_id
   WHERE r.run_mode='DAILY' AND r.analysis_date<@CutoffDate;
  DELETE FROM dbo.BlockingAnalysisRun WHERE run_mode='DAILY' AND analysis_date<@CutoffDate;
  COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH;
END;
GO
