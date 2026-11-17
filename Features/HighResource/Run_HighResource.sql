USE MS_PERF_COLLECTION;
GO
-- Analyze the previous server-local day.
EXEC analyzer.usp_AnalyzeWhoIsActiveHighResource;
GO
-- Analyze today's available samples.
DECLARE @Today date=CONVERT(date,GETDATE());
EXEC analyzer.usp_AnalyzeWhoIsActiveHighResource @AnalysisDate=@Today,@TopN=20;
GO
-- Review CPU and logical-read rankings separately.
SELECT * FROM analyzer.HighResourceSql WHERE cpu_rank<=20
ORDER BY analysis_date DESC,cpu_rank;
SELECT * FROM analyzer.HighResourceSql WHERE logical_reads_rank<=20
ORDER BY analysis_date DESC,logical_reads_rank;
SELECT TOP(20) * FROM analyzer.HighResourceSqlAnalysisRun ORDER BY analysis_run_id DESC;
