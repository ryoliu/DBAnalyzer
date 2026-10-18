#requires -Version 5.1
param(
    [string]$ServerInstance='localhost',
    [switch]$TrustServerCertificate,
    [string]$LogFile
)

$ErrorActionPreference='Stop'
$files=@(
    'Features\WhoIsActive\Deploy_WhoIsActive.sql',
    'Features\WhoIsActive\WhoIsActive_11_Deployment_In_Once.sql',
    'Features\WhoIsActive\Deploy_WhoIsActiveJob.sql',
    'Check_Environment.sql',
    'Features\Blocking\Deploy_DBAnalyzer_Daily.sql',
    'Features\LoginFailed\Deploy_DBAnalyzer_LoginFailed.sql',
    'Features\LongRunning\Deploy_DBAnalyzer_LongRunning.sql',
    'Features\HighResource\Deploy_DBAnalyzer_HighResource.sql',
    'Features\TableRowCount\Deploy_DBAnalyzer_TableRowCount.sql',
    'Features\Jobs\Deploy_DBAnalyzer_Jobs.sql'
)

# Use the current Windows account.
$settings=[System.Data.SqlClient.SqlConnectionStringBuilder]::new()
$settings['Data Source']=$ServerInstance
$settings['Initial Catalog']='master'
$settings['Integrated Security']=$true
$settings['Encrypt']=$true
$settings['TrustServerCertificate']=[bool]$TrustServerCertificate
$settings['Connect Timeout']=15
$connection=[System.Data.SqlClient.SqlConnection]::new($settings.ConnectionString)
$command=$null

$logFolder=Join-Path $PSScriptRoot 'DeploymentLogs'
[void](New-Item -ItemType Directory -Path $logFolder -Force)
if(-not $LogFile) {
    $LogFile=Join-Path $logFolder ('Deploy-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'.log')
}
Start-Transcript -Path $LogFile | Out-Null
try {
    foreach($file in $files) {
        if(-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) {
            throw ('File not found: '+$file)
        }
    }

    Write-Host ('Connecting to '+$ServerInstance)
    $connection.Open()
    $command=$connection.CreateCommand()
    $command.CommandTimeout=180

    foreach($file in $files) {
        Write-Host ('Running '+$file)
        $sql=Get-Content -LiteralPath (Join-Path $PSScriptRoot $file) -Raw -Encoding UTF8
        if($file -eq 'Features\WhoIsActive\WhoIsActive_11_Deployment_In_Once.sql') {
            $command.CommandText="SELECT OBJECT_ID(N'MS_PERF_COLLECTION.dbo.sp_WhoIsActive',N'P');"
            if($command.ExecuteScalar() -isnot [DBNull]) {
                Write-Host 'WhoIsActive already exists. Keeping the installed procedure.'
                continue
            }
            # Use only the licensed procedure batch from the supplied installer.
            $sql=([regex]::Split($sql,'(?im)^\s*GO\s*(?:--[^\r\n]*)?\r?$') |
                Where-Object {$_ -match '(?im)^ALTER PROC dbo\.sp_WhoIsActive\b'})
            if(@($sql).Count -ne 1){throw 'The WhoIsActive procedure batch was not found.'}
            $sql=$sql.Replace('ALTER PROC dbo.sp_WhoIsActive','CREATE OR ALTER PROC dbo.sp_WhoIsActive')
            $command.CommandText='USE MS_PERF_COLLECTION; SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;'
            [void]$command.ExecuteNonQuery()
        }
        $batchNumber=0
        foreach($batch in [regex]::Split($sql,'(?im)^\s*GO\s*(?:--[^\r\n]*)?\r?$')) {
            if([string]::IsNullOrWhiteSpace($batch)){continue}
            $batchNumber++
            $command.CommandText=$batch
            try{[void]$command.ExecuteNonQuery()}
            catch{throw ('{0}, batch {1}: {2}' -f $file,$batchNumber,$_.Exception.Message)}
        }
    }

    $command.CommandText="SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE enabled=1 AND name IN(N'_DBAnalyzer-Daily',N'_DBAnalyzer-Blocking-Cleanup');"
    if([int]$command.ExecuteScalar() -ne 2){throw 'Expected two enabled jobs: daily analysis and cleanup.'}
    Write-Host 'Deployment completed. All components and jobs are ready.'
}
finally {
    if($command){$command.Dispose()}
    $connection.Dispose()
    Stop-Transcript | Out-Null
}
