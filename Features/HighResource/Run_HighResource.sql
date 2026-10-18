USE DBAnalyzer;
GO
-- Analyze the previous server-local day.
EXEC dbo.usp_AnalyzeWhoIsActiveHighResource;
GO
-- Analyze today's available samples.
DECLARE @Today date=CONVERT(date,GETDATE());
EXEC dbo.usp_AnalyzeWhoIsActiveHighResource @AnalysisDate=@Today,@TopN=20;
GO
-- Review CPU and logical-read rankings separately.
SELECT * FROM dbo.HighResourceSql WHERE cpu_rank<=20
ORDER BY analysis_date DESC,cpu_rank;
SELECT * FROM dbo.HighResourceSql WHERE logical_reads_rank<=20
ORDER BY analysis_date DESC,logical_reads_rank;
SELECT TOP(20) * FROM dbo.HighResourceSqlAnalysisRun ORDER BY analysis_run_id DESC;
