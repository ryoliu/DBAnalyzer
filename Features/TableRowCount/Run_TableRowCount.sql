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
