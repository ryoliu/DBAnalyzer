USE MS_PERF_COLLECTION;
GO
IF OBJECT_ID(N'analyzer.TableRowCountRun',N'U') IS NULL
 CREATE TABLE analyzer.TableRowCountRun(
  capture_run_id bigint IDENTITY PRIMARY KEY,
  snapshot_date date NOT NULL,
  started_at_utc datetime2(3) NOT NULL,
  completed_at_utc datetime2(3) NULL,
  source_server nvarchar(128) NOT NULL,
  source_time_at_start datetimeoffset(3) NOT NULL,
  status varchar(10) NOT NULL CHECK(status IN('RUNNING','SUCCEEDED','FAILED')),
  database_count int NULL,
  table_count int NULL,
  unavailable_table_count int NULL,
  unavailable_size_table_count int NULL,
  failed_database nvarchar(128) NULL,
  error_number int NULL,
  error_message nvarchar(4000) NULL);
GO
IF OBJECT_ID(N'analyzer.TableRowCountSnapshot',N'U') IS NULL
BEGIN
 CREATE TABLE analyzer.TableRowCountSnapshot(
  snapshot_date date NOT NULL,
  database_id int NOT NULL,
  database_guid uniqueidentifier NOT NULL,
  database_name nvarchar(128) NOT NULL,
  table_object_id int NOT NULL,
  table_create_date datetime NOT NULL,
  schema_name nvarchar(128) NOT NULL,
  table_name nvarchar(128) NOT NULL,
  row_count bigint NULL CHECK(row_count>=0),
  UsedMB decimal(28,7) NULL CHECK(UsedMB>=0),
  captured_at datetime2(3) NOT NULL,
  capture_run_id bigint NOT NULL REFERENCES analyzer.TableRowCountRun(capture_run_id),
  PRIMARY KEY(snapshot_date,database_id,database_guid,table_object_id,table_create_date));
 CREATE INDEX IX_TableRowCount_History ON analyzer.TableRowCountSnapshot
  (database_id,database_guid,table_object_id,table_create_date,snapshot_date) INCLUDE(row_count);
END;
GO
-- Existing history has no size measurement. Keep it NULL until recaptured.
IF COL_LENGTH(N'analyzer.TableRowCountSnapshot',N'UsedMB') IS NULL
 ALTER TABLE analyzer.TableRowCountSnapshot ADD UsedMB decimal(28,7) NULL CHECK(UsedMB>=0);
IF COL_LENGTH(N'analyzer.TableRowCountRun',N'unavailable_size_table_count') IS NULL
 ALTER TABLE analyzer.TableRowCountRun ADD unavailable_size_table_count int NULL;
GO
CREATE OR ALTER VIEW analyzer.vTableRowCountGrowth
AS
WITH PreviousCounts AS(
 SELECT *,
  LAG(snapshot_date) OVER(PARTITION BY database_id,database_guid,table_object_id,table_create_date
   ORDER BY snapshot_date) AS previous_snapshot_date,
  LAG(row_count) OVER(PARTITION BY database_id,database_guid,table_object_id,table_create_date
   ORDER BY snapshot_date) AS previous_row_count
 FROM analyzer.TableRowCountSnapshot
 WHERE row_count IS NOT NULL
), PreviousSizes AS(
 SELECT snapshot_date,database_id,database_guid,table_object_id,table_create_date,
  LAG(snapshot_date) OVER(PARTITION BY database_id,database_guid,table_object_id,table_create_date
   ORDER BY snapshot_date) AS previous_size_snapshot_date,
  LAG(UsedMB) OVER(PARTITION BY database_id,database_guid,table_object_id,table_create_date
   ORDER BY snapshot_date) AS previous_used_mb
 FROM analyzer.TableRowCountSnapshot
 WHERE UsedMB IS NOT NULL
)
SELECT counts.*,
 DATEDIFF(DAY,counts.previous_snapshot_date,counts.snapshot_date) AS elapsed_days,
 counts.row_count-counts.previous_row_count AS net_row_change,
 CONVERT(decimal(28,3),(CONVERT(decimal(28,3),counts.row_count)-counts.previous_row_count)
  /NULLIF(DATEDIFF(DAY,counts.previous_snapshot_date,counts.snapshot_date),0)) AS avg_daily_net_growth,
 sizes.previous_size_snapshot_date,sizes.previous_used_mb,
 DATEDIFF(DAY,sizes.previous_size_snapshot_date,counts.snapshot_date) AS size_elapsed_days,
 counts.UsedMB-sizes.previous_used_mb AS net_used_mb_change,
 CONVERT(decimal(28,7),(counts.UsedMB-sizes.previous_used_mb)
  /NULLIF(DATEDIFF(DAY,sizes.previous_size_snapshot_date,counts.snapshot_date),0)) AS avg_daily_used_mb_growth
