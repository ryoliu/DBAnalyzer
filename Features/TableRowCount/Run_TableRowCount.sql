USE DBAnalyzer;
GO
-- Capture current metadata counts. Historical counts cannot be reconstructed.
EXEC dbo.usp_CaptureTableRowCount;
GO
-- Compare each capture date with the previous available date.
SELECT database_name,schema_name,table_name,snapshot_date,row_count,UsedMB,
 previous_snapshot_date,previous_row_count,elapsed_days,net_row_change,avg_daily_net_growth,
 previous_size_snapshot_date,previous_used_mb,size_elapsed_days,
 net_used_mb_change,avg_daily_used_mb_growth
FROM dbo.vTableRowCountGrowth
ORDER BY snapshot_date DESC,database_name,schema_name,table_name;
GO
-- Average daily net growth from the first valid snapshot to the latest one.
SELECT * FROM dbo.vTableRowCountGrowthSummary
ORDER BY avg_daily_net_growth DESC,database_name,schema_name,table_name;
GO
-- Rank tables by average daily used-space growth.
SELECT database_name,schema_name,table_name,first_used_mb,last_used_mb,
 total_used_mb_growth,size_elapsed_days,avg_daily_used_mb_growth
FROM dbo.vTableRowCountGrowthSummary
ORDER BY avg_daily_used_mb_growth DESC,database_name,schema_name,table_name;
GO
SELECT TOP(20) * FROM dbo.TableRowCountRun ORDER BY capture_run_id DESC;
GO
-- Linear estimates from the latest snapshot, using the last 30 calendar dates.
SELECT database_name,schema_name,table_name,forecast_status,
 first_snapshot_date,last_snapshot_date,snapshot_age_days,snapshot_count,observed_days,
 last_row_count,avg_daily_net_growth,
 forecast_date_7d,estimated_row_count_7d,forecast_date_30d,estimated_row_count_30d
FROM dbo.vTableRowCountForecast
ORDER BY estimated_row_count_30d DESC,database_name,schema_name,table_name;
