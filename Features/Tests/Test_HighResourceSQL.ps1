#requires -Version 7.0
param([switch]$ClearResults)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $projectRoot 'Tools\LabCredential.ps1')
$credential = [DBAnalyzerLabCredential]::Load()
if (-not $credential) { throw 'The authorized lab credential is missing.' }
$credential = [pscredential]::new($credential.UserName,
    (ConvertTo-SecureString $credential.Password -AsPlainText -Force)).GetNetworkCredential()

if (-not ('HighResourceLogon' -as [type])) {
    Add-Type @'
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class HighResourceLogon {
    [DllImport("advapi32.dll", EntryPoint="LogonUserW", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LogonUser(string user, string domain, string password,
        int type, int provider, out SafeAccessTokenHandle token);
}
'@
}

$token = $null
try {
    if (-not [HighResourceLogon]::LogonUser($credential.UserName, $credential.Domain,
        $credential.Password, 9, 3, [ref]$token)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    [Security.Principal.WindowsIdentity]::RunImpersonated($token, [Action]{
        $connection = [System.Data.SqlClient.SqlConnection]::new(
            'Server=tcp:192.168.56.202,1433;Database=MS_PERF_COLLECTION;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Pooling=False;Connect Timeout=15')
        $schema = 'HighResourceTest_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
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
            $command.CommandText = "SELECT OBJECT_DEFINITION(OBJECT_ID(N'analyzer.usp_AnalyzeWhoIsActiveHighResource'));"
            try { $procedure = $command.ExecuteScalar() } finally { $command.Dispose() }
            if ($procedure -isnot [string]) { throw 'The deployed HighResource procedure is missing.' }

            if ($ClearResults) {
                Invoke-Sql (Get-Content (Join-Path $PSScriptRoot 'HighResourceSQL_Clear.sql') -Raw)
            }

            Invoke-Sql 'USE tempdb;'
            Invoke-Sql "CREATE SCHEMA $schema;"
            $schemaCreated = $true
            Invoke-Sql "SELECT TOP(0) * INTO $schema.WHOISACTIVE FROM MS_PERF_COLLECTION.dbo.WHOISACTIVE;"
            $deployment = Get-Content (Join-Path $projectRoot 'Features\HighResource\Deploy_DBAnalyzer_HighResource.sql') -Raw
            foreach ($batch in [regex]::Split($deployment, '(?im)^\s*GO\s*\r?$')) {
                if ([string]::IsNullOrWhiteSpace($batch) -or $batch -match 'CREATE OR ALTER PROCEDURE') { continue }
                Invoke-Sql $batch.Replace('USE MS_PERF_COLLECTION;', 'USE tempdb;').Replace('analyzer.', "$schema.")
            }
            Invoke-Sql $procedure.Replace('analyzer.', "$schema.").Replace('dbo.WHOISACTIVE', "$schema.WHOISACTIVE")
            $tests = Get-Content (Join-Path $PSScriptRoot 'HighResourceSQL_Cases.sql') -Raw
            Invoke-Sql $tests.Replace('{{schema}}', $schema)

            Invoke-Sql 'USE MS_PERF_COLLECTION;'
            Invoke-Sql @'
DECLARE @RunId bigint;
EXEC analyzer.usp_AnalyzeWhoIsActiveHighResource @ReturnResults=0,@AnalysisRunId=@RunId OUTPUT;
IF NOT EXISTS(SELECT 1 FROM analyzer.HighResourceSqlAnalysisRun WHERE analysis_run_id=@RunId AND status='SUCCEEDED')
    THROW 58941,'The live analysis did not succeed.',1;
SELECT analysis_run_id,analysis_date,status,captured_row_count,unparsed_counter_rows,request_count
FROM analyzer.HighResourceSqlAnalysisRun WHERE analysis_run_id=@RunId;
SELECT session_id,max_cpu_ms,max_logical_reads,cpu_rank,logical_reads_rank
FROM analyzer.HighResourceSql WHERE analysis_run_id=@RunId ORDER BY cpu_rank,logical_reads_rank;
SELECT 'PASS: live analysis completed; results retained' test_result;
'@
        } finally {
            try {
                if ($schemaCreated -and $connection.State -eq 'Open') {
                    Invoke-Sql @"
USE tempdb;
DROP PROCEDURE IF EXISTS $schema.usp_AnalyzeWhoIsActiveHighResource;
DROP TABLE IF EXISTS $schema.HighResourceSql;
DROP TABLE IF EXISTS $schema.HighResourceSqlAnalysisRun;
DROP TABLE IF EXISTS $schema.WHOISACTIVE;
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