FROM PreviousCounts counts
LEFT JOIN PreviousSizes sizes
 ON sizes.snapshot_date=counts.snapshot_date AND sizes.database_id=counts.database_id
 AND sizes.database_guid=counts.database_guid AND sizes.table_object_id=counts.table_object_id
 AND sizes.table_create_date=counts.table_create_date;
GO
CREATE OR ALTER VIEW analyzer.vTableRowCountGrowthSummary
AS
SELECT last_count.database_name,last_count.schema_name,last_count.table_name,
 history.database_id,history.database_guid,history.table_object_id,history.table_create_date,
 history.snapshot_count,history.first_snapshot_date,history.last_snapshot_date,
 first_count.row_count AS first_row_count,last_count.row_count AS last_row_count,
 last_count.row_count-first_count.row_count AS total_net_growth,
 DATEDIFF(DAY,history.first_snapshot_date,history.last_snapshot_date) AS elapsed_days,
 CONVERT(decimal(28,3),(CONVERT(decimal(28,3),last_count.row_count)-first_count.row_count)
  /NULLIF(DATEDIFF(DAY,history.first_snapshot_date,history.last_snapshot_date),0)) AS avg_daily_net_growth,
 sizes.used_mb_snapshot_count,sizes.first_size_snapshot_date,sizes.last_size_snapshot_date,
 first_size.UsedMB AS first_used_mb,last_size.UsedMB AS last_used_mb,
 last_size.UsedMB-first_size.UsedMB AS total_used_mb_growth,
 DATEDIFF(DAY,sizes.first_size_snapshot_date,sizes.last_size_snapshot_date) AS size_elapsed_days,
 CONVERT(decimal(28,7),(last_size.UsedMB-first_size.UsedMB)
  /NULLIF(DATEDIFF(DAY,sizes.first_size_snapshot_date,sizes.last_size_snapshot_date),0)) AS avg_daily_used_mb_growth
FROM(
 SELECT database_id,database_guid,table_object_id,table_create_date,
  COUNT(*) AS snapshot_count,MIN(snapshot_date) AS first_snapshot_date,
  MAX(snapshot_date) AS last_snapshot_date
 FROM analyzer.TableRowCountSnapshot
 WHERE row_count IS NOT NULL
 GROUP BY database_id,database_guid,table_object_id,table_create_date
) history
JOIN analyzer.TableRowCountSnapshot first_count
 ON first_count.database_id=history.database_id AND first_count.database_guid=history.database_guid
 AND first_count.table_object_id=history.table_object_id AND first_count.table_create_date=history.table_create_date
 AND first_count.snapshot_date=history.first_snapshot_date
JOIN analyzer.TableRowCountSnapshot last_count
 ON last_count.database_id=history.database_id AND last_count.database_guid=history.database_guid
 AND last_count.table_object_id=history.table_object_id AND last_count.table_create_date=history.table_create_date
 AND last_count.snapshot_date=history.last_snapshot_date
LEFT JOIN(
 SELECT database_id,database_guid,table_object_id,table_create_date,
  COUNT(*) AS used_mb_snapshot_count,MIN(snapshot_date) AS first_size_snapshot_date,
  MAX(snapshot_date) AS last_size_snapshot_date
 FROM analyzer.TableRowCountSnapshot
 WHERE UsedMB IS NOT NULL
 GROUP BY database_id,database_guid,table_object_id,table_create_date
) sizes
 ON sizes.database_id=history.database_id AND sizes.database_guid=history.database_guid
 AND sizes.table_object_id=history.table_object_id AND sizes.table_create_date=history.table_create_date
LEFT JOIN analyzer.TableRowCountSnapshot first_size
 ON first_size.database_id=sizes.database_id AND first_size.database_guid=sizes.database_guid
 AND first_size.table_object_id=sizes.table_object_id AND first_size.table_create_date=sizes.table_create_date
 AND first_size.snapshot_date=sizes.first_size_snapshot_date
