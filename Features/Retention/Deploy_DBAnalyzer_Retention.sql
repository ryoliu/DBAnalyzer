USE MS_PERF_COLLECTION;
GO
CREATE OR ALTER PROCEDURE analyzer.usp_PurgeDBAnalyzerHistory
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
  FROM analyzer.BlockingAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE COALESCE(analysis_date, CONVERT(date, source_time_at_start)) < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT analysis_run_id INTO #HighResourceRuns
  FROM analyzer.HighResourceSqlAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE analysis_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT analysis_run_id INTO #LoginFailedRuns
  FROM analyzer.LoginFailedAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE analysis_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT analysis_run_id INTO #LongRunningRuns
  FROM analyzer.LongRunningSqlAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE analysis_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT capture_run_id INTO #TableRowCountRuns
  FROM analyzer.TableRowCountRun WITH (UPDLOCK, HOLDLOCK)
  WHERE snapshot_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');


  IF EXISTS (SELECT 1 FROM analyzer.HighResourceSql d WITH (UPDLOCK, HOLDLOCK) JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF EXISTS (SELECT 1 FROM analyzer.LoginFailedSummary d WITH (UPDLOCK, HOLDLOCK) JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;
  IF EXISTS (SELECT 1 FROM analyzer.LoginFailed d WITH (UPDLOCK, HOLDLOCK) JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF EXISTS (SELECT 1 FROM analyzer.LongRunningSql d WITH (UPDLOCK, HOLDLOCK) JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF EXISTS (SELECT 1 FROM analyzer.TableRowCountSnapshot d WITH (UPDLOCK, HOLDLOCK) JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id
   WHERE d.snapshot_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF @PreviewOnly = 1
  BEGIN
   INSERT #Results SELECT N'BlockingDetail', COUNT_BIG(*)
   FROM analyzer.BlockingDetail d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'BlockingIncident', COUNT_BIG(*)
   FROM analyzer.BlockingIncident d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'BlockingAnalysisRun', COUNT_BIG(*)
   FROM analyzer.BlockingAnalysisRun d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'HighResourceSql', COUNT_BIG(*)
   FROM analyzer.HighResourceSql d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'HighResourceSqlAnalysisRun', COUNT_BIG(*)
   FROM analyzer.HighResourceSqlAnalysisRun d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LoginFailedSummary', COUNT_BIG(*)
   FROM analyzer.LoginFailedSummary d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LoginFailed', COUNT_BIG(*)
   FROM analyzer.LoginFailed d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LoginFailedAnalysisRun', COUNT_BIG(*)
   FROM analyzer.LoginFailedAnalysisRun d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LongRunningSql', COUNT_BIG(*)
   FROM analyzer.LongRunningSql d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LongRunningSqlAnalysisRun', COUNT_BIG(*)
   FROM analyzer.LongRunningSqlAnalysisRun d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'TableRowCountSnapshot', COUNT_BIG(*)
   FROM analyzer.TableRowCountSnapshot d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
   INSERT #Results SELECT N'TableRowCountRun', COUNT_BIG(*)
   FROM analyzer.TableRowCountRun d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
  END
  ELSE
  BEGIN
   DELETE d FROM analyzer.BlockingDetail d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'BlockingDetail', ROWCOUNT_BIG());
   DELETE d FROM analyzer.BlockingIncident d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'BlockingIncident', ROWCOUNT_BIG());
   DELETE d FROM analyzer.BlockingAnalysisRun d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'BlockingAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM analyzer.HighResourceSql d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'HighResourceSql', ROWCOUNT_BIG());
   DELETE d FROM analyzer.HighResourceSqlAnalysisRun d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'HighResourceSqlAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM analyzer.LoginFailedSummary d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LoginFailedSummary', ROWCOUNT_BIG());
   DELETE d FROM analyzer.LoginFailed d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LoginFailed', ROWCOUNT_BIG());
   DELETE d FROM analyzer.LoginFailedAnalysisRun d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LoginFailedAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM analyzer.LongRunningSql d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LongRunningSql', ROWCOUNT_BIG());
   DELETE d FROM analyzer.LongRunningSqlAnalysisRun d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LongRunningSqlAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM analyzer.TableRowCountSnapshot d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
   INSERT #Results VALUES (N'TableRowCountSnapshot', ROWCOUNT_BIG());
   DELETE d FROM analyzer.TableRowCountRun d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
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
