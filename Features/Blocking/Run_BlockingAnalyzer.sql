USE MS_PERF_COLLECTION;
GO
-- Default: analyze the current server-local day up to execution start.
EXEC analyzer.usp_AnalyzeWhoIsActiveBlocking;
GO
-- Rebuild one date when needed. The current date produces a partial report.
-- EXEC analyzer.usp_AnalyzeWhoIsActiveBlocking @AnalysisDate='20261016';

DECLARE @AnalysisDate date=CONVERT(date,GETDATE());
SELECT * FROM analyzer.vBlockingIncident
WHERE analysis_date=@AnalysisDate ORDER BY start_time,incident_id;
SELECT * FROM analyzer.vBlockingDetail
WHERE analysis_date=@AnalysisDate ORDER BY incident_id,collection_time,victim_session_id;
SELECT TOP(20) analysis_run_id,analysis_date,status,is_current_daily,
 captured_sample_count,incident_count,blocked_request_observations,error_message
FROM analyzer.BlockingAnalysisRun WHERE run_mode='DAILY'
ORDER BY analysis_run_id DESC;
GO
