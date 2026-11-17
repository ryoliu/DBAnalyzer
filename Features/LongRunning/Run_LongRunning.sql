USE MS_PERF_COLLECTION;
GO
-- Analyze the current server-local day up to execution start with the default 30-second threshold.
EXEC analyzer.usp_AnalyzeWhoIsActiveLongRunning;
GO
-- Rebuild a past day explicitly when needed.
-- DECLARE @Past date=DATEADD(DAY,-1,CONVERT(date,GETDATE()));
-- EXEC analyzer.usp_AnalyzeWhoIsActiveLongRunning @AnalysisDate=@Past;
GO
-- Review recent reports and run history.
SELECT * FROM analyzer.LongRunningSql
ORDER BY analysis_date DESC,max_elapsed_seconds DESC;
SELECT TOP(20) * FROM analyzer.LongRunningSqlAnalysisRun ORDER BY analysis_run_id DESC;
