#Requires -Version 5.1
<#
.SYNOPSIS
    Registers (or removes) a daily Windows scheduled task that runs Backup-Cloud.ps1.

.PARAMETER At
    Time of day to run, HH:mm. Default 02:30.

.PARAMETER TaskName
    Scheduled task name. Default 'CloudBackup'.

.PARAMETER Uninstall
    Remove the task instead of creating it.

.EXAMPLE
    .\Install-Schedule.ps1 -At 03:00
.EXAMPLE
    .\Install-Schedule.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d{1,2}:\d{2}$')][string] $At = '02:30',
    [string] $TaskName = 'CloudBackup',
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch] $Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    } else {
        Write-Host "No scheduled task named '$TaskName'." -ForegroundColor Yellow
    }
    return
}

$script = Join-Path $PSScriptRoot 'Backup-Cloud.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "Backup-Cloud.ps1 not found next to this script." }
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "$ConfigPath not found - run .\Set-Password.ps1 -ConfigPath '$ConfigPath' first."
}

$action = New-ScheduledTaskAction `
    -Execute (Join-Path $PSHOME 'powershell.exe') `
    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -Quiet' -f $script, $ConfigPath) `
    -WorkingDirectory $PSScriptRoot

$trigger = New-ScheduledTaskTrigger -Daily -At ([DateTime]::ParseExact($At, 'H:mm', $null))

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 12) `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 30)

# Interactive logon type: no stored Windows password needed. The task runs when the
# user is logged on; -StartWhenAvailable catches up on a missed daily run.
$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force `
    -Description 'Daily incremental backup of the ownCloud/Nextcloud account (Backup-Cloud.ps1).' | Out-Null

Write-Host "Scheduled task '$TaskName' registered - runs daily at $At as $env:USERNAME." -ForegroundColor Green
Write-Host "Run it now with:  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Green
Write-Host "Last result:      Get-ScheduledTaskInfo -TaskName '$TaskName'" -ForegroundColor Green
