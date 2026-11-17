USE MS_PERF_COLLECTION;
SET XACT_ABORT ON;

IF CONVERT(nvarchar(128),SERVERPROPERTY('ServerName'))<>N'WIN2019LAB'
    THROW 58940,'This cleanup is restricted to WIN2019LAB.',1;

-- Avoid clearing while the daily analysis job is active.
IF EXISTS(
    SELECT 1 FROM msdb.dbo.sysjobactivity a
    JOIN msdb.dbo.sysjobs j ON j.job_id=a.job_id
    WHERE j.name=N'_DBAnalyzer-Daily'
      AND a.session_id=(SELECT MAX(session_id) FROM msdb.dbo.syssessions)
      AND a.run_requested_date IS NOT NULL AND a.stop_execution_date IS NULL)
    THROW 58942,'The daily analysis job is active. Retry after it completes.',1;

BEGIN TRANSACTION;
DECLARE @Details bigint,@Runs bigint;
DELETE analyzer.HighResourceSql;
SET @Details=@@ROWCOUNT;
DELETE analyzer.HighResourceSqlAnalysisRun;
SET @Runs=@@ROWCOUNT;
SELECT @Details deleted_results,@Runs deleted_runs,
       (SELECT COUNT_BIG(*) FROM analyzer.HighResourceSql) remaining_results,
       (SELECT COUNT_BIG(*) FROM analyzer.HighResourceSqlAnalysisRun) remaining_runs;
COMMIT TRANSACTION;
