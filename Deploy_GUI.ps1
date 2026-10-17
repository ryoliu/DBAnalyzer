#requires -Version 5.1
param([switch]$NoShow)

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$packageRoot=$PSScriptRoot
$enginePath=Join-Path $packageRoot 'Deploy.ps1'
$script:deployProcess=$null
$script:outputTask=$null
$script:errorTask=$null
$script:currentLog=$null

$form=[System.Windows.Forms.Form]::new()
$form.Text='DBAnalyzer Deployment'
$form.ClientSize=[System.Drawing.Size]::new(740,460)
$form.StartPosition='CenterScreen'
$form.FormBorderStyle='FixedDialog'
$form.MaximizeBox=$false
$form.Font=[System.Drawing.Font]::new('Segoe UI',10)

$instanceLabel=[System.Windows.Forms.Label]::new()
$instanceLabel.Text='SQL Server Instance'
$instanceLabel.SetBounds(20,18,690,24)
$form.Controls.Add($instanceLabel)

$instanceText=[System.Windows.Forms.TextBox]::new()
$instanceText.Text='localhost'
$instanceText.SetBounds(20,46,700,28)
$form.Controls.Add($instanceText)

$exampleLabel=[System.Windows.Forms.Label]::new()
$exampleLabel.Text='Examples: WIN2019LAB | WIN2019LAB\LAB2 | tcp:192.168.56.104,1433'
$exampleLabel.SetBounds(20,80,700,24)
$exampleLabel.ForeColor=[System.Drawing.Color]::DimGray
$form.Controls.Add($exampleLabel)

$trustCheck=[System.Windows.Forms.CheckBox]::new()
$trustCheck.Text='Trust server certificate (for a self-signed certificate)'
$trustCheck.SetBounds(20,112,700,26)
$form.Controls.Add($trustCheck)

$deployButton=[System.Windows.Forms.Button]::new()
$deployButton.Text='Deploy'
$deployButton.SetBounds(20,150,120,36)
$form.Controls.Add($deployButton)

$closeButton=[System.Windows.Forms.Button]::new()
$closeButton.Text='Close'
$closeButton.SetBounds(152,150,120,36)
$closeButton.Add_Click({$form.Close()})
$form.Controls.Add($closeButton)
$form.AcceptButton=$deployButton
$form.CancelButton=$closeButton

$statusLabel=[System.Windows.Forms.Label]::new()
$statusLabel.Text='Ready. Authentication uses the current Windows account.'
$statusLabel.SetBounds(20,198,700,24)
$form.Controls.Add($statusLabel)

$outputText=[System.Windows.Forms.TextBox]::new()
$outputText.Multiline=$true
$outputText.ReadOnly=$true
$outputText.ScrollBars='Vertical'
$outputText.WordWrap=$true
$outputText.Font=[System.Drawing.Font]::new('Consolas',9)
$outputText.SetBounds(20,230,700,210)
$form.Controls.Add($outputText)

$timer=[System.Windows.Forms.Timer]::new()
$timer.Interval=300
$timer.Add_Tick({
    if($script:currentLog -and (Test-Path -LiteralPath $script:currentLog)) {
        try {
            $text=Get-Content -LiteralPath $script:currentLog -Raw -ErrorAction Stop
            if($text -and $outputText.Text -ne $text) {
                $outputText.Text=$text
                $outputText.SelectionStart=$outputText.TextLength
                $outputText.ScrollToCaret()
            }
        }catch{}
    }
    if($script:deployProcess -and $script:deployProcess.HasExited -and
       $script:outputTask.IsCompleted -and $script:errorTask.IsCompleted) {
        $timer.Stop()
        $standardOutput=$script:outputTask.Result
        $errorOutput=$script:errorTask.Result
        $outputText.Text=$standardOutput
        if($errorOutput){$outputText.AppendText([Environment]::NewLine+$errorOutput)}
        if($script:deployProcess.ExitCode -eq 0) {
            $statusLabel.Text='Deployment completed. Daily analysis and cleanup jobs are enabled.'
            $statusLabel.ForeColor=[System.Drawing.Color]::DarkGreen
        }else{
            $statusLabel.Text='Deployment failed. See the output below.'
            $statusLabel.ForeColor=[System.Drawing.Color]::DarkRed
        }
        $outputText.AppendText([Environment]::NewLine+'Log: '+$script:currentLog)
        $instanceText.Enabled=$true
        $trustCheck.Enabled=$true
        $deployButton.Enabled=$true
        $closeButton.Enabled=$true
        $script:deployProcess.Dispose()
        $script:deployProcess=$null
    }
})

$deployButton.Add_Click({
    $target=$instanceText.Text.Trim()
    if(-not $target -or $target -match '[\x00-\x1f"]' -or $target.EndsWith('\')) {
        $statusLabel.Text='Enter a valid SQL Server instance.'
        $statusLabel.ForeColor=[System.Drawing.Color]::DarkRed
        $instanceText.Focus()
        return
    }
    try {
        if(-not (Test-Path -LiteralPath $enginePath)){throw 'Deploy.ps1 was not found.'}
        $logFolder=Join-Path $packageRoot 'DeploymentLogs'
        [void](New-Item -ItemType Directory -Path $logFolder -Force)
        $script:currentLog=Join-Path $logFolder ('GUI-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'.log')
        $startInfo=[System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $startInfo.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$enginePath+'" -ServerInstance "'+$target+'" -LogFile "'+$script:currentLog+'"'
        if($trustCheck.Checked){$startInfo.Arguments+=' -TrustServerCertificate'}
        $startInfo.UseShellExecute=$false
        $startInfo.CreateNoWindow=$true
        $startInfo.RedirectStandardOutput=$true
        $startInfo.RedirectStandardError=$true
        $script:deployProcess=[System.Diagnostics.Process]::Start($startInfo)
        $script:outputTask=$script:deployProcess.StandardOutput.ReadToEndAsync()
        $script:errorTask=$script:deployProcess.StandardError.ReadToEndAsync()
        $outputText.Text='Starting deployment...'
        $statusLabel.Text='Deploying to '+$target+'...'
        $statusLabel.ForeColor=[System.Drawing.Color]::Black
        $instanceText.Enabled=$false
        $trustCheck.Enabled=$false
        $deployButton.Enabled=$false
        $closeButton.Enabled=$false
        $timer.Start()
    }catch{
        $statusLabel.Text='Unable to start deployment.'
        $statusLabel.ForeColor=[System.Drawing.Color]::DarkRed
        $outputText.Text=$_.Exception.Message
    }
})

$form.Add_FormClosing({
    param($sender,$eventArgs)
    if($script:deployProcess -and -not $script:deployProcess.HasExited) {
        $eventArgs.Cancel=$true
        $statusLabel.Text='Deployment is running. Please wait for it to finish.'
    }
})
$form.Add_FormClosed({$timer.Dispose()})
if(-not $NoShow){[void]$form.ShowDialog();$form.Dispose()}
