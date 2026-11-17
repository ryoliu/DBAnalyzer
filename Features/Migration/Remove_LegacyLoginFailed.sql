-- Run only after a verified backup and a successful analyzer migration.
USE MS_PERF_COLLECTION;
GO
SET XACT_ABORT ON;
IF OBJECT_ID(N'analyzer.LoginFailed',N'U') IS NULL OR OBJECT_ID(N'analyzer.usp_AnalyzeLoginFailed',N'P') IS NULL
 THROW 58850,'The replacement analyzer objects are missing.',1;
IF EXISTS(SELECT 1 FROM sys.sql_expression_dependencies
 WHERE referenced_id=OBJECT_ID(N'dbo.LoginFailed') AND referencing_id<>ISNULL(OBJECT_ID(N'dbo.usp_AnalyzeLoginFailed'),0))
 THROW 58851,'Another object depends on the legacy LoginFailed table.',1;
IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobsteps
 WHERE (database_name=N'MS_PERF_COLLECTION' AND (command LIKE N'%dbo.usp_AnalyzeLoginFailed%' OR command LIKE N'%dbo.LoginFailed%'))
 OR command LIKE N'%MS_PERF_COLLECTION.dbo.LoginFailed%' OR command LIKE N'%MS_PERF_COLLECTION.dbo.usp_AnalyzeLoginFailed%')
 THROW 58852,'A job still references legacy LoginFailed objects.',1;
BEGIN TRY
 BEGIN TRANSACTION;
 DROP PROCEDURE IF EXISTS dbo.usp_AnalyzeLoginFailed;
 DROP TABLE IF EXISTS dbo.LoginFailed;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
GO
