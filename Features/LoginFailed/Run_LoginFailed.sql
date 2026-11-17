USE MS_PERF_COLLECTION;
GO
-- Collect the current server-local day up to execution start.
EXEC analyzer.usp_AnalyzeLoginFailed;
GO
-- Rebuild one date when necessary, or explicitly collect today's partial log.
-- EXEC analyzer.usp_AnalyzeLoginFailed @AnalysisDate='20261016';
-- Increase limits only when the retained ERRORLOG files still cover the requested date.
-- EXEC analyzer.usp_AnalyzeLoginFailed @AnalysisDate='20261016', @MaxArchiveNo=20, @RetentionDays=90;
-- SQL Agent: EXEC analyzer.usp_AnalyzeLoginFailed @ReturnResults=0;
-- DECLARE @Today date=CONVERT(date,GETDATE());
-- EXEC analyzer.usp_AnalyzeLoginFailed @AnalysisDate=@Today;

DECLARE @Date date=CONVERT(date,GETDATE());
SELECT analysis_date,failure_category,error_number,error_state,failure_count,
 affected_login_count,affected_client_count,first_failure,last_failure,sample_failure_reason
FROM analyzer.LoginFailedSummary WHERE analysis_date=@Date
ORDER BY failure_count DESC,failure_category;

SELECT log_date,login_name,client_address,error_number,severity,error_state,
 failure_reason,archive_number,raw_message
FROM analyzer.LoginFailed WHERE analysis_date=@Date
ORDER BY log_date,login_failed_id;

SELECT login_name,client_address,failure_category,error_number,error_state,COUNT_BIG(*) AS failure_count,
 MIN(log_date) AS first_failure,MAX(log_date) AS last_failure
FROM analyzer.vLoginFailedClassified WHERE analysis_date=@Date
GROUP BY login_name,client_address,failure_category,error_number,error_state
ORDER BY failure_count DESC;

SELECT TOP(20) * FROM analyzer.LoginFailedAnalysisRun ORDER BY analysis_run_id DESC;

-- Drill down from a summary category to the original failure messages.
SELECT log_date,failure_category,login_name,client_address,error_number,error_state,
 failure_reason,raw_message
FROM analyzer.vLoginFailedClassified
WHERE analysis_date=@Date AND failure_category='DATABASE_ACCESS_FAILED'
ORDER BY log_date,login_failed_id;
GO
