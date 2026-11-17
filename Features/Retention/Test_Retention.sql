-- Run only against the lab server. All fixtures are isolated in tempdb.
USE tempdb;
GO
IF SCHEMA_ID(N'RetentionTest') IS NOT NULL THROW 58520, 'RetentionTest schema already exists.', 1;
EXEC(N'CREATE SCHEMA RetentionTest');
GO
SELECT TOP (0) * INTO RetentionTest.BlockingAnalysisRun FROM DBAnalyzer.dbo.BlockingAnalysisRun;
SELECT TOP (0) * INTO RetentionTest.BlockingIncident FROM DBAnalyzer.dbo.BlockingIncident;
SELECT TOP (0) * INTO RetentionTest.BlockingDetail FROM DBAnalyzer.dbo.BlockingDetail;
SELECT TOP (0) * INTO RetentionTest.HighResourceSqlAnalysisRun FROM DBAnalyzer.dbo.HighResourceSqlAnalysisRun;
SELECT TOP (0) * INTO RetentionTest.HighResourceSql FROM DBAnalyzer.dbo.HighResourceSql;
SELECT TOP (0) * INTO RetentionTest.LoginFailedAnalysisRun FROM DBAnalyzer.dbo.LoginFailedAnalysisRun;
SELECT TOP (0) * INTO RetentionTest.LoginFailed FROM DBAnalyzer.dbo.LoginFailed;
SELECT TOP (0) * INTO RetentionTest.LoginFailedSummary FROM DBAnalyzer.dbo.LoginFailedSummary;
SELECT TOP (0) * INTO RetentionTest.LongRunningSqlAnalysisRun FROM DBAnalyzer.dbo.LongRunningSqlAnalysisRun;
SELECT TOP (0) * INTO RetentionTest.LongRunningSql FROM DBAnalyzer.dbo.LongRunningSql;
SELECT TOP (0) * INTO RetentionTest.TableRowCountRun FROM DBAnalyzer.dbo.TableRowCountRun;
SELECT TOP (0) * INTO RetentionTest.TableRowCountSnapshot FROM DBAnalyzer.dbo.TableRowCountSnapshot;

DECLARE @Table sysname, @Columns nvarchar(max), @Sql nvarchar(max);
DECLARE TableKeys CURSOR LOCAL FAST_FORWARD FOR
 SELECT t.name, STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(c.name)), N',')
 WITHIN GROUP (ORDER BY ic.key_ordinal)
 FROM DBAnalyzer.sys.tables t JOIN DBAnalyzer.sys.indexes i ON i.object_id=t.object_id AND i.is_primary_key=1
 JOIN DBAnalyzer.sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id
 JOIN DBAnalyzer.sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
 WHERE t.name IN (N'BlockingAnalysisRun',N'BlockingIncident',N'BlockingDetail',N'HighResourceSqlAnalysisRun',N'HighResourceSql',N'LoginFailedAnalysisRun',N'LoginFailed',N'LoginFailedSummary',N'LongRunningSqlAnalysisRun',N'LongRunningSql',N'TableRowCountRun',N'TableRowCountSnapshot') AND ic.key_ordinal>0
 GROUP BY t.name;
OPEN TableKeys;
FETCH NEXT FROM TableKeys INTO @Table,@Columns;
WHILE @@FETCH_STATUS=0
BEGIN
 SET @Sql=N'ALTER TABLE RetentionTest.'+QUOTENAME(@Table)+N' ADD PRIMARY KEY ('+@Columns+N');';
 EXEC(@Sql);
 FETCH NEXT FROM TableKeys INTO @Table,@Columns;
