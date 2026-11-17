#requires -Version 7.0
param(
    [pscredential]$Credential,
    [string]$ServerInstance = 'tcp:192.168.56.202,1433'
)

$ErrorActionPreference = 'Stop'
if (-not $Credential) {
    $password = Read-Host 'Password for WIN2019LAB\Administrator' -AsSecureString
    $Credential = [pscredential]::new('WIN2019LAB\Administrator', $password)
}

Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class LoginFailedNetworkLogon {
    [DllImport("advapi32.dll", EntryPoint="LogonUserW", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LogonUser(string user, string domain, string password,
        int logonType, int provider, out SafeAccessTokenHandle token);
}
'@

$token = $null
$networkCredential = $Credential.GetNetworkCredential()
try {
    if (-not [LoginFailedNetworkLogon]::LogonUser($networkCredential.UserName,
        $networkCredential.Domain, $networkCredential.Password, 9, 3, [ref]$token)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }

    [Security.Principal.WindowsIdentity]::RunImpersonated($token, [Action]{
        $settings = [System.Data.SqlClient.SqlConnectionStringBuilder]::new('Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Pooling=False;Connect Timeout=10;Application Name=DBAnalyzer LoginFailed Test;')
        $settings['Data Source'] = $ServerInstance
        $connection = [System.Data.SqlClient.SqlConnection]::new($settings.ConnectionString)
        $schema = 'LoginFailedTest_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $schemaCreated = $false

        function Invoke-TestSql([string]$Sql) {
            $command = $connection.CreateCommand()
            $command.CommandTimeout = 120
            $command.CommandText = $Sql
            try { [void]$command.ExecuteNonQuery() } finally { $command.Dispose() }
        }

        function Get-TestScalar([string]$Sql) {
            $command = $connection.CreateCommand()
            $command.CommandTimeout = 120
            $command.CommandText = $Sql
            try { $command.ExecuteScalar() } finally { $command.Dispose() }
        }

        function Reset-Fixture([string]$Scenario = 'NORMAL') {
            Invoke-TestSql @"
DELETE $schema.LoginFailedSummary;
DELETE $schema.LoginFailed;
DELETE $schema.LoginFailedAnalysisRun;
DELETE $schema.SourceLog;
UPDATE $schema.Control SET scenario='$Scenario', enum_calls=0, read_calls=0;
DECLARE @Day date=DATEADD(DAY,-1,CONVERT(date,GETDATE())), @RunId bigint;
INSERT $schema.LoginFailedAnalysisRun
    (analysis_date,started_at_utc,source_server,source_time_at_start,status)
VALUES (@Day,SYSUTCDATETIME(),N'Test',SYSDATETIMEOFFSET(),'SUCCEEDED');
SET @RunId=SCOPE_IDENTITY();
INSERT $schema.LoginFailed
    (analysis_run_id,analysis_date,log_date,archive_number,login_name,raw_message)
SELECT @RunId,d,CONVERT(datetime,d),0,N'Seed',N'Preserve this seed'
FROM (VALUES(@Day),(DATEADD(DAY,-31,@Day)),(DATEADD(DAY,-28,@Day))) dates(d);
INSERT $schema.LoginFailedSummary
    (analysis_run_id,analysis_date,failure_category,failure_count,
     affected_login_count,affected_client_count,first_failure,last_failure)
SELECT @RunId,analysis_date,'OTHER',1,1,0,log_date,log_date FROM $schema.LoginFailed;
INSERT $schema.SourceLog VALUES
    (0,DATEADD(SECOND,-1,CONVERT(datetime,@Day)),N'Server',N'Coverage witness');
"@
        }

        function Expect-Failure([int]$Number, [string]$Arguments = '') {
            try {
                Invoke-TestSql "DECLARE @Day date=DATEADD(DAY,-1,CONVERT(date,GETDATE())); EXEC $schema.usp_AnalyzeLoginFailed @AnalysisDate=@Day,@ReturnResults=0 $Arguments;"
                throw "Expected SQL error $Number was not raised."
            } catch {
                if ($_.Exception.GetBaseException().Number -ne $Number) { throw }
            }
            Invoke-TestSql @"
IF (SELECT COUNT(*) FROM $schema.LoginFailed)<>3
    OR EXISTS(SELECT 1 FROM $schema.LoginFailed WHERE raw_message<>N'Preserve this seed')
    OR (SELECT COUNT(*) FROM $schema.LoginFailedSummary)<>3
    OR EXISTS(SELECT 1 FROM $schema.LoginFailedSummary WHERE failure_count<>1)
    THROW 57100,'Failed collection changed existing data.',1;
IF (SELECT TOP(1) status FROM $schema.LoginFailedAnalysisRun ORDER BY analysis_run_id DESC)<>'FAILED'
    THROW 57101,'Failure was not recorded.',1;
IF APPLOCK_MODE(N'public',N'DBAnalyzer.LoginFailed',N'Session')<>N'NoLock'
    THROW 57102,'Collection lock was not released.',1;
"@
        }

        try {
            $connection.Open()
            Write-Host (Get-TestScalar @'
SELECT SERVERPROPERTY('ServerName') AS server_name,ORIGINAL_LOGIN() AS login_name,
       SERVERPROPERTY('ProductVersion') AS product_version,HAS_DBACCESS(N'MS_PERF_COLLECTION') AS has_access
FOR JSON PATH,WITHOUT_ARRAY_WRAPPER;
'@)
            Write-Host (Get-TestScalar @'
SELECT COUNT_BIG(*) AS existing_detail_count,MIN(analysis_date) AS first_date,
       MAX(analysis_date) AS last_date FROM MS_PERF_COLLECTION.analyzer.LoginFailed
FOR JSON PATH,WITHOUT_ARRAY_WRAPPER;
'@)
            $historyQuery = @'
SELECT (SELECT analysis_date,COUNT_BIG(*) AS failure_count
FROM MS_PERF_COLLECTION.analyzer.LoginFailed
WHERE analysis_date>=DATEADD(DAY,-29,CONVERT(date,GETDATE()))
GROUP BY analysis_date ORDER BY analysis_date FOR JSON PATH) AS history_json;
'@
            $existingHistory = Get-TestScalar $historyQuery
            $existingProcedure = Get-TestScalar "SELECT CONVERT(varchar(64),HASHBYTES('SHA2_256',definition),2) FROM MS_PERF_COLLECTION.sys.sql_modules WHERE object_id=OBJECT_ID(N'MS_PERF_COLLECTION.analyzer.usp_AnalyzeLoginFailed');"
            Invoke-TestSql 'USE tempdb;'
            Invoke-TestSql "CREATE SCHEMA $schema;"
            $schemaCreated = $true
            $deployment = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Deploy_DBAnalyzer_LoginFailed.sql') -Raw
            $deployment = $deployment.Replace('USE MS_PERF_COLLECTION;', 'USE tempdb;')
            foreach ($name in @('LoginFailedAnalysisRun','LoginFailedSummary','vLoginFailedClassified','usp_AnalyzeLoginFailed','LoginFailed')) {
                $deployment = $deployment.Replace('analyzer.' + $name, $schema + '.' + $name)
            }
            $batches = [regex]::Split($deployment, '(?im)^\s*GO\s*\r?$')
            foreach ($batch in $batches) {
                if (-not [string]::IsNullOrWhiteSpace($batch)) { Invoke-TestSql $batch }
            }
            Write-Host 'PASS: deploy actual source to isolated tempdb schema'

            try {
                Invoke-TestSql "EXEC $schema.usp_AnalyzeLoginFailed @ReturnResults=0;"
                $liveCount = Get-TestScalar "SELECT COUNT_BIG(*) FROM $schema.LoginFailed;"
                Invoke-TestSql "EXEC $schema.usp_AnalyzeLoginFailed @ReturnResults=0;"
                if ((Get-TestScalar "SELECT COUNT_BIG(*) FROM $schema.LoginFailed;") -ne $liveCount) {
                    throw 'Live collection changed count on repeat.'
                }
                Write-Host "PASS: live ERRORLOG, configured audit check and repeat ($liveCount details)"
            } catch {
                if ($_.Exception.GetBaseException().Number -ne 56009) { throw }
                Write-Host 'LIMITATION: live ERRORLOG does not cover yesterday; live collection correctly refused'
            }

            foreach ($date in ($existingHistory | ConvertFrom-Json)) {
                $analysisDate = ([datetime]$date.analysis_date).ToString('yyyyMMdd')
                try {
                    Invoke-TestSql "EXEC $schema.usp_AnalyzeLoginFailed @AnalysisDate='$analysisDate',@ReturnResults=0;"
                    $actualCount = Get-TestScalar "SELECT COUNT_BIG(*) FROM $schema.LoginFailed WHERE analysis_date='$analysisDate';"
                    if ($actualCount -ne $date.failure_count) { throw "Live history count mismatch for $analysisDate." }
                    Invoke-TestSql @"
IF EXISTS(
 SELECT log_date,login_name,client_address,failure_reason,error_number,severity,error_state,raw_message,COUNT_BIG(*) AS copies
 FROM MS_PERF_COLLECTION.analyzer.LoginFailed WHERE analysis_date='$analysisDate'
 GROUP BY log_date,login_name,client_address,failure_reason,error_number,severity,error_state,raw_message
 EXCEPT
 SELECT log_date,login_name,client_address,failure_reason,error_number,severity,error_state,raw_message,COUNT_BIG(*)
 FROM $schema.LoginFailed WHERE analysis_date='$analysisDate'
 GROUP BY log_date,login_name,client_address,failure_reason,error_number,severity,error_state,raw_message)
 THROW 57113,'Live history parsing differs from existing details.',1;
"@
                    Write-Host "PASS: live history $analysisDate ($actualCount details), parsing matches existing data"
                } catch {
                    if ($_.Exception.GetBaseException().Number -ne 56009) { throw }
                    Write-Host "LIMITATION: ERRORLOG no longer covers $analysisDate; existing source cannot be replayed"
                }
            }

            Invoke-TestSql @"
CREATE TABLE $schema.Control(scenario varchar(32),enum_calls int,read_calls int);
INSERT $schema.Control VALUES('NORMAL',0,0);
CREATE TABLE $schema.SourceLog
    (archive_number int,log_date datetime,process_info nvarchar(50),log_text nvarchar(max));
"@
            Invoke-TestSql @"
CREATE PROCEDURE $schema.EnumArchives AS
BEGIN
    SET NOCOUNT ON;
    UPDATE $schema.Control SET enum_calls=enum_calls+1;
    SELECT 0 AS archive_number,CONVERT(datetime,CONVERT(date,GETDATE())) AS log_date,CONVERT(bigint,10000) AS log_size
    UNION ALL
    SELECT CASE WHEN scenario='GAP' THEN 2 ELSE 1 END,
           CONVERT(datetime,DATEADD(DAY,-1,CONVERT(date,GETDATE()))),
           CONVERT(bigint,CASE WHEN scenario='ROTATION' THEN enum_calls*100 ELSE 100 END)
    FROM $schema.Control;
END;
"@
            Invoke-TestSql @"
CREATE PROCEDURE $schema.ReadErrorLog
    @Archive int,@LogType int,@Search1 nvarchar(4000)=NULL,@Search2 nvarchar(4000)=NULL,
    @From datetime=NULL,@To datetime=NULL,@Sort nvarchar(4)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE $schema.Control SET read_calls=read_calls+1;
    IF EXISTS(SELECT 1 FROM $schema.Control WHERE scenario='READ_FAIL')
        THROW 57001,'Injected read failure.',1;
    SELECT log_date,process_info,log_text FROM $schema.SourceLog
    WHERE archive_number=@Archive AND (@From IS NULL OR log_date>=@From) AND (@To IS NULL OR log_date<=@To)
      AND NOT EXISTS(SELECT 1 FROM $schema.Control WHERE scenario='RESET_CURRENT' AND read_calls>1)
    ORDER BY log_date;
END;
"@
            $procedure = $batches | Where-Object { $_ -match 'CREATE OR ALTER PROCEDURE' }
            $procedure = $procedure.Replace('master.dbo.sp_enumerrorlogs', "$schema.EnumArchives").Replace('master.dbo.xp_readerrorlog', "$schema.ReadErrorLog")
            Invoke-TestSql $procedure

            Reset-Fixture
            Invoke-TestSql @"
DECLARE @Day datetime=DATEADD(DAY,-1,CONVERT(date,GETDATE()));
INSERT $schema.SourceLog VALUES
 (0,@Day,N'Logon',N'Login failed for user ''NoReason''. [CLIENT: 10.0.0.1]'),
 (0,DATEADD(MINUTE,1,@Day),N'Logon',N'Error: 18456, Severity: 14, State: 8.'),
 (0,DATEADD(MINUTE,1,@Day),N'Logon',N'Login failed for user ''O''Brien''. Reason: Password did not match that for the login provided. [CLIENT: 10.0.0.2]'),
 (0,DATEADD(MINUTE,2,@Day),N'Logon',N'Error: 18456, Severity: 14, State: 8.'),
 (0,DATEADD(MINUTE,2,@Day),N'Logon',N'Error: 18456, Severity: 14, State: 5.'),
 (0,DATEADD(MINUTE,2,@Day),N'Logon',N'Login failed for user ''Ambiguous''. [CLIENT: 10.0.0.3]'),
 (0,DATEADD(MINUTE,2,@Day),N'Logon',N'Login failed for user ''Ambiguous''. [CLIENT: 10.0.0.3]'),
 (0,DATEADD(MINUTE,3,@Day),N'Logon',N'Login failed for user ''''. [CLIENT: <local machine>]'),
 (0,DATEADD(MINUTE,4,@Day),N'Logon',N'Login failed for user ''Malformed. [CLIENT: 10.0.0.4]'),
 (0,DATEADD(DAY,1,@Day),N'Logon',N'Login failed for user ''NextDay''.');
EXEC $schema.usp_AnalyzeLoginFailed @AnalysisDate=@Day,@ReturnResults=0;
IF (SELECT COUNT(*) FROM $schema.LoginFailed WHERE analysis_date=CONVERT(date,@Day))<>6
    THROW 57103,'Wrong detail count or date boundary.',1;
IF NOT EXISTS(SELECT 1 FROM $schema.LoginFailed WHERE login_name=N'NoReason' AND failure_reason IS NULL AND client_address=N'10.0.0.1')
    THROW 57104,'Missing Reason parsing failed.',1;
IF NOT EXISTS(SELECT 1 FROM $schema.vLoginFailedClassified WHERE login_name=N'O''Brien' AND error_number=18456 AND severity=14 AND error_state=8 AND failure_category='PASSWORD_MISMATCH')
    THROW 57105,'Quoted login or header parsing failed.',1;
IF (SELECT COUNT(*) FROM $schema.LoginFailed WHERE login_name=N'Ambiguous' AND error_state IS NULL)<>2
    THROW 57106,'Ambiguous headers or duplicate events were mishandled.',1;
IF NOT EXISTS(SELECT 1 FROM $schema.LoginFailed WHERE login_name=N'' AND client_address=N'<local machine>')
    OR NOT EXISTS(SELECT 1 FROM $schema.LoginFailed WHERE login_name IS NULL AND raw_message LIKE N'%Malformed%')
    THROW 57107,'Empty or malformed login parsing failed.',1;
IF EXISTS(SELECT 1 FROM $schema.LoginFailed WHERE analysis_date<DATEADD(DAY,-29,CONVERT(date,GETDATE())))
    OR EXISTS(SELECT 1 FROM $schema.LoginFailedSummary WHERE analysis_date<DATEADD(DAY,-29,CONVERT(date,GETDATE())))
    OR NOT EXISTS(SELECT 1 FROM $schema.LoginFailed WHERE analysis_date=DATEADD(DAY,-29,CONVERT(date,GETDATE())))
    OR NOT EXISTS(SELECT 1 FROM $schema.LoginFailedSummary WHERE analysis_date=DATEADD(DAY,-29,CONVERT(date,GETDATE())))
    OR NOT EXISTS(SELECT 1 FROM $schema.LoginFailedAnalysisRun WHERE source_server=N'Test')
    THROW 57108,'Retention boundary or run-history preservation failed.',1;
EXEC $schema.usp_AnalyzeLoginFailed @AnalysisDate=@Day,@ReturnResults=0;
IF (SELECT COUNT(*) FROM $schema.LoginFailed WHERE analysis_date=CONVERT(date,@Day))<>6
    OR (SELECT SUM(failure_count) FROM $schema.LoginFailedSummary WHERE analysis_date=CONVERT(date,@Day))<>6
    THROW 57109,'Repeat collection accumulated details or summaries.',1;
"@
            Write-Host 'PASS: parsing, unique headers, duplicate preservation, date boundary, retention and repeat'

            Reset-Fixture
            Invoke-TestSql "DECLARE @Day date=DATEADD(DAY,-1,CONVERT(date,GETDATE())); EXEC $schema.usp_AnalyzeLoginFailed @AnalysisDate=@Day,@ReturnResults=0; IF EXISTS(SELECT 1 FROM $schema.LoginFailed WHERE analysis_date=DATEADD(DAY,-1,CONVERT(date,GETDATE()))) OR EXISTS(SELECT 1 FROM $schema.LoginFailedSummary WHERE analysis_date=DATEADD(DAY,-1,CONVERT(date,GETDATE()))) THROW 57110,'Complete zero-event collection did not replace old data.',1;"
            Write-Host 'PASS: complete source with zero failures'

            Reset-Fixture 'INCOMPLETE'
            Invoke-TestSql "DELETE $schema.SourceLog;"
            Expect-Failure 56009
            Write-Host 'PASS: incomplete source preserves existing details, summary and expired data'

            Reset-Fixture 'CAP'
            Invoke-TestSql "UPDATE $schema.SourceLog SET archive_number=1;"
            Expect-Failure 56009 ', @MaxArchiveNo=0'
            Write-Host 'PASS: insufficient archive cap preserves existing data'

            foreach ($test in @(@('READ_FAIL',57001),@('ROTATION',56010),@('RESET_CURRENT',56010),@('GAP',56008))) {
                Reset-Fixture $test[0]
                if ($test[0] -eq 'GAP') { Invoke-TestSql "DELETE $schema.SourceLog;" }
                Expect-Failure $test[1]
                Write-Host ('PASS: ' + $test[0] + ' preserves existing data and records failure')
            }

            Reset-Fixture
            Invoke-TestSql @"
DECLARE @Day datetime=DATEADD(DAY,-1,CONVERT(date,GETDATE()));
UPDATE $schema.SourceLog SET archive_number=1;
INSERT $schema.SourceLog VALUES
 (0,@Day,N'Logon',N'Login failed for user ''MidnightA''.'),
 (1,@Day,N'Logon',N'Login failed for user ''MidnightB''.');
EXEC $schema.usp_AnalyzeLoginFailed @AnalysisDate=@Day,@ReturnResults=0;
IF (SELECT COUNT(*) FROM $schema.LoginFailed WHERE analysis_date=CONVERT(date,@Day))<>2
    THROW 57111,'Midnight ties in adjacent archives were lost.',1;
"@
            Write-Host 'PASS: midnight ties across adjacent archives'

            Reset-Fixture
            Invoke-TestSql "CREATE TRIGGER $schema.FailSummary ON $schema.LoginFailedSummary AFTER INSERT AS THROW 57002,'Injected write failure.',1;"
            try { Expect-Failure 57002 } finally { Invoke-TestSql "DROP TRIGGER $schema.FailSummary;" }
            Write-Host 'PASS: write failure rolls back details, summary and retention; releases lock'

            Reset-Fixture
            $lockConnection = [System.Data.SqlClient.SqlConnection]::new($settings.ConnectionString)
            try {
                $lockConnection.Open()
                $lockCommand = $lockConnection.CreateCommand()
                try {
                    $lockCommand.CommandText = "USE tempdb; DECLARE @Result int; EXEC @Result=sys.sp_getapplock @Resource=N'DBAnalyzer.LoginFailed',@LockMode=N'Exclusive',@LockOwner=N'Session',@LockTimeout=0,@DbPrincipal=N'public'; IF @Result<0 THROW 57112,'Test could not acquire collection lock.',1;"
                    [void]$lockCommand.ExecuteNonQuery()
                    Expect-Failure 56007
                } finally { $lockCommand.Dispose() }
            } finally { $lockConnection.Dispose() }
            Write-Host 'PASS: concurrent collection refuses immediately and preserves existing data'
            if ((Get-TestScalar $historyQuery) -ne $existingHistory -or
                (Get-TestScalar "SELECT CONVERT(varchar(64),HASHBYTES('SHA2_256',definition),2) FROM MS_PERF_COLLECTION.sys.sql_modules WHERE object_id=OBJECT_ID(N'MS_PERF_COLLECTION.analyzer.usp_AnalyzeLoginFailed');") -ne $existingProcedure) {
                throw 'Existing analyzer history or procedure changed during testing.'
            }
            Write-Host 'PASS: existing analyzer history counts and procedure definition are unchanged'
        } finally {
            if ($schemaCreated -and $connection.State -eq 'Open') {
                Invoke-TestSql @"
DROP PROCEDURE $schema.usp_AnalyzeLoginFailed;
IF OBJECT_ID(N'$schema.ReadErrorLog',N'P') IS NOT NULL DROP PROCEDURE $schema.ReadErrorLog;
IF OBJECT_ID(N'$schema.EnumArchives',N'P') IS NOT NULL DROP PROCEDURE $schema.EnumArchives;
DROP VIEW $schema.vLoginFailedClassified;
DROP TABLE $schema.LoginFailedSummary;
DROP TABLE $schema.LoginFailed;
DROP TABLE $schema.LoginFailedAnalysisRun;
IF OBJECT_ID(N'$schema.SourceLog',N'U') IS NOT NULL DROP TABLE $schema.SourceLog;
IF OBJECT_ID(N'$schema.Control',N'U') IS NOT NULL DROP TABLE $schema.Control;
DROP SCHEMA $schema;
"@
                Write-Host 'CLEANUP: isolated test schema removed; analyzer objects were not changed'
            }
            $connection.Dispose()
        }
    })
} finally {
    if ($token) { $token.Dispose() }
}
