#requires -Version 7.0
param([switch]$LiveRequest)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $projectRoot 'Tools\LabCredential.ps1')
$credential = [DBAnalyzerLabCredential]::Load()
if (-not $credential) { throw 'The authorized lab credential is missing.' }
$credential = [pscredential]::new($credential.UserName,
    (ConvertTo-SecureString $credential.Password -AsPlainText -Force)).GetNetworkCredential()

if (-not ('LongRunningLogon' -as [type])) {
    Add-Type @'
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class LongRunningLogon {
    [DllImport("advapi32.dll", EntryPoint="LogonUserW", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LogonUser(string user, string domain, string password,
        int type, int provider, out SafeAccessTokenHandle token);
}
'@
}

$token = $null
try {
    if (-not [LongRunningLogon]::LogonUser($credential.UserName, $credential.Domain,
        $credential.Password, 9, 3, [ref]$token)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    [Security.Principal.WindowsIdentity]::RunImpersonated($token, [Action]{
        $connection = [System.Data.SqlClient.SqlConnection]::new(
            'Server=tcp:192.168.56.202,1433;Database=MS_PERF_COLLECTION;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Pooling=False;Connect Timeout=15')
        $schema = 'LongRunningTest_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $schemaCreated = $false
        function Invoke-Sql([string]$Sql) {
            $command = $connection.CreateCommand()
            $command.CommandText = $Sql
            $command.CommandTimeout = 120
            try {
                $reader = $command.ExecuteReader()
                try {
                    do {
                        while ($reader.Read()) {
                            $values = for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                                $reader.GetName($i) + '=' + $reader.GetValue($i)
                            }
                            Write-Host ($values -join '; ')
                        }
                    } while ($reader.NextResult())
                } finally { $reader.Dispose() }
            } finally { $command.Dispose() }
        }
        try {
            $connection.Open()
            Invoke-Sql @'
SELECT SERVERPROPERTY('ServerName') server_name, ORIGINAL_LOGIN() original_login,
       HAS_DBACCESS(N'MS_PERF_COLLECTION') collection_access, GETDATE() server_time;
IF CONVERT(nvarchar(128),SERVERPROPERTY('ServerName'))<>N'WIN2019LAB'
    THROW 58940,'This test is restricted to WIN2019LAB.',1;
'@
            $command = $connection.CreateCommand()
            $command.CommandText = "SELECT OBJECT_DEFINITION(OBJECT_ID(N'analyzer.usp_AnalyzeWhoIsActiveLongRunning'));"
            try { $procedure = $command.ExecuteScalar() } finally { $command.Dispose() }
            if ($procedure -isnot [string]) { throw 'The deployed LongRunning procedure is missing.' }
            if (-not $procedure.Contains('DECLARE @RunTime datetime = GETDATE();')) {
                throw 'The deployed procedure clock declaration has changed. Review the test clock replacement.'
            }

            Invoke-Sql 'USE tempdb;'
            Invoke-Sql "CREATE SCHEMA $schema;"
            $schemaCreated = $true
            Invoke-Sql "SELECT TOP(0) * INTO $schema.WHOISACTIVE FROM MS_PERF_COLLECTION.dbo.WHOISACTIVE;"
            $deployment = Get-Content (Join-Path $projectRoot 'Features\LongRunning\Deploy_DBAnalyzer_LongRunning.sql') -Raw
            foreach ($batch in [regex]::Split($deployment, '(?im)^\s*GO\s*\r?$')) {
                if ([string]::IsNullOrWhiteSpace($batch) -or $batch -match 'CREATE OR ALTER PROCEDURE') { continue }
                Invoke-Sql $batch.Replace('USE MS_PERF_COLLECTION;', 'USE tempdb;').Replace('analyzer.', "$schema.")
            }
            Invoke-Sql "CREATE TABLE $schema.Clock(run_time datetime NOT NULL); INSERT $schema.Clock VALUES(GETDATE());"
            $procedure = $procedure.Replace('DECLARE @RunTime datetime = GETDATE();', "DECLARE @RunTime datetime = (SELECT run_time FROM $schema.Clock);")
            Invoke-Sql $procedure.Replace('analyzer.', "$schema.").Replace('dbo.WHOISACTIVE', "$schema.WHOISACTIVE")
            $tests = Get-Content (Join-Path $PSScriptRoot 'LongRunningSQL_Cases.sql') -Raw
            Invoke-Sql $tests.Replace('{{schema}}', $schema)

            Invoke-Sql 'USE MS_PERF_COLLECTION;'
            if ($LiveRequest) {
                $liveProgram = 'DBAnalyzer LongRunning Test ' + [guid]::NewGuid().ToString('N')
                $testConnection = [System.Data.SqlClient.SqlConnection]::new(
                    $connection.ConnectionString + ';Application Name=' + $liveProgram)
                $testCommand = $null
                try {
                    $testConnection.Open()
                    $testCommand = $testConnection.CreateCommand()
                    $testCommand.CommandText = 'SELECT @@SPID;'
                    $testSession = [int]$testCommand.ExecuteScalar()
                    $testCommand.CommandText = "WAITFOR DELAY '00:00:45';"
                    $testCommand.CommandTimeout = 90
                    $testTask = $testCommand.ExecuteNonQueryAsync()
                    Write-Host "LIVE: session $testSession is running a 45-second wait"
                    Invoke-Sql @"
WAITFOR DELAY '00:00:35';
EXEC dbo.sp_WhoIsActive
 @filter='$testSession',@filter_type='session',
 @show_sleeping_spids=1,@show_system_spids=1,@get_task_info=2,
 @get_locks=1,@find_block_leaders=1,@get_outer_command=1,
 @get_full_inner_text=1,@get_avg_time=1,@format_output=1,
 @sort_order='[start_time] ASC',@destination_table='dbo.WHOISACTIVE';
"@
                    [void]$testTask.GetAwaiter().GetResult()
                } finally {
                    if ($testCommand) { $testCommand.Dispose() }
                    $testConnection.Dispose()
                }
            }
            Invoke-Sql @'
DECLARE @RunId bigint;
EXEC analyzer.usp_AnalyzeWhoIsActiveLongRunning @ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
IF NOT EXISTS(SELECT 1 FROM analyzer.LongRunningSqlAnalysisRun WHERE analysis_run_id=@RunId AND status='SUCCEEDED' AND min_duration_seconds=30)
    THROW 58941,'The live analysis did not succeed.',1;
SELECT analysis_run_id,analysis_date,status,min_duration_seconds,captured_row_count,request_count
FROM analyzer.LongRunningSqlAnalysisRun WHERE analysis_run_id=@RunId;
SELECT session_id,max_elapsed_seconds,observed_sample_count
FROM analyzer.LongRunningSql WHERE analysis_run_id=@RunId ORDER BY max_elapsed_seconds DESC;
SELECT 'PASS: live analysis completed; results retained' test_result;
'@
            if ($LiveRequest) {
                Invoke-Sql @"
IF NOT EXISTS(SELECT 1 FROM analyzer.LongRunningSql
 WHERE program_name=N'$liveProgram' AND max_elapsed_seconds>=30)
 THROW 58969,'The real 30-second request was not recorded.',1;
SELECT analysis_run_id,session_id,request_start_time,max_elapsed_seconds,
 observed_sample_count,last_wait_info,program_name,last_sql_text
FROM analyzer.LongRunningSql WHERE program_name=N'$liveProgram';
SELECT 'PASS: real request exceeded 30 seconds, was sampled, and is retained in LongRunningSql' test_result;
"@
            }
        } finally {
            try {
                if ($schemaCreated -and $connection.State -eq 'Open') {
                    Invoke-Sql @"
USE tempdb;
DROP PROCEDURE IF EXISTS $schema.usp_AnalyzeWhoIsActiveLongRunning;
DROP TABLE IF EXISTS $schema.LongRunningSql;
DROP TABLE IF EXISTS $schema.LongRunningSqlAnalysisRun;
DROP TABLE IF EXISTS $schema.WHOISACTIVE;
DROP TABLE IF EXISTS $schema.Clock;
DROP SCHEMA $schema;
SELECT 'PASS: isolated test objects removed' test_result;
"@
                }
            } finally { $connection.Dispose() }
        }
    })
} finally {
    if ($token) { $token.Dispose() }
    $credential = $null
}
