-- Current exact row count and per-startup load history.
SELECT COUNT_BIG(*) AS current_row_count FROM TableRowCountTestLab.dbo.SampleRows;
SELECT * FROM TableRowCountTestLab.dbo.StartupLoadRun ORDER BY load_run_id DESC;

-- Daily metadata snapshots and linear estimates.
SELECT snapshot_date,row_count,UsedMB,captured_at
FROM DBAnalyzer.dbo.TableRowCountSnapshot
WHERE database_name=N'TableRowCountTestLab' AND schema_name=N'dbo' AND table_name=N'SampleRows'
ORDER BY snapshot_date;
SELECT * FROM DBAnalyzer.dbo.vTableRowCountForecast
WHERE database_name=N'TableRowCountTestLab' AND schema_name=N'dbo' AND table_name=N'SampleRows';

-- Job history includes insertion or snapshot errors.
SELECT TOP(20) h.run_date,h.run_time,h.step_id,h.step_name,h.run_status,h.message
FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id=h.job_id
WHERE j.name=N'_DBAnalyzer-TestRows-Startup' ORDER BY h.instance_id DESC;

-- Retry safely: this SQL Server startup will not insert a second batch.
-- EXEC msdb.dbo.sp_start_job @job_name=N'_DBAnalyzer-TestRows-Startup';
-- EXEC msdb.dbo.sp_update_job @job_name=N'_DBAnalyzer-TestRows-Startup',@enabled=0;
