#requires -Version 5.1
param(
    [string]$ServerInstance='localhost',
    [switch]$TrustServerCertificate,
    [string]$LogFile
)

$ErrorActionPreference='Stop'
$files=@(
    'Check_Environment.sql',
    'Blocking\Deploy_DBAnalyzer_Daily.sql',
    'LoginFailed\Deploy_DBAnalyzer_LoginFailed.sql',
    'Jobs\Deploy_DBAnalyzer_Jobs.sql'
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
    Write-Host 'Deployment completed. Daily analysis and cleanup jobs are enabled.'
}
finally {
    if($command){$command.Dispose()}
    $connection.Dispose()
    Stop-Transcript | Out-Null
}
