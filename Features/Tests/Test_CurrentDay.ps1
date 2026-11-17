#requires -Version 7.0
param(
    [pscredential]$Credential,
    [string]$ServerInstance='tcp:192.168.56.202,1433'
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $Credential) {
    . (Join-Path $projectRoot 'Tools\LabCredential.ps1')
    $saved=[DBAnalyzerLabCredential]::Load()
    if(-not $saved){throw 'The authorized lab credential is missing.'}
    $Credential=[pscredential]::new($saved.UserName,(ConvertTo-SecureString $saved.Password -AsPlainText -Force))
    $saved=$null
}
Add-Type @'
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class CurrentDayLogon {
    [DllImport("advapi32.dll",EntryPoint="LogonUserW",CharSet=CharSet.Unicode,SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LogonUser(string user,string domain,string password,int type,int provider,out SafeAccessTokenHandle token);
}
'@
$token=$null
$network=$Credential.GetNetworkCredential()
try {
    if(-not [CurrentDayLogon]::LogonUser($network.UserName,$network.Domain,$network.Password,9,3,[ref]$token)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    [Security.Principal.WindowsIdentity]::RunImpersonated($token,[Action]{
        $connection=[System.Data.SqlClient.SqlConnection]::new("Server=$ServerInstance;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Pooling=False;Connect Timeout=15")
        $schema='CurrentDayTest_'+[guid]::NewGuid().ToString('N').Substring(0,12)
        $schemaCreated=$false
        function Invoke-TestSql([string]$Sql) {
            $command=$connection.CreateCommand()
            $command.CommandText=$Sql
            $command.CommandTimeout=120
            try {[void]$command.ExecuteNonQuery()} finally {$command.Dispose()}
        }
        try {
            $connection.Open()
            $command=$connection.CreateCommand()
            $command.CommandText="SELECT CONVERT(nvarchar(128),SERVERPROPERTY('ServerName')) server_name,ORIGINAL_LOGIN() original_login,HAS_DBACCESS(N'MS_PERF_COLLECTION') collection_access FOR JSON PATH,WITHOUT_ARRAY_WRAPPER;"
            try {Write-Host $command.ExecuteScalar()} finally {$command.Dispose()}
            Invoke-TestSql 'USE tempdb;'
            Invoke-TestSql "CREATE SCHEMA $schema;"
            $schemaCreated=$true
            Invoke-TestSql @"
CREATE TABLE $schema.Clock(run_time datetime NOT NULL);
INSERT $schema.Clock VALUES(GETDATE());
CREATE TABLE $schema.SourceLog(archive_number int,log_date datetime,process_info nvarchar(50),log_text nvarchar(max));
SELECT TOP(0) * INTO $schema.WHOISACTIVE FROM MS_PERF_COLLECTION.dbo.WHOISACTIVE;
"@
            Invoke-TestSql @"
CREATE PROCEDURE $schema.EnumArchives AS
BEGIN
 SET NOCOUNT ON;
 SELECT 0 archive_number,CONVERT(datetime,CONVERT(date,run_time)) log_date,CONVERT(bigint,1000) log_size FROM $schema.Clock
 UNION ALL SELECT 1,DATEADD(DAY,-1,CONVERT(datetime,CONVERT(date,run_time))),CONVERT(bigint,100) FROM $schema.Clock;
END;
"@
            Invoke-TestSql @"
CREATE PROCEDURE $schema.ReadErrorLog
 @Archive int,@LogType int,@Search1 nvarchar(4000)=NULL,@Search2 nvarchar(4000)=NULL,
 @From datetime=NULL,@To datetime=NULL,@Sort nvarchar(4)=NULL
AS
BEGIN
 SET NOCOUNT ON;
 SELECT log_date,process_info,log_text FROM $schema.SourceLog
 WHERE archive_number=@Archive AND (@From IS NULL OR log_date>=@From) AND (@To IS NULL OR log_date<=@To)
 ORDER BY log_date;
END;
"@
            foreach($file in @('Blocking\Deploy_DBAnalyzer_Daily.sql','LoginFailed\Deploy_DBAnalyzer_LoginFailed.sql',
                'LongRunning\Deploy_DBAnalyzer_LongRunning.sql','HighResource\Deploy_DBAnalyzer_HighResource.sql')) {
                $sql=Get-Content (Join-Path $projectRoot ('Features\'+$file)) -Raw
                $clock='DECLARE @RunTime datetime = GETDATE();'
                if(-not $sql.Contains($clock)){throw ('The captured analysis clock is missing: '+$file)}
                $sql=$sql.Replace('USE MS_PERF_COLLECTION;','USE tempdb;').Replace('analyzer.',$schema+'.')
                $sql=$sql.Replace('dbo.WHOISACTIVE',$schema+'.WHOISACTIVE')
                $sql=$sql.Replace($clock,"DECLARE @RunTime datetime = (SELECT run_time FROM $schema.Clock);")
                $sql=$sql.Replace('master.dbo.sp_enumerrorlogs',$schema+'.EnumArchives').Replace('master.dbo.xp_readerrorlog',$schema+'.ReadErrorLog')
                foreach($batch in [regex]::Split($sql,'(?im)^\s*GO\s*\r?$')) {
                    if(-not [string]::IsNullOrWhiteSpace($batch)){Invoke-TestSql $batch}
                }
            }
            $fixtures=Get-Content (Join-Path $PSScriptRoot 'CurrentDay_Fixtures.sql') -Raw
            Invoke-TestSql $fixtures.Replace('{{schema}}',$schema)
            Write-Host 'PASS: current-day default, frozen upper boundary, historical dates, cross-midnight requests, repeat execution, advancing cutoff, midnight rollover, and future-date rejection'
        } finally {
            if($schemaCreated -and $connection.State -eq 'Open') {
                Invoke-TestSql @"
DECLARE @Sql nvarchar(max)=N'';
SELECT @Sql+=N'DROP '+CASE type WHEN 'P' THEN N'PROCEDURE ' ELSE N'VIEW ' END+QUOTENAME('$schema')+N'.'+QUOTENAME(name)+N';'
 FROM sys.objects WHERE schema_id=SCHEMA_ID(N'$schema') AND type IN('P','V');
EXEC(@Sql);
SET @Sql=N'';
SELECT @Sql+=N'ALTER TABLE '+QUOTENAME('$schema')+N'.'+QUOTENAME(OBJECT_NAME(parent_object_id))+N' DROP CONSTRAINT '+QUOTENAME(name)+N';'
 FROM sys.foreign_keys WHERE schema_id=SCHEMA_ID(N'$schema');
EXEC(@Sql);
SET @Sql=N'';
SELECT @Sql+=N'DROP TABLE '+QUOTENAME('$schema')+N'.'+QUOTENAME(name)+N';' FROM sys.tables WHERE schema_id=SCHEMA_ID(N'$schema');
EXEC(@Sql);
DROP SCHEMA $schema;
"@
                Write-Host 'CLEANUP: isolated current-day test schema removed'
            }
            $connection.Dispose()
        }
    })
} finally {
    if($token){$token.Dispose()}
    $network=$null
    $Credential=$null
}
