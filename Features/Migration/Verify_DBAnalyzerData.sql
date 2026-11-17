-- Run while analyzer jobs are paused, before executing analyses in the target.
USE MS_PERF_COLLECTION;
GO
SET NOCOUNT ON;
DECLARE @Table sysname,@Order nvarchar(max),@Sql nvarchar(max),
 @SourceHash varbinary(32),@TargetHash varbinary(32),@Rows bigint,
 @SourceNext decimal(38,0),@TargetNext decimal(38,0);
DROP TABLE IF EXISTS #MigrationVerification;
CREATE TABLE #MigrationVerification(table_name sysname,row_count bigint,data_hash varchar(64),next_identity decimal(38,0));
DECLARE TablesToVerify CURSOR LOCAL FAST_FORWARD FOR
 SELECT t.name,STRING_AGG(CONVERT(nvarchar(max),QUOTENAME(c.name)),N',') WITHIN GROUP(ORDER BY ic.key_ordinal)
 FROM DBAnalyzer.sys.tables t JOIN DBAnalyzer.sys.indexes i ON i.object_id=t.object_id AND i.is_primary_key=1
 JOIN DBAnalyzer.sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id
 JOIN DBAnalyzer.sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
 WHERE ic.key_ordinal>0 GROUP BY t.name;
OPEN TablesToVerify;
FETCH NEXT FROM TablesToVerify INTO @Table,@Order;
WHILE @@FETCH_STATUS=0
BEGIN
 SET @Sql=N'SELECT @SourceHash=HASHBYTES(''SHA2_256'',(SELECT * FROM DBAnalyzer.dbo.'+QUOTENAME(@Table)
  +N' ORDER BY '+@Order+N' FOR JSON PATH,INCLUDE_NULL_VALUES));'
  +N'SELECT @TargetHash=HASHBYTES(''SHA2_256'',(SELECT * FROM analyzer.'+QUOTENAME(@Table)
  +N' ORDER BY '+@Order+N' FOR JSON PATH,INCLUDE_NULL_VALUES));'
  +N'SELECT @Rows=COUNT_BIG(*) FROM analyzer.'+QUOTENAME(@Table)+N';';
 EXEC sys.sp_executesql @Sql,N'@SourceHash varbinary(32) OUTPUT,@TargetHash varbinary(32) OUTPUT,@Rows bigint OUTPUT',
  @SourceHash OUTPUT,@TargetHash OUTPUT,@Rows OUTPUT;
 IF @SourceHash<>@TargetHash THROW 58840,'Source and target data hashes differ.',1;
 SET @SourceNext=NULL;
 SET @TargetNext=NULL;
 SELECT @SourceNext=CONVERT(decimal(38,0),COALESCE(last_value,seed_value))
  +CASE WHEN last_value IS NULL THEN 0 ELSE CONVERT(decimal(38,0),increment_value) END
 FROM DBAnalyzer.sys.identity_columns WHERE object_id=OBJECT_ID(N'DBAnalyzer.dbo.'+@Table);
 SELECT @TargetNext=CONVERT(decimal(38,0),IDENT_CURRENT(N'analyzer.'+QUOTENAME(@Table)))
  +CASE WHEN @Rows=0 THEN 0 ELSE CONVERT(decimal(38,0),increment_value) END
 FROM sys.identity_columns WHERE object_id=OBJECT_ID(N'analyzer.'+@Table);
 IF @SourceNext<>@TargetNext THROW 58841,'The next identity value differs.',1;
 INSERT #MigrationVerification VALUES(@Table,@Rows,CONVERT(varchar(64),@TargetHash,2),@TargetNext);
 FETCH NEXT FROM TablesToVerify INTO @Table,@Order;