LEFT JOIN analyzer.TableRowCountSnapshot last_size
 ON last_size.database_id=sizes.database_id AND last_size.database_guid=sizes.database_guid
 AND last_size.table_object_id=sizes.table_object_id AND last_size.table_create_date=sizes.table_create_date
 AND last_size.snapshot_date=sizes.last_size_snapshot_date;
GO
CREATE OR ALTER VIEW analyzer.vTableRowCountForecast
AS
WITH Recent AS(
 SELECT * FROM analyzer.TableRowCountSnapshot
 WHERE snapshot_date>=DATEADD(DAY,-29,CONVERT(date,GETDATE()))
   AND snapshot_date<=CONVERT(date,GETDATE())
), History AS(
 SELECT database_id,database_guid,table_object_id,table_create_date,
  COUNT(*) AS snapshot_count,MIN(snapshot_date) AS first_snapshot_date,
  MAX(snapshot_date) AS last_valid_snapshot_date
 FROM Recent WHERE row_count IS NOT NULL
 GROUP BY database_id,database_guid,table_object_id,table_create_date
), Trend AS(
 SELECT latest.database_name,latest.schema_name,latest.table_name,
  latest.database_id,latest.database_guid,latest.table_object_id,latest.table_create_date,
  ISNULL(history.snapshot_count,0) AS snapshot_count,history.first_snapshot_date,
  latest.snapshot_date AS last_snapshot_date,latest.captured_at,
  DATEDIFF(DAY,latest.snapshot_date,CONVERT(date,GETDATE())) AS snapshot_age_days,
  DATEDIFF(DAY,history.first_snapshot_date,history.last_valid_snapshot_date) AS observed_days,
  first_count.row_count AS first_row_count,latest.row_count AS last_row_count,
  CONVERT(decimal(28,6),(CONVERT(decimal(28,6),latest.row_count)-first_count.row_count)
   /NULLIF(DATEDIFF(DAY,history.first_snapshot_date,history.last_valid_snapshot_date),0)) AS avg_daily_net_growth
 FROM Recent latest
 LEFT JOIN History history
  ON history.database_id=latest.database_id AND history.database_guid=latest.database_guid
  AND history.table_object_id=latest.table_object_id AND history.table_create_date=latest.table_create_date
 LEFT JOIN Recent first_count
  ON first_count.database_id=history.database_id AND first_count.database_guid=history.database_guid
  AND first_count.table_object_id=history.table_object_id AND first_count.table_create_date=history.table_create_date
  AND first_count.snapshot_date=history.first_snapshot_date
 WHERE latest.snapshot_date=(SELECT MAX(snapshot_date) FROM Recent)
)
SELECT *,
 CONVERT(varchar(24),CASE WHEN last_row_count IS NULL THEN 'UNKNOWN_COUNT'
  WHEN snapshot_count<2 THEN 'INSUFFICIENT_HISTORY' ELSE 'ESTIMATE' END) AS forecast_status,
 DATEADD(DAY,7,last_snapshot_date) AS forecast_date_7d,
 CONVERT(decimal(28,0),CASE WHEN last_row_count+avg_daily_net_growth*7<0 THEN 0
  ELSE last_row_count+avg_daily_net_growth*7 END) AS estimated_row_count_7d,
 DATEADD(DAY,30,last_snapshot_date) AS forecast_date_30d,
 CONVERT(decimal(28,0),CASE WHEN last_row_count+avg_daily_net_growth*30<0 THEN 0
  ELSE last_row_count+avg_daily_net_growth*30 END) AS estimated_row_count_30d
