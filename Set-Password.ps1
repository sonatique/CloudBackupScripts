#Requires -Version 5.1
<#
.SYNOPSIS
    Stores the ownCloud / Nextcloud app password in config.json, encrypted with DPAPI.

.DESCRIPTION
    The encrypted blob can only be decrypted by the same Windows user account on the
    same machine. Run this as the account that will run the scheduled task.

    Use an *app password* (Nextcloud: Settings > Security > Devices & sessions >
    Create new app password), not your login password - it can be revoked on its own
    and works with two-factor authentication.

.EXAMPLE
    .\Set-Password.ps1
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $example = Join-Path $PSScriptRoot 'config.example.json'
    if (-not (Test-Path -LiteralPath $example)) { throw "Neither $ConfigPath nor config.example.json exists." }
    Copy-Item -LiteralPath $example -Destination $ConfigPath
    Write-Host "Created $ConfigPath from the example - edit ServerUrl, Username and LocalRoot after this." -ForegroundColor Yellow
}

$configRaw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
try {
    $cfg = $configRaw | ConvertFrom-Json
} catch {
    # ConvertFrom-Json reports a character offset, not a line - translate it, and name
    # the mistakes that actually happen when this file is edited by hand.
    $where = ''
    if ($_.Exception.Message -match '\((\d+)\)' ) {
        $offset = [int]$Matches[1]
        if ($offset -gt 0 -and $offset -le $configRaw.Length) {
            $where = ' near line {0}' -f (($configRaw.Substring(0, $offset) -split "`n").Count)
        }
    }
    # The parser echoes the whole file after the offset - drop that, it is already on screen.
    $reason = $_.Exception.Message -replace '(?s):\s*\{.*$', ''
    Write-Host ("{0} is not valid JSON{1}:" -f $ConfigPath, $where) -ForegroundColor Red
    Write-Host ("  {0}" -f $reason) -ForegroundColor Red
    Write-Host ''
    Write-Host 'Most likely one of:' -ForegroundColor Yellow
    Write-Host '  - a missing quote, e.g.  "PasswordEncrypted": ",   should be   "PasswordEncrypted": "",'
    Write-Host '  - a single backslash in a path - double them ("D:\\Backups") or use forward slashes ("D:/Backups")'
    Write-Host '  - a trailing comma after the last entry of an object or list'
    exit 2
}

$secure = Read-Host -Prompt "App password for '$($cfg.Username)' at $($cfg.ServerUrl)" -AsSecureString
if ($secure.Length -eq 0) { throw 'No password entered.' }

$cfg | Add-Member -NotePropertyName 'PasswordEncrypted' -NotePropertyValue (ConvertFrom-SecureString -SecureString $secure) -Force
if ($cfg.PSObject.Properties.Name -contains 'Password') { $cfg.PSObject.Properties.Remove('Password') }

($cfg | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

# Restrict the file to the current user - it holds a credential, encrypted or not.
$acl = Get-Acl -LiteralPath $ConfigPath
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
    "$env:USERDOMAIN\$env:USERNAME", 'FullControl', 'Allow')))
Set-Acl -LiteralPath $ConfigPath -AclObject $acl

Write-Host "Password stored (DPAPI, user $env:USERNAME on $env:COMPUTERNAME) in $ConfigPath" -ForegroundColor Green
Write-Host "Next: .\Backup-Cloud.ps1 -DryRun" -ForegroundColor Green
