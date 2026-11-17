-- Back up both databases and pause analyzer jobs before running this migration.
-- Run before deploying analyzer tables on an existing DBAnalyzer installation.
USE MS_PERF_COLLECTION;
GO
SET NOCOUNT ON;
IF @@TRANCOUNT<>0 THROW 58809,'Execute outside an existing transaction.',1;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
IF DB_ID(N'DBAnalyzer') IS NULL THROW 58810,'Source DBAnalyzer database is missing.',1;
IF EXISTS(SELECT 1 FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name=N'analyzer')
 THROW 58811,'Target analyzer tables already exist. Do not rerun a completed migration.',1;
IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE enabled=1 AND name IN
 (N'_DBAnalyzer-Daily',N'_DBAnalyzer-History-Cleanup',N'_DBAnalyzer-TestRows-Startup'))
 THROW 58812,'Pause analyzer jobs before migrating.',1;
IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id=a.job_id
 WHERE a.session_id=(SELECT MAX(session_id) FROM msdb.dbo.syssessions)
 AND a.run_requested_date IS NOT NULL AND a.stop_execution_date IS NULL
 AND j.name IN(N'_DBAnalyzer-Daily',N'_DBAnalyzer-History-Cleanup',N'_DBAnalyzer-TestRows-Startup'))
 THROW 58813,'An analyzer job is running or queued.',1;
IF SCHEMA_ID(N'analyzer') IS NULL EXEC(N'CREATE SCHEMA analyzer AUTHORIZATION dbo;');

DECLARE @Tables TABLE(sequence int PRIMARY KEY,table_name sysname);
INSERT @Tables VALUES
 (1,N'BlockingAnalysisRun'),(2,N'BlockingIncident'),(3,N'BlockingDetail'),
 (4,N'HighResourceSqlAnalysisRun'),(5,N'HighResourceSql'),
 (6,N'LoginFailedAnalysisRun'),(7,N'LoginFailed'),(8,N'LoginFailedSummary'),
 (9,N'LongRunningSqlAnalysisRun'),(10,N'LongRunningSql'),
 (11,N'TableRowCountRun'),(12,N'TableRowCountSnapshot');
IF (SELECT COUNT(*) FROM DBAnalyzer.sys.tables t JOIN DBAnalyzer.sys.schemas s ON s.schema_id=t.schema_id
 JOIN @Tables q ON q.table_name=t.name WHERE s.name=N'dbo')<>12
 THROW 58814,'The expected 12 source tables were not found.',1;
IF EXISTS(SELECT 1 FROM DBAnalyzer.sys.tables t JOIN DBAnalyzer.sys.schemas s ON s.schema_id=t.schema_id
 WHERE s.name<>N'dbo' OR t.name NOT IN(SELECT table_name FROM @Tables))
 THROW 58815,'Unexpected source tables exist. Review before migrating.',1;
IF EXISTS(SELECT 1 FROM DBAnalyzer.sys.columns WHERE is_computed=1 OR system_type_id=189)
 THROW 58816,'Computed or rowversion columns require a separate migration.',1;
IF EXISTS(SELECT 1 FROM DBAnalyzer.sys.triggers WHERE parent_class=1)
 THROW 58817,'Source triggers require a separate migration.',1;
IF EXISTS(SELECT 1 FROM DBAnalyzer.sys.database_permissions p JOIN DBAnalyzer.sys.objects o ON o.object_id=p.major_id WHERE p.class=1 AND o.is_ms_shipped=0)
 THROW 58818,'Source object permissions require a separate migration.',1;

DECLARE @Table sysname,@Name sysname,@Sql nvarchar(max),@Columns nvarchar(max),
 @Includes nvarchar(max),@Definition nvarchar(max),@Type nvarchar(60),
 @ReferencedColumns nvarchar(max),@ReferencedTable sysname,@Unique bit,@Primary bit,
 @Constraint bit,@IdentityValue nvarchar(40),@HasIdentity bit,@Filter nvarchar(max),
 @LockResult int,@CopiedRows bigint,@Increment decimal(38,0);