END;
CLOSE TablesToVerify;
DEALLOCATE TablesToVerify;
IF (SELECT COUNT(*) FROM #MigrationVerification)<>12 THROW 58842,'Expected 12 verified tables.',1;

DECLARE @SourceMetadata nvarchar(max),@TargetMetadata nvarchar(max);
SELECT @SourceMetadata=(SELECT t.name table_name,c.name column_name,c.system_type_id,c.max_length,
 c.precision,c.scale,c.collation_name,c.is_nullable,c.is_identity
 FROM DBAnalyzer.sys.tables t JOIN DBAnalyzer.sys.columns c ON c.object_id=t.object_id
 ORDER BY t.name,c.column_id FOR JSON PATH,INCLUDE_NULL_VALUES);
SELECT @TargetMetadata=(SELECT t.name table_name,c.name column_name,c.system_type_id,c.max_length,
 c.precision,c.scale,c.collation_name,c.is_nullable,c.is_identity
 FROM sys.tables t JOIN sys.columns c ON c.object_id=t.object_id JOIN sys.schemas s ON s.schema_id=t.schema_id
 WHERE s.name=N'analyzer' ORDER BY t.name,c.column_id FOR JSON PATH,INCLUDE_NULL_VALUES);
IF HASHBYTES('SHA2_256',@SourceMetadata)<>HASHBYTES('SHA2_256',@TargetMetadata)
 THROW 58843,'Column metadata differs.',1;
SELECT @SourceMetadata=(SELECT t.name table_name,i.name,i.type_desc,i.is_unique,i.is_primary_key,i.is_unique_constraint,
 i.filter_definition,ic.key_ordinal,ic.is_descending_key,ic.is_included_column,c.name column_name
 FROM DBAnalyzer.sys.tables t JOIN DBAnalyzer.sys.indexes i ON i.object_id=t.object_id
 JOIN DBAnalyzer.sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id
 JOIN DBAnalyzer.sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
 ORDER BY t.name,i.name,ic.index_column_id FOR JSON PATH,INCLUDE_NULL_VALUES);
SELECT @TargetMetadata=(SELECT t.name table_name,i.name,i.type_desc,i.is_unique,i.is_primary_key,i.is_unique_constraint,
 i.filter_definition,ic.key_ordinal,ic.is_descending_key,ic.is_included_column,c.name column_name
 FROM sys.tables t JOIN sys.indexes i ON i.object_id=t.object_id
 JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id
 JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id JOIN sys.schemas s ON s.schema_id=t.schema_id
 WHERE s.name=N'analyzer' ORDER BY t.name,i.name,ic.index_column_id FOR JSON PATH,INCLUDE_NULL_VALUES);
IF HASHBYTES('SHA2_256',@SourceMetadata)<>HASHBYTES('SHA2_256',@TargetMetadata)
 THROW 58844,'Index metadata differs.',1;
IF EXISTS(SELECT 1 FROM sys.foreign_keys f JOIN sys.tables t ON t.object_id=f.parent_object_id
 WHERE t.schema_id=SCHEMA_ID(N'analyzer') AND (f.is_disabled=1 OR f.is_not_trusted=1))
 THROW 58845,'A target foreign key is disabled or untrusted.',1;
SELECT @SourceMetadata=(SELECT t.name table_name,f.name,c.name column_name,r.name referenced_table,rc.name referenced_column,
 f.delete_referential_action,f.update_referential_action,fc.constraint_column_id
 FROM DBAnalyzer.sys.foreign_keys f JOIN DBAnalyzer.sys.tables t ON t.object_id=f.parent_object_id
 JOIN DBAnalyzer.sys.foreign_key_columns fc ON fc.constraint_object_id=f.object_id
 JOIN DBAnalyzer.sys.columns c ON c.object_id=t.object_id AND c.column_id=fc.parent_column_id
 JOIN DBAnalyzer.sys.tables r ON r.object_id=f.referenced_object_id
 JOIN DBAnalyzer.sys.columns rc ON rc.object_id=r.object_id AND rc.column_id=fc.referenced_column_id
 WHERE 1=1 ORDER BY t.name,f.name,fc.constraint_column_id FOR JSON PATH,INCLUDE_NULL_VALUES);
SELECT @TargetMetadata=(SELECT t.name table_name,f.name,c.name column_name,r.name referenced_table,rc.name referenced_column,
 f.delete_referential_action,f.update_referential_action,fc.constraint_column_id
 FROM sys.foreign_keys f JOIN sys.tables t ON t.object_id=f.parent_object_id
 JOIN sys.foreign_key_columns fc ON fc.constraint_object_id=f.object_id
 JOIN sys.columns c ON c.object_id=t.object_id AND c.column_id=fc.parent_column_id
 JOIN sys.tables r ON r.object_id=f.referenced_object_id
 JOIN sys.columns rc ON rc.object_id=r.object_id AND rc.column_id=fc.referenced_column_id
 WHERE t.schema_id=SCHEMA_ID(N'analyzer') ORDER BY t.name,f.name,fc.constraint_column_id FOR JSON PATH,INCLUDE_NULL_VALUES);
IF HASHBYTES('SHA2_256',@SourceMetadata)<>HASHBYTES('SHA2_256',@TargetMetadata)
 THROW 58847,'Foreign-key metadata differs.',1;
SELECT @SourceMetadata=(SELECT t.name table_name,d.name,d.definition,c.name column_name
 FROM DBAnalyzer.sys.default_constraints d JOIN DBAnalyzer.sys.tables t ON t.object_id=d.parent_object_id
 JOIN DBAnalyzer.sys.columns c ON c.object_id=t.object_id AND c.column_id=d.parent_column_id
 WHERE 1=1 ORDER BY t.name,d.name FOR JSON PATH,INCLUDE_NULL_VALUES);
SELECT @TargetMetadata=(SELECT t.name table_name,d.name,d.definition,c.name column_name
 FROM sys.default_constraints d JOIN sys.tables t ON t.object_id=d.parent_object_id
 JOIN sys.columns c ON c.object_id=t.object_id AND c.column_id=d.parent_column_id
 WHERE t.schema_id=SCHEMA_ID(N'analyzer') ORDER BY t.name,d.name FOR JSON PATH,INCLUDE_NULL_VALUES);
IF HASHBYTES('SHA2_256',@SourceMetadata)<>HASHBYTES('SHA2_256',@TargetMetadata)
 THROW 58847,'Default constraints differ.',1;
SELECT @SourceMetadata=(SELECT t.name table_name,c.name,c.definition,c.is_disabled,c.is_not_trusted
 FROM DBAnalyzer.sys.check_constraints c JOIN DBAnalyzer.sys.tables t ON t.object_id=c.parent_object_id
 WHERE 1=1 ORDER BY t.name,c.name FOR JSON PATH,INCLUDE_NULL_VALUES);
SELECT @TargetMetadata=(SELECT t.name table_name,c.name,c.definition,c.is_disabled,c.is_not_trusted
 FROM sys.check_constraints c JOIN sys.tables t ON t.object_id=c.parent_object_id
 WHERE t.schema_id=SCHEMA_ID(N'analyzer') ORDER BY t.name,c.name FOR JSON PATH,INCLUDE_NULL_VALUES);
IF HASHBYTES('SHA2_256',@SourceMetadata)<>HASHBYTES('SHA2_256',@TargetMetadata)
 THROW 58847,'Check constraints differ.',1;
DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS;
SELECT * FROM #MigrationVerification ORDER BY table_name;
SELECT N'DATA_AND_STRUCTURE_VERIFIED' result;
DROP TABLE #MigrationVerification;
GO
