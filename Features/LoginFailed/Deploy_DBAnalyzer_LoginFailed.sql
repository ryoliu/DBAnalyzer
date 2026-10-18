
USE DBAnalyzer;
GO
IF OBJECT_ID(N'dbo.LoginFailedAnalysisRun',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.LoginFailedAnalysisRun(
  analysis_run_id bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
  analysis_date date NOT NULL,
  started_at_utc datetime2(3) NOT NULL,
  completed_at_utc datetime2(3) NULL,
  source_server nvarchar(128) NOT NULL,
  source_time_at_start datetimeoffset(3) NOT NULL,
  status varchar(10) NOT NULL CHECK(status IN('RUNNING','SUCCEEDED','FAILED')),
  audit_level nvarchar(128) NULL,
  archives_scanned int NULL,
  failed_login_count bigint NULL,
  error_number int NULL,
  error_message nvarchar(4000) NULL);
 CREATE INDEX IX_LoginFailedRun_Date ON dbo.LoginFailedAnalysisRun(analysis_date,analysis_run_id);
END;
GO
IF OBJECT_ID(N'dbo.LoginFailed',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.LoginFailed(
  login_failed_id bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
  analysis_run_id bigint NOT NULL REFERENCES dbo.LoginFailedAnalysisRun(analysis_run_id),
  analysis_date date NOT NULL,
  log_date datetime NOT NULL,
  archive_number int NOT NULL,
  process_info nvarchar(50) NULL,
  login_name nvarchar(256) NULL,
  client_address nvarchar(256) NULL,
  failure_reason nvarchar(max) NULL,
  error_number int NULL,
  severity int NULL,
  error_state int NULL,
  error_header nvarchar(max) NULL,
  raw_message nvarchar(max) NOT NULL);
 CREATE INDEX IX_LoginFailed_Date ON dbo.LoginFailed(analysis_date,log_date);
END;
GO

IF OBJECT_ID(N'dbo.LoginFailedSummary',N'U') IS NULL
BEGIN
 CREATE TABLE dbo.LoginFailedSummary(
  summary_id bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
  analysis_run_id bigint NOT NULL REFERENCES dbo.LoginFailedAnalysisRun(analysis_run_id),
  analysis_date date NOT NULL,
  failure_category varchar(48) NOT NULL,
  error_number int NULL,
  error_state int NULL,
  failure_count bigint NOT NULL,
  affected_login_count int NOT NULL,
  affected_client_count int NOT NULL,
  first_failure datetime NOT NULL,
  last_failure datetime NOT NULL,
  sample_failure_reason nvarchar(4000) NULL);
 CREATE UNIQUE INDEX UX_LoginFailedSummary_Group
 ON dbo.LoginFailedSummary(analysis_date,failure_category,error_number,error_state);
END;
GO
CREATE OR ALTER VIEW dbo.vLoginFailedClassified
AS
SELECT f.*,CONVERT(varchar(48),CASE
 WHEN r.reason_text LIKE N'%failed to open%database%'
   OR r.reason_text LIKE N'%cannot open%database%'
   OR r.reason_text LIKE N'%could not find%database%'
   OR f.error_number IN(4060,4064) THEN 'DATABASE_ACCESS_FAILED'
 WHEN r.reason_text LIKE N'%account%locked%' THEN 'ACCOUNT_LOCKED'
 WHEN r.reason_text LIKE N'%login%disabled%'
   OR r.reason_text LIKE N'%account%disabled%' THEN 'LOGIN_DISABLED'
 WHEN r.reason_text LIKE N'%password%expired%' THEN 'PASSWORD_EXPIRED'
 WHEN r.reason_text LIKE N'%password%must be changed%'
   OR r.reason_text LIKE N'%must change%password%' THEN 'PASSWORD_CHANGE_REQUIRED'
 WHEN r.reason_text LIKE N'%server is configured for windows authentication only%'
   THEN 'AUTHENTICATION_MODE_MISMATCH'
 WHEN r.reason_text LIKE N'%could not find a login matching%'
   OR r.reason_text LIKE N'%login does not exist%'
   OR r.reason_text LIKE N'%user id%not valid%' THEN 'LOGIN_NOT_FOUND'
 WHEN f.error_number=18456 AND f.error_state=7 THEN 'LOGIN_DISABLED_OR_BAD_PASSWORD'
 WHEN r.reason_text LIKE N'%password did not match%'
   OR r.reason_text LIKE N'%password is incorrect%'
   OR r.reason_text LIKE N'%password is invalid%' THEN 'PASSWORD_MISMATCH'
 WHEN r.reason_text LIKE N'%server access validation failed%'
   OR r.reason_text LIKE N'%server access failed%'
   OR r.reason_text LIKE N'%connect sql%denied%' THEN 'SERVER_ACCESS_FAILED'
 WHEN r.reason_text LIKE N'%untrusted domain%'
   OR r.reason_text LIKE N'%sspi%'
   OR r.reason_text LIKE N'%windows authentication%failed%' THEN 'WINDOWS_AUTHENTICATION_FAILED'
 WHEN f.error_number=18456 AND f.error_state IN(2,5) THEN 'LOGIN_NOT_FOUND'
 WHEN f.error_number=18456 AND f.error_state IN(8,9) THEN 'PASSWORD_MISMATCH'
 WHEN f.error_number=18456 AND f.error_state=18 THEN 'PASSWORD_CHANGE_REQUIRED'
 WHEN f.error_number=18456 AND f.error_state IN(38,46,126) THEN 'DATABASE_ACCESS_FAILED'
 WHEN f.error_number=18456 AND f.error_state IN(11,12) THEN 'SERVER_ACCESS_FAILED'
 WHEN f.error_number=18456 AND f.error_state=6 THEN 'AUTHENTICATION_METHOD_MISMATCH'
 WHEN f.error_number=18456 AND f.error_state=58 THEN 'AUTHENTICATION_CONFIGURATION'
 WHEN f.error_number=18456 AND f.error_state=62 THEN 'CONTAINED_USER_SID_MISMATCH'
 ELSE 'OTHER' END) AS failure_category
FROM dbo.LoginFailed f
CROSS APPLY(SELECT LOWER(COALESCE(NULLIF(f.failure_reason,N''),f.raw_message,N'')) COLLATE Latin1_General_100_CI_AS AS reason_text) r;
GO

CREATE OR ALTER PROCEDURE dbo.usp_AnalyzeLoginFailed
    @AnalysisDate date = NULL,
    @ReturnResults bit = 1,
    @AnalysisRunId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @AnalysisRunId = NULL;

    IF @@TRANCOUNT <> 0
        THROW 56000, 'Execute outside an existing transaction.', 1;
    IF @AnalysisDate IS NULL
        SET @AnalysisDate = DATEADD(DAY, -1, CONVERT(date, GETDATE()));
    IF @AnalysisDate > CONVERT(date, GETDATE())
        THROW 56001, 'AnalysisDate must not be in the future.', 1;

    DECLARE @FromTime datetime = CONVERT(datetime, @AnalysisDate);
    DECLARE @ToTime datetime = DATEADD(DAY, 1, @FromTime);
    DECLARE @LogNumber int, @LastLogNumber int, @ArchivesScanned int = 0;
    DECLARE @FailureCount bigint, @AuditLevel nvarchar(128);

    BEGIN TRY
        -- 1. Record the run and check login auditing.
        INSERT dbo.LoginFailedAnalysisRun
            (analysis_date, started_at_utc, source_server, source_time_at_start, status)
        VALUES
            (@AnalysisDate, SYSUTCDATETIME(), CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')),
             SYSDATETIMEOFFSET(), 'RUNNING');
        SET @AnalysisRunId = CONVERT(bigint, SCOPE_IDENTITY());

        CREATE TABLE #AuditLevel (config_name nvarchar(128), config_value nvarchar(128));
        INSERT #AuditLevel EXEC master.dbo.xp_loginconfig N'audit level';
        SELECT @AuditLevel = config_value FROM #AuditLevel WHERE config_name = N'audit level';
        UPDATE dbo.LoginFailedAnalysisRun SET audit_level = @AuditLevel
        WHERE analysis_run_id = @AnalysisRunId;
        IF @AuditLevel IS NULL OR LOWER(@AuditLevel) NOT IN (N'failure', N'all')
            THROW 56002, 'Login auditing must include failed logins.', 1;

        -- 2. Read current and archived ERRORLOG files.
        CREATE TABLE #Archives (archive_number int, log_date nvarchar(128), log_size bigint);
        INSERT #Archives EXEC master.dbo.sp_enumerrorlogs;
        IF NOT EXISTS (SELECT 1 FROM #Archives)
            THROW 56003, 'No SQL Server error logs were enumerated.', 1;

        CREATE TABLE #Log (log_date datetime, process_info nvarchar(50), log_text nvarchar(max));
        CREATE TABLE #Messages
            (archive_number int, log_date datetime, process_info nvarchar(50), log_text nvarchar(max));
        SELECT @LogNumber = MIN(archive_number), @LastLogNumber = MAX(archive_number) FROM #Archives;

        WHILE @LogNumber <= @LastLogNumber
        BEGIN
            IF EXISTS (SELECT 1 FROM #Archives WHERE archive_number = @LogNumber)
            BEGIN
                TRUNCATE TABLE #Log;
                INSERT #Log
                    EXEC master.dbo.xp_readerrorlog @LogNumber, 1, NULL, NULL, @FromTime, @ToTime, N'asc';
                INSERT #Messages
                SELECT @LogNumber, log_date, process_info, log_text
                FROM #Log
                WHERE log_date >= @FromTime AND log_date < @ToTime
                  AND (log_text LIKE N'Login failed for user %'
                       OR log_text LIKE N'Error: %, Severity: %, State: %.');
                SET @ArchivesScanned = @ArchivesScanned + 1;
            END;
            SET @LogNumber = @LogNumber + 1;
        END;

        -- 3. Extract account, client and reason using named string positions.
        SELECT *,
            LEN(N'Login failed for user ''') + 1 AS login_start,
            CHARINDEX(N'. Reason:', log_text) AS reason_at,
            CHARINDEX(N'. Reason:', log_text) + LEN(N'. Reason:') AS reason_start,
            CHARINDEX(N'[CLIENT:', log_text) AS client_at,
            CHARINDEX(N']', log_text, CHARINDEX(N'[CLIENT:', log_text)) AS client_end,
            CONVERT(nvarchar(max), NULL) AS login_name,
            CONVERT(nvarchar(max), NULL) AS client_address,
            CONVERT(nvarchar(max), NULL) AS failure_reason,
            CONVERT(nvarchar(max), NULL) AS error_header,
            CONVERT(int, NULL) AS error_number,
            CONVERT(int, NULL) AS severity,
            CONVERT(int, NULL) AS error_state
        INTO #Failures
        FROM #Messages
        WHERE log_text LIKE N'Login failed for user %';

        UPDATE #Failures
        SET login_name = SUBSTRING(log_text, login_start, reason_at - login_start - 1)
        WHERE reason_at > login_start + 1;

        UPDATE #Failures
        SET client_address = LTRIM(RTRIM(SUBSTRING(log_text, client_at + LEN(N'[CLIENT:'),
                             client_end - client_at - LEN(N'[CLIENT:'))))
        WHERE client_at > 0 AND client_end > client_at + LEN(N'[CLIENT:');

        UPDATE #Failures
        SET failure_reason = LTRIM(RTRIM(SUBSTRING(log_text, reason_start,
            CASE WHEN client_at > reason_at THEN client_at ELSE LEN(log_text) + 1 END - reason_start)))
        WHERE reason_at > 0;

        -- 4. Attach a header only when both message and header are unambiguous.
        SELECT archive_number, log_date, process_info,
            MAX(CASE WHEN log_text LIKE N'Error: %, Severity: %, State: %.' THEN log_text END) AS error_header
        INTO #Headers
        FROM #Messages
        GROUP BY archive_number, log_date, process_info
        HAVING SUM(CASE WHEN log_text LIKE N'Login failed for user %' THEN 1 ELSE 0 END) = 1
           AND SUM(CASE WHEN log_text LIKE N'Error: %, Severity: %, State: %.' THEN 1 ELSE 0 END) = 1;

        -- Name each position before extracting the header values.
        SELECT *,
            CHARINDEX(N',', error_header) AS error_end,
            CHARINDEX(N'Severity:', error_header) + LEN(N'Severity:') AS severity_start,
            CHARINDEX(N', State:', error_header) AS severity_end,
            CHARINDEX(N'State:', error_header) + LEN(N'State:') AS state_start
        INTO #HeaderPositions
        FROM #Headers;

        UPDATE f
        SET error_header = h.error_header,
            error_number = TRY_CONVERT(int, REPLACE(LEFT(h.error_header, h.error_end - 1), N'Error:', N'')),
            severity = TRY_CONVERT(int, SUBSTRING(h.error_header, h.severity_start,
                                                 h.severity_end - h.severity_start)),
            error_state = TRY_CONVERT(int, REPLACE(SUBSTRING(h.error_header, h.state_start,
                                                            LEN(h.error_header)), N'.', N''))
        FROM #Failures f JOIN #HeaderPositions h
          ON h.archive_number = f.archive_number AND h.log_date = f.log_date
         AND h.process_info = f.process_info;

        -- 5. Replace this date's details and summary in one transaction.
        BEGIN TRANSACTION;
        DELETE FROM dbo.LoginFailed WHERE analysis_date = @AnalysisDate;
        INSERT dbo.LoginFailed
            (analysis_run_id, analysis_date, log_date, archive_number, process_info,
             login_name, client_address, failure_reason, error_number, severity, error_state, error_header, raw_message)
        SELECT @AnalysisRunId, @AnalysisDate, log_date, archive_number, process_info,
               CONVERT(nvarchar(256), login_name), CONVERT(nvarchar(256), client_address),
               failure_reason, error_number, severity, error_state, error_header, log_text
        FROM #Failures;
        SET @FailureCount = @@ROWCOUNT;

        DELETE FROM dbo.LoginFailedSummary WHERE analysis_date = @AnalysisDate;
        INSERT dbo.LoginFailedSummary
            (analysis_run_id, analysis_date, failure_category, error_number, error_state,
             failure_count, affected_login_count, affected_client_count, first_failure, last_failure, sample_failure_reason)
        SELECT @AnalysisRunId, analysis_date, failure_category, error_number, error_state,
               COUNT_BIG(*), COUNT(DISTINCT NULLIF(login_name, N'')),
               COUNT(DISTINCT NULLIF(client_address, N'')), MIN(log_date), MAX(log_date),
               MIN(CONVERT(nvarchar(4000), failure_reason))
        FROM dbo.vLoginFailedClassified
        WHERE analysis_date = @AnalysisDate
        GROUP BY analysis_date, failure_category, error_number, error_state;

        UPDATE dbo.LoginFailedAnalysisRun
        SET status = 'SUCCEEDED', completed_at_utc = SYSUTCDATETIME(),
            archives_scanned = @ArchivesScanned, failed_login_count = @FailureCount
        WHERE analysis_run_id = @AnalysisRunId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        IF @AnalysisRunId IS NOT NULL
            UPDATE dbo.LoginFailedAnalysisRun
            SET status = 'FAILED', completed_at_utc = SYSUTCDATETIME(),
                error_number = ERROR_NUMBER(), error_message = ERROR_MESSAGE()
            WHERE analysis_run_id = @AnalysisRunId;
        THROW;
    END CATCH;

    IF @ReturnResults = 1
    BEGIN
        SELECT * FROM dbo.LoginFailedAnalysisRun WHERE analysis_run_id = @AnalysisRunId;
        SELECT * FROM dbo.LoginFailed WHERE analysis_date = @AnalysisDate ORDER BY log_date, login_failed_id;
        SELECT * FROM dbo.LoginFailedSummary WHERE analysis_date = @AnalysisDate
        ORDER BY failure_count DESC, failure_category, error_number, error_state;
    END;
END;
GO




-- Initialize summaries from already collected details without rereading ERRORLOG.
IF NOT EXISTS(SELECT 1 FROM dbo.LoginFailedSummary)
BEGIN
 INSERT dbo.LoginFailedSummary(analysis_run_id,analysis_date,failure_category,error_number,error_state,
 failure_count,affected_login_count,affected_client_count,first_failure,last_failure,sample_failure_reason)
 SELECT MAX(analysis_run_id),analysis_date,failure_category,error_number,error_state,COUNT_BIG(*),COUNT(DISTINCT NULLIF(login_name,N'')),
 COUNT(DISTINCT NULLIF(client_address,N'')),MIN(log_date),MAX(log_date),
 MIN(CONVERT(nvarchar(4000),failure_reason))
 FROM dbo.vLoginFailedClassified
 GROUP BY analysis_date,failure_category,error_number,error_state;
END;
GO