END;
CLOSE TableKeys;
DEALLOCATE TableKeys;
ALTER TABLE RetentionTest.BlockingIncident ADD FOREIGN KEY (analysis_run_id) REFERENCES RetentionTest.BlockingAnalysisRun (analysis_run_id);
ALTER TABLE RetentionTest.BlockingDetail ADD FOREIGN KEY (analysis_run_id,incident_id) REFERENCES RetentionTest.BlockingIncident (analysis_run_id,incident_id);
ALTER TABLE RetentionTest.HighResourceSql ADD FOREIGN KEY (analysis_run_id) REFERENCES RetentionTest.HighResourceSqlAnalysisRun (analysis_run_id);
ALTER TABLE RetentionTest.LoginFailed ADD FOREIGN KEY (analysis_run_id) REFERENCES RetentionTest.LoginFailedAnalysisRun (analysis_run_id);
ALTER TABLE RetentionTest.LoginFailedSummary ADD FOREIGN KEY (analysis_run_id) REFERENCES RetentionTest.LoginFailedAnalysisRun (analysis_run_id);
ALTER TABLE RetentionTest.LongRunningSql ADD FOREIGN KEY (analysis_run_id) REFERENCES RetentionTest.LongRunningSqlAnalysisRun (analysis_run_id);
ALTER TABLE RetentionTest.TableRowCountSnapshot ADD FOREIGN KEY (capture_run_id) REFERENCES RetentionTest.TableRowCountRun (capture_run_id);
GO
CREATE OR ALTER PROCEDURE RetentionTest.usp_PurgeDBAnalyzerHistory
 @RetentionDays int = 30,
 @PreviewOnly bit = 1
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 IF @@TRANCOUNT <> 0 THROW 58500, 'Execute outside an existing transaction.', 1;
 IF @RetentionDays IS NULL OR @RetentionDays < 1 OR @RetentionDays > 36500
  THROW 58501, 'RetentionDays must be between 1 and 36500.', 1;
 IF @PreviewOnly IS NULL THROW 58502, 'PreviewOnly must be specified.', 1;
 DECLARE @KeepFromDate date = DATEADD(DAY, 1 - @RetentionDays, CONVERT(date, GETDATE())),
         @LockResult int;
 CREATE TABLE #Results (table_name sysname PRIMARY KEY, row_count bigint NOT NULL);
 BEGIN TRY
  BEGIN TRANSACTION;
  EXEC @LockResult = sys.sp_getapplock @Resource = N'DBAnalyzer.HistoryCleanup',
   @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 0, @DbPrincipal = N'public';
  IF @LockResult < 0 THROW 58503, 'Another history cleanup is running. Retry later.', 1;
  EXEC @LockResult = sys.sp_getapplock @Resource = N'DBAnalyzer.LoginFailed',
   @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 0, @DbPrincipal = N'public';
  IF @LockResult < 0 THROW 58504, 'Failed-login collection is running. Retry later.', 1;

  -- Hold the selected completed runs until all child rows and parent rows are processed.
  SELECT analysis_run_id INTO #BlockingRuns
  FROM RetentionTest.BlockingAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE COALESCE(analysis_date, CONVERT(date, source_time_at_start)) < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT analysis_run_id INTO #HighResourceRuns
  FROM RetentionTest.HighResourceSqlAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE analysis_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT analysis_run_id INTO #LoginFailedRuns
  FROM RetentionTest.LoginFailedAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE analysis_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT analysis_run_id INTO #LongRunningRuns
  FROM RetentionTest.LongRunningSqlAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE analysis_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT capture_run_id INTO #TableRowCountRuns
  FROM RetentionTest.TableRowCountRun WITH (UPDLOCK, HOLDLOCK)
  WHERE snapshot_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');


  IF EXISTS (SELECT 1 FROM RetentionTest.HighResourceSql d WITH (UPDLOCK, HOLDLOCK) JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF EXISTS (SELECT 1 FROM RetentionTest.LoginFailedSummary d WITH (UPDLOCK, HOLDLOCK) JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;
  IF EXISTS (SELECT 1 FROM RetentionTest.LoginFailed d WITH (UPDLOCK, HOLDLOCK) JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF EXISTS (SELECT 1 FROM RetentionTest.LongRunningSql d WITH (UPDLOCK, HOLDLOCK) JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF EXISTS (SELECT 1 FROM RetentionTest.TableRowCountSnapshot d WITH (UPDLOCK, HOLDLOCK) JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id
   WHERE d.snapshot_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF @PreviewOnly = 1
  BEGIN
   INSERT #Results SELECT N'BlockingDetail', COUNT_BIG(*)
   FROM RetentionTest.BlockingDetail d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'BlockingIncident', COUNT_BIG(*)
   FROM RetentionTest.BlockingIncident d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'BlockingAnalysisRun', COUNT_BIG(*)
   FROM RetentionTest.BlockingAnalysisRun d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'HighResourceSql', COUNT_BIG(*)
   FROM RetentionTest.HighResourceSql d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'HighResourceSqlAnalysisRun', COUNT_BIG(*)
   FROM RetentionTest.HighResourceSqlAnalysisRun d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LoginFailedSummary', COUNT_BIG(*)
   FROM RetentionTest.LoginFailedSummary d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LoginFailed', COUNT_BIG(*)
   FROM RetentionTest.LoginFailed d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LoginFailedAnalysisRun', COUNT_BIG(*)
   FROM RetentionTest.LoginFailedAnalysisRun d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LongRunningSql', COUNT_BIG(*)
   FROM RetentionTest.LongRunningSql d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LongRunningSqlAnalysisRun', COUNT_BIG(*)
   FROM RetentionTest.LongRunningSqlAnalysisRun d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'TableRowCountSnapshot', COUNT_BIG(*)
   FROM RetentionTest.TableRowCountSnapshot d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
   INSERT #Results SELECT N'TableRowCountRun', COUNT_BIG(*)
   FROM RetentionTest.TableRowCountRun d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
  END
  ELSE
  BEGIN
   DELETE d FROM RetentionTest.BlockingDetail d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'BlockingDetail', ROWCOUNT_BIG());
   DELETE d FROM RetentionTest.BlockingIncident d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'BlockingIncident', ROWCOUNT_BIG());
   DELETE d FROM RetentionTest.BlockingAnalysisRun d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'BlockingAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM RetentionTest.HighResourceSql d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'HighResourceSql', ROWCOUNT_BIG());
   DELETE d FROM RetentionTest.HighResourceSqlAnalysisRun d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'HighResourceSqlAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM RetentionTest.LoginFailedSummary d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LoginFailedSummary', ROWCOUNT_BIG());
   DELETE d FROM RetentionTest.LoginFailed d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LoginFailed', ROWCOUNT_BIG());
   DELETE d FROM RetentionTest.LoginFailedAnalysisRun d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LoginFailedAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM RetentionTest.LongRunningSql d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LongRunningSql', ROWCOUNT_BIG());
   DELETE d FROM RetentionTest.LongRunningSqlAnalysisRun d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LongRunningSqlAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM RetentionTest.TableRowCountSnapshot d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
   INSERT #Results VALUES (N'TableRowCountSnapshot', ROWCOUNT_BIG());
   DELETE d FROM RetentionTest.TableRowCountRun d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
   INSERT #Results VALUES (N'TableRowCountRun', ROWCOUNT_BIG());
  END;
  COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH;
 SELECT @KeepFromDate AS keep_from_date, @PreviewOnly AS preview_only,
        table_name, row_count
 FROM #Results ORDER BY table_name;
END;
GO


DECLARE @Cutoff date=DATEADD(DAY,-29,CONVERT(date,GETDATE())), @Date date, @Run int,
 @Table sysname, @Columns nvarchar(max), @Values nvarchar(max), @Sql nvarchar(max), @Identity bit;
DECLARE Fixtures CURSOR LOCAL FAST_FORWARD FOR
 SELECT name FROM (VALUES
(0,N'BlockingAnalysisRun'),(1,N'BlockingIncident'),(2,N'BlockingDetail'),(3,N'HighResourceSqlAnalysisRun'),(4,N'HighResourceSql'),(5,N'LoginFailedAnalysisRun'),(6,N'LoginFailed'),(7,N'LoginFailedSummary'),(8,N'LongRunningSqlAnalysisRun'),(9,N'LongRunningSql'),(10,N'TableRowCountRun'),(11,N'TableRowCountSnapshot')
 ) t(sequence,name) ORDER BY sequence;
OPEN Fixtures;
FETCH NEXT FROM Fixtures INTO @Table;
WHILE @@FETCH_STATUS=0
BEGIN
 SELECT @Columns=STRING_AGG(CONVERT(nvarchar(max),QUOTENAME(c.name)),N',') WITHIN GROUP(ORDER BY c.column_id),
 @Values=STRING_AGG(CONVERT(nvarchar(max),CASE
 WHEN c.name IN ('analysis_run_id','capture_run_id') OR c.is_identity=1 THEN N'@Run'
 WHEN c.name='analysis_date' AND @Table='BlockingAnalysisRun' THEN N'CASE WHEN @Run=5 THEN NULL ELSE @Date END'
 WHEN c.name IN ('analysis_date','snapshot_date') THEN N'@Date'
 WHEN c.name='status' THEN N'CASE WHEN @Run=4 THEN ''RUNNING'' ELSE ''SUCCEEDED'' END'
 WHEN c.name='run_mode' THEN N'CASE WHEN @Run=5 THEN ''LEGACY'' ELSE ''DAILY'' END'
 WHEN c.name='source_time_at_start' THEN N'TODATETIMEOFFSET(CONVERT(datetime2,@Date),''+00:00'')'
 WHEN c.is_nullable=1 THEN N'NULL'
 WHEN ty.name IN ('varchar','nvarchar','char','nchar') THEN N'N''fixture'''
 WHEN ty.name IN ('date','datetime','datetime2','smalldatetime') THEN N'CONVERT(datetime2,@Date)'
 WHEN ty.name='datetimeoffset' THEN N'TODATETIMEOFFSET(CONVERT(datetime2,@Date),''+00:00'')'
 WHEN ty.name='uniqueidentifier' THEN N'NEWID()'
 ELSE N'1' END),N',') WITHIN GROUP(ORDER BY c.column_id)
 FROM DBAnalyzer.sys.columns c JOIN DBAnalyzer.sys.types ty ON ty.user_type_id=c.user_type_id
 WHERE c.object_id=OBJECT_ID(N'DBAnalyzer.dbo.'+@Table);
 SELECT @Identity=CONVERT(bit,COUNT(*)) FROM DBAnalyzer.sys.columns
 WHERE object_id=OBJECT_ID(N'DBAnalyzer.dbo.'+@Table) AND is_identity=1;
 SET @Sql=CASE WHEN @Identity=1 THEN N'SET IDENTITY_INSERT RetentionTest.'+QUOTENAME(@Table)+N' ON;' ELSE N'' END
  +N'INSERT RetentionTest.'+QUOTENAME(@Table)+N'('+@Columns+N') SELECT '+@Values+N';'
  +CASE WHEN @Identity=1 THEN N'SET IDENTITY_INSERT RetentionTest.'+QUOTENAME(@Table)+N' OFF;' ELSE N'' END;
 SET @Run=1;
 WHILE @Run<=CASE WHEN @Table LIKE 'Blocking%' THEN 5 ELSE 4 END
 BEGIN
  SET @Date=CASE WHEN @Run=2 THEN @Cutoff WHEN @Run=3 THEN CONVERT(date,GETDATE()) ELSE DATEADD(DAY,-1,@Cutoff) END;
  EXEC sys.sp_executesql @Sql,N'@Run int,@Date date',@Run,@Date;
  SET @Run+=1;
 END;
 FETCH NEXT FROM Fixtures INTO @Table;
END;
CLOSE Fixtures;
DEALLOCATE Fixtures;
GO
EXEC RetentionTest.usp_PurgeDBAnalyzerHistory;
IF (SELECT COUNT(*) FROM RetentionTest.BlockingAnalysisRun)<>5
 THROW 58522,'Preview changed data.',1;

-- An inconsistent child date must abort without deleting any tables.
UPDATE RetentionTest.HighResourceSql SET analysis_date=DATEADD(DAY,-29,CONVERT(date,GETDATE())) WHERE analysis_run_id=1;
BEGIN TRY
 EXEC RetentionTest.usp_PurgeDBAnalyzerHistory @PreviewOnly=0;
 THROW 58523,'Expected a child-date validation failure.',1;
END TRY
BEGIN CATCH
 IF ERROR_NUMBER()<>58505 THROW;
END CATCH;
IF (SELECT COUNT(*) FROM RetentionTest.BlockingAnalysisRun)<>5
 THROW 58524,'Failed cleanup did not preserve data.',1;
UPDATE RetentionTest.HighResourceSql SET analysis_date=DATEADD(DAY,-30,CONVERT(date,GETDATE())) WHERE analysis_run_id=1;

-- Force a foreign-key failure after earlier groups have been deleted.
CREATE TABLE RetentionTest.ProtectRun(analysis_run_id bigint NOT NULL REFERENCES RetentionTest.LongRunningSqlAnalysisRun(analysis_run_id));
INSERT RetentionTest.ProtectRun VALUES(1);
BEGIN TRY
 EXEC RetentionTest.usp_PurgeDBAnalyzerHistory @PreviewOnly=0;
 THROW 58530,'Expected foreign-key failure.',1;
END TRY
BEGIN CATCH
 IF ERROR_NUMBER()<>547 THROW;
END CATCH;
IF (SELECT COUNT(*) FROM RetentionTest.BlockingAnalysisRun)<>5
 OR (SELECT COUNT(*) FROM RetentionTest.HighResourceSql)<>4
 THROW 58531,'Partial deletes were not rolled back.',1;
DROP TABLE RetentionTest.ProtectRun;

EXEC RetentionTest.usp_PurgeDBAnalyzerHistory @PreviewOnly=0;
IF (SELECT COUNT(*) FROM RetentionTest.BlockingAnalysisRun)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.BlockingAnalysisRun WHERE analysis_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: BlockingAnalysisRun.',1;
IF (SELECT COUNT(*) FROM RetentionTest.BlockingIncident)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.BlockingIncident WHERE analysis_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: BlockingIncident.',1;
IF (SELECT COUNT(*) FROM RetentionTest.BlockingDetail)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.BlockingDetail WHERE analysis_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: BlockingDetail.',1;
IF (SELECT COUNT(*) FROM RetentionTest.HighResourceSqlAnalysisRun)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.HighResourceSqlAnalysisRun WHERE analysis_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: HighResourceSqlAnalysisRun.',1;
IF (SELECT COUNT(*) FROM RetentionTest.HighResourceSql)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.HighResourceSql WHERE analysis_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: HighResourceSql.',1;
IF (SELECT COUNT(*) FROM RetentionTest.LoginFailedAnalysisRun)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.LoginFailedAnalysisRun WHERE analysis_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: LoginFailedAnalysisRun.',1;
IF (SELECT COUNT(*) FROM RetentionTest.LoginFailed)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.LoginFailed WHERE analysis_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: LoginFailed.',1;
IF (SELECT COUNT(*) FROM RetentionTest.LoginFailedSummary)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.LoginFailedSummary WHERE analysis_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: LoginFailedSummary.',1;
IF (SELECT COUNT(*) FROM RetentionTest.LongRunningSqlAnalysisRun)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.LongRunningSqlAnalysisRun WHERE analysis_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: LongRunningSqlAnalysisRun.',1;
IF (SELECT COUNT(*) FROM RetentionTest.LongRunningSql)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.LongRunningSql WHERE analysis_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: LongRunningSql.',1;
IF (SELECT COUNT(*) FROM RetentionTest.TableRowCountRun)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.TableRowCountRun WHERE capture_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: TableRowCountRun.',1;
IF (SELECT COUNT(*) FROM RetentionTest.TableRowCountSnapshot)<>3 OR EXISTS(SELECT 1 FROM RetentionTest.TableRowCountSnapshot WHERE capture_run_id IN (1,5))
 THROW 58526,'Retention boundary or running-run preservation failed: TableRowCountSnapshot.',1;

EXEC RetentionTest.usp_PurgeDBAnalyzerHistory @PreviewOnly=0;
BEGIN TRY
 EXEC RetentionTest.usp_PurgeDBAnalyzerHistory @RetentionDays=0;
 THROW 58528,'Expected parameter validation failure.',1;
END TRY
BEGIN CATCH
 IF ERROR_NUMBER()<>58501 THROW;
END CATCH;
BEGIN TRANSACTION;
BEGIN TRY
 EXEC RetentionTest.usp_PurgeDBAnalyzerHistory;
 THROW 58529,'Expected existing transaction rejection.',1;
END TRY
BEGIN CATCH
 IF ERROR_NUMBER()<>58500 BEGIN ROLLBACK; THROW; END;
END CATCH;
ROLLBACK;
SELECT 'PASSED' AS result, 'Preview, dates, legacy, foreign keys, running runs, rollback, repeat execution, validation' AS checks;
GO
DROP PROCEDURE RetentionTest.usp_PurgeDBAnalyzerHistory;
DROP TABLE RetentionTest.TableRowCountSnapshot;
DROP TABLE RetentionTest.TableRowCountRun;
DROP TABLE RetentionTest.LongRunningSql;
DROP TABLE RetentionTest.LongRunningSqlAnalysisRun;
DROP TABLE RetentionTest.LoginFailedSummary;
DROP TABLE RetentionTest.LoginFailed;
DROP TABLE RetentionTest.LoginFailedAnalysisRun;
DROP TABLE RetentionTest.HighResourceSql;
DROP TABLE RetentionTest.HighResourceSqlAnalysisRun;
DROP TABLE RetentionTest.BlockingDetail;
DROP TABLE RetentionTest.BlockingIncident;
DROP TABLE RetentionTest.BlockingAnalysisRun;
DROP SCHEMA RetentionTest;
GO