BEGIN TRY
 BEGIN TRANSACTION;
 EXEC @LockResult=DBAnalyzer.sys.sp_getapplock @Resource=N'DBAnalyzer.LoginFailed',
  @LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=0,@DbPrincipal=N'public';
 IF @LockResult<0 THROW 58819,'Source failed-login collection is active.',1;
 EXEC @LockResult=DBAnalyzer.sys.sp_getapplock @Resource=N'DBAnalyzer.HistoryCleanup',
  @LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=0,@DbPrincipal=N'public';
 IF @LockResult<0 THROW 58820,'Source cleanup is active.',1;

 DECLARE TablesToCopy CURSOR LOCAL FAST_FORWARD FOR SELECT table_name FROM @Tables ORDER BY sequence;
 OPEN TablesToCopy;
 FETCH NEXT FROM TablesToCopy INTO @Table;
 WHILE @@FETCH_STATUS=0
 BEGIN
  -- Source table locks protect all rows, including columns retained from older versions.
  SET @Sql=N'DECLARE @Count bigint; SELECT @Count=COUNT_BIG(*) FROM DBAnalyzer.dbo.'+QUOTENAME(@Table)
   +N' WITH(TABLOCKX,HOLDLOCK);'
   +CASE WHEN @Table IN(N'BlockingAnalysisRun',N'HighResourceSqlAnalysisRun',N'LoginFailedAnalysisRun',N'LongRunningSqlAnalysisRun',N'TableRowCountRun')
    THEN N'IF EXISTS(SELECT 1 FROM DBAnalyzer.dbo.'+QUOTENAME(@Table)+N' WHERE status=''RUNNING'') THROW 58821,''A source analysis run is still RUNNING.'',1;' ELSE N'' END
   +N'SELECT TOP(0) * INTO analyzer.'+QUOTENAME(@Table)+N' FROM DBAnalyzer.dbo.'+QUOTENAME(@Table)+N';';
  EXEC(@Sql);
  SELECT @Columns=STRING_AGG(CONVERT(nvarchar(max),QUOTENAME(c.name)),N',') WITHIN GROUP(ORDER BY c.column_id)
  FROM DBAnalyzer.sys.columns c WHERE c.object_id=OBJECT_ID(N'DBAnalyzer.dbo.'+@Table);
  SET @HasIdentity=0;
  SET @IdentityValue=NULL;
  SELECT @HasIdentity=1,@IdentityValue=CONVERT(nvarchar(40),last_value),@Increment=CONVERT(decimal(38,0),increment_value)
  FROM DBAnalyzer.sys.identity_columns WHERE object_id=OBJECT_ID(N'DBAnalyzer.dbo.'+@Table);
  SET @Sql=CASE WHEN @HasIdentity=1 THEN N'SET IDENTITY_INSERT analyzer.'+QUOTENAME(@Table)+N' ON;' ELSE N'' END
   +N'INSERT analyzer.'+QUOTENAME(@Table)+N'('+@Columns+N') SELECT '+@Columns+N' FROM DBAnalyzer.dbo.'+QUOTENAME(@Table)+N'; SET @CopiedRows=ROWCOUNT_BIG();'
   +CASE WHEN @HasIdentity=1 THEN N'SET IDENTITY_INSERT analyzer.'+QUOTENAME(@Table)+N' OFF;' ELSE N'' END;
  EXEC sys.sp_executesql @Sql,N'@CopiedRows bigint OUTPUT',@CopiedRows OUTPUT;
  IF @CopiedRows=0 AND @IdentityValue IS NOT NULL
   SET @IdentityValue=CONVERT(nvarchar(40),CONVERT(decimal(38,0),@IdentityValue)+@Increment);
  IF @IdentityValue IS NOT NULL
  BEGIN
   SET @Sql=N'DBCC CHECKIDENT (''analyzer.'+QUOTENAME(@Table)+N''',RESEED,'+@IdentityValue+N') WITH NO_INFOMSGS;';
   EXEC(@Sql);
  END;
  FETCH NEXT FROM TablesToCopy INTO @Table;
 END;
 CLOSE TablesToCopy;
 DEALLOCATE TablesToCopy;

 DECLARE DefaultsAndChecks CURSOR LOCAL FAST_FORWARD FOR
  SELECT t.name,d.name,N'DEFAULT '+d.definition+N' FOR '+QUOTENAME(c.name)
  FROM DBAnalyzer.sys.default_constraints d JOIN DBAnalyzer.sys.tables t ON t.object_id=d.parent_object_id
  JOIN DBAnalyzer.sys.columns c ON c.object_id=t.object_id AND c.column_id=d.parent_column_id
  UNION ALL SELECT t.name,c.name,N'CHECK '+c.definition
  FROM DBAnalyzer.sys.check_constraints c JOIN DBAnalyzer.sys.tables t ON t.object_id=c.parent_object_id;
 OPEN DefaultsAndChecks;
 FETCH NEXT FROM DefaultsAndChecks INTO @Table,@Name,@Definition;
 WHILE @@FETCH_STATUS=0
 BEGIN
  SET @Sql=N'ALTER TABLE analyzer.'+QUOTENAME(@Table)+N' ADD CONSTRAINT '+QUOTENAME(@Name)+N' '+@Definition+N';';
  EXEC(@Sql);
  FETCH NEXT FROM DefaultsAndChecks INTO @Table,@Name,@Definition;
 END;
 CLOSE DefaultsAndChecks;
 DEALLOCATE DefaultsAndChecks;

 DECLARE @ObjectId int,@IndexId int;
 DECLARE IndexesToCopy CURSOR LOCAL FAST_FORWARD FOR
  SELECT t.object_id,t.name,i.index_id,i.name,i.type_desc,i.is_unique,i.is_primary_key,i.is_unique_constraint,i.filter_definition
  FROM DBAnalyzer.sys.tables t JOIN DBAnalyzer.sys.indexes i ON i.object_id=t.object_id
  WHERE i.index_id>0 ORDER BY t.name,i.index_id;
 OPEN IndexesToCopy;
 FETCH NEXT FROM IndexesToCopy INTO @ObjectId,@Table,@IndexId,@Name,@Type,@Unique,@Primary,@Constraint,@Filter;
 WHILE @@FETCH_STATUS=0
 BEGIN
  IF @Type NOT IN(N'CLUSTERED',N'NONCLUSTERED') THROW 58822,'Unsupported source index type.',1;
  SELECT @Columns=STRING_AGG(CONVERT(nvarchar(max),QUOTENAME(c.name)+CASE WHEN ic.is_descending_key=1 THEN N' DESC' ELSE N' ASC' END),N',')
   WITHIN GROUP(ORDER BY ic.key_ordinal)
  FROM DBAnalyzer.sys.index_columns ic JOIN DBAnalyzer.sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
  WHERE ic.object_id=@ObjectId AND ic.index_id=@IndexId AND ic.key_ordinal>0;
  SELECT @Includes=STRING_AGG(CONVERT(nvarchar(max),QUOTENAME(c.name)),N',') WITHIN GROUP(ORDER BY ic.index_column_id)
  FROM DBAnalyzer.sys.index_columns ic JOIN DBAnalyzer.sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
  WHERE ic.object_id=@ObjectId AND ic.index_id=@IndexId AND ic.is_included_column=1;
  SET @Sql=CASE WHEN @Primary=1 OR @Constraint=1
   THEN N'ALTER TABLE analyzer.'+QUOTENAME(@Table)+N' ADD CONSTRAINT '+QUOTENAME(@Name)
    +CASE WHEN @Primary=1 THEN N' PRIMARY KEY ' ELSE N' UNIQUE ' END+@Type+N'('+@Columns+N');'
   ELSE N'CREATE '+CASE WHEN @Unique=1 THEN N'UNIQUE ' ELSE N'' END+@Type+N' INDEX '+QUOTENAME(@Name)
    +N' ON analyzer.'+QUOTENAME(@Table)+N'('+@Columns+N')'
    +CASE WHEN @Includes IS NOT NULL THEN N' INCLUDE('+@Includes+N')' ELSE N'' END
    +CASE WHEN @Filter IS NOT NULL THEN N' WHERE '+@Filter ELSE N'' END+N';' END;
  EXEC(@Sql);
  FETCH NEXT FROM IndexesToCopy INTO @ObjectId,@Table,@IndexId,@Name,@Type,@Unique,@Primary,@Constraint,@Filter;
 END;
 CLOSE IndexesToCopy;
 DEALLOCATE IndexesToCopy;

 DECLARE @ForeignKeyId int;
 DECLARE ForeignKeysToCopy CURSOR LOCAL FAST_FORWARD FOR
  SELECT f.object_id,f.name,t.name,r.name FROM DBAnalyzer.sys.foreign_keys f
  JOIN DBAnalyzer.sys.tables t ON t.object_id=f.parent_object_id
  JOIN DBAnalyzer.sys.tables r ON r.object_id=f.referenced_object_id;
 OPEN ForeignKeysToCopy;
 FETCH NEXT FROM ForeignKeysToCopy INTO @ForeignKeyId,@Name,@Table,@ReferencedTable;
 WHILE @@FETCH_STATUS=0
 BEGIN
  SELECT @Columns=STRING_AGG(CONVERT(nvarchar(max),QUOTENAME(c.name)),N',') WITHIN GROUP(ORDER BY f.constraint_column_id),
   @ReferencedColumns=STRING_AGG(CONVERT(nvarchar(max),QUOTENAME(r.name)),N',') WITHIN GROUP(ORDER BY f.constraint_column_id)
  FROM DBAnalyzer.sys.foreign_key_columns f
  JOIN DBAnalyzer.sys.columns c ON c.object_id=f.parent_object_id AND c.column_id=f.parent_column_id
  JOIN DBAnalyzer.sys.columns r ON r.object_id=f.referenced_object_id AND r.column_id=f.referenced_column_id
  WHERE f.constraint_object_id=@ForeignKeyId;
  SET @Sql=N'ALTER TABLE analyzer.'+QUOTENAME(@Table)+N' WITH CHECK ADD CONSTRAINT '+QUOTENAME(@Name)
   +N' FOREIGN KEY('+@Columns+N') REFERENCES analyzer.'+QUOTENAME(@ReferencedTable)+N'('+@ReferencedColumns+N');';
  EXEC(@Sql);
  FETCH NEXT FROM ForeignKeysToCopy INTO @ForeignKeyId,@Name,@Table,@ReferencedTable;
 END;
 CLOSE ForeignKeysToCopy;
 DEALLOCATE ForeignKeysToCopy;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
SELECT N'DATA_MIGRATED' result;
GO
