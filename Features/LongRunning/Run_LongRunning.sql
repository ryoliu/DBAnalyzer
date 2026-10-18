USE DBAnalyzer;
GO
-- Analyze the previous server-local day with the default 300-second threshold.
EXEC dbo.usp_AnalyzeWhoIsActiveLongRunning;
GO
-- Analyze today's available samples.
DECLARE @Today date=CONVERT(date,GETDATE());
EXEC dbo.usp_AnalyzeWhoIsActiveLongRunning @AnalysisDate=@Today;
GO
-- Review recent reports and run history.
SELECT * FROM dbo.LongRunningSql
ORDER BY analysis_date DESC,max_elapsed_seconds DESC;
SELECT TOP(20) * FROM dbo.LongRunningSqlAnalysisRun ORDER BY analysis_run_id DESC;
