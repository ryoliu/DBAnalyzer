USE DBAnalyzer;
GO
CREATE OR ALTER PROCEDURE dbo.usp_PurgeDBAnalyzerHistory
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
  FROM dbo.BlockingAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE COALESCE(analysis_date, CONVERT(date, source_time_at_start)) < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT analysis_run_id INTO #HighResourceRuns
  FROM dbo.HighResourceSqlAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE analysis_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT analysis_run_id INTO #LoginFailedRuns
  FROM dbo.LoginFailedAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE analysis_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT analysis_run_id INTO #LongRunningRuns
  FROM dbo.LongRunningSqlAnalysisRun WITH (UPDLOCK, HOLDLOCK)
  WHERE analysis_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');

  SELECT capture_run_id INTO #TableRowCountRuns
  FROM dbo.TableRowCountRun WITH (UPDLOCK, HOLDLOCK)
  WHERE snapshot_date < @KeepFromDate AND status IN ('SUCCEEDED', 'FAILED');


  IF EXISTS (SELECT 1 FROM dbo.HighResourceSql d WITH (UPDLOCK, HOLDLOCK) JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF EXISTS (SELECT 1 FROM dbo.LoginFailedSummary d WITH (UPDLOCK, HOLDLOCK) JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;
  IF EXISTS (SELECT 1 FROM dbo.LoginFailed d WITH (UPDLOCK, HOLDLOCK) JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF EXISTS (SELECT 1 FROM dbo.LongRunningSql d WITH (UPDLOCK, HOLDLOCK) JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id
   WHERE d.analysis_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF EXISTS (SELECT 1 FROM dbo.TableRowCountSnapshot d WITH (UPDLOCK, HOLDLOCK) JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id
   WHERE d.snapshot_date >= @KeepFromDate)
   THROW 58505, 'A selected run has child data inside the retention window. No data was deleted.', 1;

  IF @PreviewOnly = 1
  BEGIN
   INSERT #Results SELECT N'BlockingDetail', COUNT_BIG(*)
   FROM dbo.BlockingDetail d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'BlockingIncident', COUNT_BIG(*)
   FROM dbo.BlockingIncident d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'BlockingAnalysisRun', COUNT_BIG(*)
   FROM dbo.BlockingAnalysisRun d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'HighResourceSql', COUNT_BIG(*)
   FROM dbo.HighResourceSql d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'HighResourceSqlAnalysisRun', COUNT_BIG(*)
   FROM dbo.HighResourceSqlAnalysisRun d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LoginFailedSummary', COUNT_BIG(*)
   FROM dbo.LoginFailedSummary d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LoginFailed', COUNT_BIG(*)
   FROM dbo.LoginFailed d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LoginFailedAnalysisRun', COUNT_BIG(*)
   FROM dbo.LoginFailedAnalysisRun d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LongRunningSql', COUNT_BIG(*)
   FROM dbo.LongRunningSql d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'LongRunningSqlAnalysisRun', COUNT_BIG(*)
   FROM dbo.LongRunningSqlAnalysisRun d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results SELECT N'TableRowCountSnapshot', COUNT_BIG(*)
   FROM dbo.TableRowCountSnapshot d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
   INSERT #Results SELECT N'TableRowCountRun', COUNT_BIG(*)
   FROM dbo.TableRowCountRun d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
  END
  ELSE
  BEGIN
   DELETE d FROM dbo.BlockingDetail d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'BlockingDetail', ROWCOUNT_BIG());
   DELETE d FROM dbo.BlockingIncident d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'BlockingIncident', ROWCOUNT_BIG());
   DELETE d FROM dbo.BlockingAnalysisRun d JOIN #BlockingRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'BlockingAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM dbo.HighResourceSql d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'HighResourceSql', ROWCOUNT_BIG());
   DELETE d FROM dbo.HighResourceSqlAnalysisRun d JOIN #HighResourceRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'HighResourceSqlAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM dbo.LoginFailedSummary d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LoginFailedSummary', ROWCOUNT_BIG());
   DELETE d FROM dbo.LoginFailed d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LoginFailed', ROWCOUNT_BIG());
   DELETE d FROM dbo.LoginFailedAnalysisRun d JOIN #LoginFailedRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LoginFailedAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM dbo.LongRunningSql d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LongRunningSql', ROWCOUNT_BIG());
   DELETE d FROM dbo.LongRunningSqlAnalysisRun d JOIN #LongRunningRuns r ON r.analysis_run_id = d.analysis_run_id;
   INSERT #Results VALUES (N'LongRunningSqlAnalysisRun', ROWCOUNT_BIG());
   DELETE d FROM dbo.TableRowCountSnapshot d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
   INSERT #Results VALUES (N'TableRowCountSnapshot', ROWCOUNT_BIG());
   DELETE d FROM dbo.TableRowCountRun d JOIN #TableRowCountRuns r ON r.capture_run_id = d.capture_run_id;
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