FROM Trend;
GO
CREATE OR ALTER PROCEDURE analyzer.usp_CaptureTableRowCount
 @ReturnResults bit=1,
 @CaptureRunId bigint=NULL OUTPUT
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 SET @CaptureRunId=NULL;
 IF @@TRANCOUNT<>0 THROW 58600,'Execute outside an existing transaction.',1;
 DECLARE @SnapshotDate date=CONVERT(date,GETDATE()),
  @DatabaseName sysname,@DatabaseGuid uniqueidentifier,@Sql nvarchar(max),
  @QueueId int=1,@DatabaseCount int,@TableCount int;
 BEGIN TRY
  INSERT analyzer.TableRowCountRun(snapshot_date,started_at_utc,source_server,source_time_at_start,status)
  VALUES(@SnapshotDate,SYSUTCDATETIME(),CONVERT(nvarchar(128),SERVERPROPERTY('ServerName')),
   SYSDATETIMEOFFSET(),'RUNNING');
  SET @CaptureRunId=CONVERT(bigint,SCOPE_IDENTITY());

  -- Include user databases, excluding monitoring databases and database snapshots.
  SELECT IDENTITY(int,1,1) AS queue_id,d.name,r.database_guid
  INTO #Databases
  FROM master.sys.databases d
  LEFT JOIN master.sys.database_recovery_status r ON r.database_id=d.database_id
  WHERE d.database_id>4 AND d.source_database_id IS NULL
   AND d.name NOT IN(N'DBAnalyzer',N'MS_PERF_COLLECTION');
  SET @DatabaseCount=@@ROWCOUNT;

  CREATE TABLE #Counts(
   database_id int,database_guid uniqueidentifier NOT NULL,database_name nvarchar(128),
   table_object_id int,table_create_date datetime,schema_name nvarchar(128),
   table_name nvarchar(128),row_count bigint NULL,UsedMB decimal(28,7) NULL,captured_at datetime2(3));

  -- Count base rows only, but include all index partitions when measuring used space.
  WHILE @QueueId<=@DatabaseCount
  BEGIN
   SELECT @DatabaseName=name,@DatabaseGuid=database_guid FROM #Databases WHERE queue_id=@QueueId;
   SET @Sql=N'USE '+QUOTENAME(@DatabaseName)+N';
    INSERT #Counts
    SELECT DB_ID(),@Guid,DB_NAME(),t.object_id,t.create_date,s.name,t.name,
     CASE WHEN t.is_memory_optimized=1 THEN NULL ELSE p.row_count END,
     CASE WHEN t.is_memory_optimized=1 THEN NULL ELSE p.UsedMB END,SYSDATETIME()
    FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id
    LEFT JOIN(
     SELECT object_id,
      SUM(CASE WHEN index_id IN(0,1) THEN row_count END) AS row_count,
      CONVERT(decimal(28,7),SUM(used_page_count))/128 AS UsedMB
     FROM sys.dm_db_partition_stats
     GROUP BY object_id
    ) p ON p.object_id=t.object_id
    WHERE t.is_ms_shipped=0;';
   EXEC sys.sp_executesql @Sql,N'@Guid uniqueidentifier',@Guid=@DatabaseGuid;
   SET @QueueId=@QueueId+1;
  END;
  SET @DatabaseName=NULL;

  -- Replace today's complete snapshot only after every database has been read.
  BEGIN TRANSACTION;
  DELETE analyzer.TableRowCountSnapshot WHERE snapshot_date=@SnapshotDate;
  INSERT analyzer.TableRowCountSnapshot(snapshot_date,database_id,database_guid,database_name,
   table_object_id,table_create_date,schema_name,table_name,row_count,UsedMB,captured_at,capture_run_id)
  SELECT @SnapshotDate,database_id,database_guid,database_name,
   table_object_id,table_create_date,schema_name,table_name,row_count,UsedMB,captured_at,@CaptureRunId
  FROM #Counts;
  SET @TableCount=@@ROWCOUNT;
  UPDATE analyzer.TableRowCountRun
  SET status='SUCCEEDED',completed_at_utc=SYSUTCDATETIME(),database_count=@DatabaseCount,
   table_count=@TableCount,unavailable_table_count=(SELECT COUNT(*) FROM #Counts WHERE row_count IS NULL),
   unavailable_size_table_count=(SELECT COUNT(*) FROM #Counts WHERE UsedMB IS NULL)
  WHERE capture_run_id=@CaptureRunId;
  COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
  UPDATE analyzer.TableRowCountRun
  SET status='FAILED',completed_at_utc=SYSUTCDATETIME(),failed_database=@DatabaseName,
   error_number=ERROR_NUMBER(),error_message=ERROR_MESSAGE()
  WHERE capture_run_id=@CaptureRunId;
  THROW;
 END CATCH;
 IF @ReturnResults=1
 BEGIN
  SELECT * FROM analyzer.TableRowCountRun WHERE capture_run_id=@CaptureRunId;
  SELECT * FROM analyzer.TableRowCountSnapshot WHERE capture_run_id=@CaptureRunId
   ORDER BY database_name,schema_name,table_name;
 END;
END;
GO
