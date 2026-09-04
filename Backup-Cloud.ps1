#Requires -Version 5.1
<#
.SYNOPSIS
    Incremental one-way backup of an ownCloud / Nextcloud account to a local folder.

.DESCRIPTION
    Walks the remote WebDAV tree (PROPFIND, depth 1, recursive), compares each file's
    ETag / size against a local state file, and downloads only what changed since the
    last run. Designed to be run unattended once a day by Task Scheduler.

    A file that moved remotely is renamed locally instead of being downloaded again,
    matched on the server's oc:fileid (ETag + size on plain WebDAV servers).

    When KeepVersions is on, the previous content of an overwritten file is kept under
    _versions\<run timestamp>\, so a bad edit can still be recovered.

    Every file this script downloads has its SHA-256 recorded in state.json. -Verify
    rehashes the local tree and re-downloads anything that no longer matches - this
    catches local corruption that size/mtime alone would miss, but only for files this
    script has itself fetched at least once; a file trusted at enrollment (see below)
    has no baseline hash until its content next changes and is re-downloaded.

    On enrollment - the first run over a file that already exists locally, so there is
    no prior state entry - size + modification time alone cannot prove the content is
    intact. When the server publishes an oc:checksums property for that file (Nextcloud
    computes SHA1/MD5 for files uploaded through a client that supports it; not
    guaranteed for every file), the local content is hashed and compared against it
    before being trusted, which also seeds the SHA-256 baseline. Without a server
    checksum, an enrolled file is trusted by size + mtime alone, exactly as before.

.PARAMETER ConfigPath
    Path to the JSON configuration file. Defaults to config.json next to this script.

.PARAMETER Full
    Ignore the saved state and re-verify every remote file against the local copy.
    (Files that already match by size + timestamp are still skipped.)

.PARAMETER Verify
    Rehash every local file that would otherwise be skipped as unchanged, and compare
    against its recorded SHA-256. A mismatch forces a re-download. Files with no
    recorded hash (never downloaded by this script) cannot be checked and are reported,
    not silently passed. Expensive - reads the whole local tree - so this is meant for
    a weekly/monthly run, not the daily one.

.PARAMETER DryRun
    Report what would be transferred, moved or removed without touching the local tree.

.PARAMETER Quiet
    Suppress INFO output on the console. Warnings, errors and the log file are kept.

.EXAMPLE
    .\Backup-Cloud.ps1
.EXAMPLE
    .\Backup-Cloud.ps1 -DryRun -Verbose
.EXAMPLE
    .\Backup-Cloud.ps1 -Verify
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch] $Full,
    [switch] $Verify,
    [switch] $BaselineLocal,
    [switch] $DryRun,
    [switch] $Quiet,
    [switch] $NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol =
    [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
[Net.ServicePointManager]::DefaultConnectionLimit = 8

# ---------------------------------------------------------------- logging ----

$script:LogFile = $null

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string] $Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { Write-Verbose $line }
        default { if (-not $Quiet) { Write-Host $line } }
    }
}

# ----------------------------------------------------------------- config ----

function Get-Prop {
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $Default }
    $value = $Object.$Name
    if ($null -eq $value) { return $Default }
    if (($value -is [string]) -and $value.Trim() -eq '') { return $Default }
    return $value
}

# --------------------------------------------------- log file, early -------
# Opened before anything else can fail. A scheduled task has no console to show a startup
# error on, so without this an unreadable drive letter or an undecryptable password is a
# red flash on screen and nothing at all on disk. State, lock and log names carry the
# config file's name so several accounts can share this folder.
$configTag = [IO.Path]::GetFileNameWithoutExtension($ConfigPath)
$bootstrapLogDir = Join-Path $PSScriptRoot 'logs'
try {
    if (-not (Test-Path -LiteralPath $bootstrapLogDir)) {
        New-Item -ItemType Directory -Path $bootstrapLogDir -Force | Out-Null
    }
    $script:LogFile = Join-Path $bootstrapLogDir ('backup-{0}-{1}.log' -f $configTag, (Get-Date -Format 'yyyyMMdd'))
} catch {
    Write-Host "Could not create a log file in $bootstrapLogDir - $($_.Exception.Message)" -ForegroundColor Red
}

function Stop-WithError {
    # Startup failures: recorded in the log, then a clean exit. 'throw' here would print a
    # PowerShell stack trace to a console nobody is watching and leave no trace behind.
    param([Parameter(Mandatory)][string] $Message)
    Write-Log $Message 'ERROR'
    exit 2
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Stop-WithError "Configuration file not found: $ConfigPath (copy config.example.json to config.json and edit it)"
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

foreach ($required in 'ServerUrl', 'Username', 'LocalRoot') {
    if (-not (Get-Prop $cfg $required)) { Stop-WithError "Configuration key '$required' is missing or empty in $ConfigPath" }
}

# A misspelled key is silently ignored and its default used instead - which looks exactly
# like the script disobeying the config. Name them rather than let that happen quietly.
$knownKeys = @(
    'ServerUrl', 'Username', 'Password', 'PasswordEncrypted', 'AllowInsecureHttp',
    'RemoteRoot', 'LocalRoot', 'Exclude',
    'DetectMoves', 'KeepVersions', 'VersionRetentionDays',
    'DeleteRemoved', 'TrashLocalOrphans', 'MaxOrphanPercent', 'TrashRetentionDays',
    'TrashPath', 'VersionsPath', 'StatePath', 'LogDirectory',
    'MaxFileSizeMB', 'TimeoutSeconds', 'Retries', 'LogRetentionDays'
)

function Wait-ForAcknowledgement {
    <#
        Blocks until a key is pressed, but ONLY when a human is actually there to press it.
        This script's main job is an unattended nightly run; a prompt that blocks Task
        Scheduler would silently stop backups until the task's execution time limit kills it.
        Hence three layers of defence: the explicit switches, an interactivity test, and a
        timeout so that even a misdetected session cannot stall forever.
    #>
    param([int] $TimeoutSeconds = 60)

    if ($NoPause -or $Quiet) { Write-Log 'pause skipped: -NoPause/-Quiet' 'DEBUG'; return }
    if (-not [Environment]::UserInteractive) { Write-Log 'pause skipped: session is not interactive' 'DEBUG'; return }
    try {
        if ([Console]::IsInputRedirected) { Write-Log 'pause skipped: stdin is redirected' 'DEBUG'; return }
    } catch { Write-Log 'pause skipped: stdin state unreadable' 'DEBUG'; return }

    $raw = $null
    try { $raw = $Host.UI.RawUI } catch { Write-Log 'pause skipped: host has no RawUI' 'DEBUG'; return }
    if (-not $raw) { Write-Log 'pause skipped: host has no RawUI' 'DEBUG'; return }

    Write-Host ''
    Write-Host ("Review the warning(s) above. Press any key to continue, or Ctrl+C to abort (continues on its own in {0}s)..." -f $TimeoutSeconds) -ForegroundColor Yellow
    try {
        # A console's input buffer also carries focus and mouse events. Without this the
        # very first KeyAvailable can be true for something nobody typed, and the prompt
        # releases itself instantly.
        try { $raw.FlushInputBuffer() } catch { }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if ($raw.KeyAvailable) {
                $k = $raw.ReadKey('NoEcho,IncludeKeyDown')
                if ($k.VirtualKeyCode -ne 0) { Write-Host ''; return }   # ignore non-key events
            }
            Start-Sleep -Milliseconds 150
        }
        Write-Host '(no key pressed - continuing)' -ForegroundColor Yellow
    } catch {
        # Host cannot do raw key reads (ISE, remoting, redirected input): carry on.
    }
}

function Get-EditDistance {
    # Levenshtein, two rolling rows - PowerShell cannot parse arithmetic inside a
    # multi-dimensional index, so a 2-D array is more trouble than it is worth here.
    param([string] $A, [string] $B)
    $A = $A.ToLowerInvariant(); $B = $B.ToLowerInvariant()
    if (-not $A) { return $B.Length }
    if (-not $B) { return $A.Length }

    $prev = New-Object 'int[]' ($B.Length + 1)
    $curr = New-Object 'int[]' ($B.Length + 1)
    for ($j = 0; $j -le $B.Length; $j++) { $prev[$j] = $j }

    for ($i = 1; $i -le $A.Length; $i++) {
        $curr[0] = $i
        for ($j = 1; $j -le $B.Length; $j++) {
            $cost = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            $del = $prev[$j] + 1
            $ins = $curr[$j - 1] + 1
            $sub = $prev[$j - 1] + $cost
            $curr[$j] = [Math]::Min([Math]::Min($del, $ins), $sub)
        }
        $swap = $prev; $prev = $curr; $curr = $swap
    }
    return $prev[$B.Length]
}

# Held until the log file exists a few lines below, so an unattended run records this too.
$script:StartupWarnings = New-Object 'System.Collections.Generic.List[string]'
foreach ($bad in @($cfg.PSObject.Properties.Name | Where-Object { $knownKeys -notcontains $_ })) {
    $suggestion = $knownKeys |
        Where-Object { (Get-EditDistance $bad $_) -le 3 } |
        Sort-Object { Get-EditDistance $bad $_ } |
        Select-Object -First 1
    if ($suggestion) {
        $script:StartupWarnings.Add(("'{0}' is not a known setting and is being IGNORED - did you mean '{1}'? (in {2})" -f $bad, $suggestion, $ConfigPath))
    } else {
        $script:StartupWarnings.Add(("'{0}' is not a known setting and is being IGNORED. (in {1})" -f $bad, $ConfigPath))
    }
}

$ServerUrl   = ([string](Get-Prop $cfg 'ServerUrl')).TrimEnd('/')
$Username    = [string](Get-Prop $cfg 'Username')
$LocalRoot   = [string](Get-Prop $cfg 'LocalRoot')
$RemoteRoot  = ([string](Get-Prop $cfg 'RemoteRoot' '/')).Trim('/')
$Exclude     = @(Get-Prop $cfg 'Exclude' @())
$DeleteRemoved      = [bool](Get-Prop $cfg 'DeleteRemoved' $false)
$TrashLocalOrphans  = [bool](Get-Prop $cfg 'TrashLocalOrphans' $false)
$MaxOrphanPercent   = [int](Get-Prop $cfg 'MaxOrphanPercent' 25)
$DetectMoves        = [bool](Get-Prop $cfg 'DetectMoves' $true)
$KeepVersions       = [bool](Get-Prop $cfg 'KeepVersions' $true)
$TrashRetentionDays = [int](Get-Prop $cfg 'TrashRetentionDays' 30)
$VersionRetentionDays = [int](Get-Prop $cfg 'VersionRetentionDays' 90)
$MaxFileSizeMB      = [int](Get-Prop $cfg 'MaxFileSizeMB' 0)
$TimeoutSeconds     = [int](Get-Prop $cfg 'TimeoutSeconds' 300)
$Retries            = [int](Get-Prop $cfg 'Retries' 3)
$LogRetentionDays   = [int](Get-Prop $cfg 'LogRetentionDays' 60)
# [IO.Path]::Combine, not Join-Path: Join-Path resolves the drive qualifier and throws
# "cannot find drive" for a mapped drive that is not present in the current logon session.
# Building a path string must never depend on the drive being mounted; the later file I/O
# reports that properly.
$TrashPath    = [string](Get-Prop $cfg 'TrashPath'    ([IO.Path]::Combine($LocalRoot, '_trash')))
$VersionsPath = [string](Get-Prop $cfg 'VersionsPath' ([IO.Path]::Combine($LocalRoot, '_versions')))

if ($ServerUrl -notmatch '^https?://') { Stop-WithError "ServerUrl must start with http:// or https:// (got '$ServerUrl')" }
# A mapped drive letter exists only inside the logon session that mapped it, so a path like
# "Y:\owncloud" can work when run by hand and be missing under Task Scheduler. Say so plainly
# instead of failing later with a bare "cannot find drive".
$localRootRoot = ''
try { $localRootRoot = [IO.Path]::GetPathRoot($LocalRoot) } catch { }
if ($localRootRoot -match '^[A-Za-z]:\\?$' -and -not (Test-Path -LiteralPath $localRootRoot)) {
    $msg = ("LocalRoot '{0}' is on drive {1} which is not available in this session. " -f $LocalRoot, $localRootRoot.Substring(0, 2)) +
           "If that is a mapped network drive, note that drive letters belong to the logon session that created them: " +
           "a scheduled task does not inherit them, which is why this can work by hand and fail under Task Scheduler. " +
           'Use the UNC path instead, e.g. "\\server\share\owncloud" (doubled in JSON: "\\\\server\\share\\owncloud").'
    Stop-WithError $msg
}

foreach ($special in @($TrashPath, $VersionsPath)) {
    if ([IO.Path]::GetFullPath($special).TrimEnd('\') -eq [IO.Path]::GetFullPath($LocalRoot).TrimEnd('\')) {
        Stop-WithError "TrashPath/VersionsPath must not be LocalRoot itself - retention would purge the mirror."
    }
}
if ($ServerUrl -match '^http://' -and -not [bool](Get-Prop $cfg 'AllowInsecureHttp' $false)) {
    Stop-WithError "ServerUrl uses plain http://. Credentials would be sent in clear text. Set AllowInsecureHttp to true to override."
}

# Password: either DPAPI-encrypted (per Windows user, written by Set-Password.ps1) or plaintext.
$encrypted = Get-Prop $cfg 'PasswordEncrypted'
$plain     = Get-Prop $cfg 'Password'
if ($encrypted) {
    try {
        $secure   = ConvertTo-SecureString -String ([string]$encrypted)
        $bstr     = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    } catch {
        Stop-WithError "PasswordEncrypted could not be decrypted. It is bound to the Windows account and machine that created it. Re-run Set-Password.ps1 as the account the scheduled task uses."
    }
} elseif ($plain) {
    $Password = [string]$plain
} else {
    Stop-WithError "No credential found in $ConfigPath. Run .\Set-Password.ps1 to store an app password, or set the 'Password' key."
}

$authHeader = 'Basic ' + [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes(($Username + ':' + $Password)))

# --------------------------------------------------------------- log file ----

# The bootstrap log above already exists; move to the configured directory if it differs,
# and say so in both files so neither trail dead-ends.
$logDir = [string](Get-Prop $cfg 'LogDirectory' $bootstrapLogDir)
if ($logDir -ne $bootstrapLogDir) {
    $newLog = Join-Path $logDir ('backup-{0}-{1}.log' -f $configTag, (Get-Date -Format 'yyyyMMdd'))
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Write-Log "continuing in the configured log directory: $newLog" 'DEBUG'
        $script:LogFile = $newLog
        Write-Log "(startup was logged in $bootstrapLogDir until the configuration was read)" 'DEBUG'
    } catch {
        Write-Log "LogDirectory '$logDir' is unusable ($($_.Exception.Message)) - staying in $bootstrapLogDir" 'WARN'
    }
}

foreach ($w in $script:StartupWarnings) { Write-Log $w 'WARN' }
if ($script:StartupWarnings.Count -gt 0) {
    Write-Log 'A misspelled setting keeps its DEFAULT value, which can change what this run does.' 'WARN'
    Wait-ForAcknowledgement
}

# ------------------------------------------------------------- single run ----

$lockPath = Join-Path $logDir ('backup-{0}.lock' -f $configTag)
$lockStream = $null
try {
    $lockStream = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    Write-Log "Another backup run holds $lockPath - exiting." 'WARN'
    exit 0
}

# ------------------------------------------------------------ dav helpers ----

$davBase     = '{0}/remote.php/dav/files/{1}' -f $ServerUrl, [Uri]::EscapeDataString($Username)
$davBasePath = [Uri]::UnescapeDataString(([Uri]$davBase).AbsolutePath).TrimEnd('/')

function ConvertTo-DavUrl {
    # $RelPath is relative to the user's WebDAV root, '/'-separated, unescaped.
    param([string] $RelPath)
    if ([string]::IsNullOrEmpty($RelPath)) { return $davBase }
    $escaped = ($RelPath.Trim('/') -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    return ($davBase + '/' + $escaped)
}

function Invoke-DavRequest {
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $Method,
        [hashtable] $ExtraHeaders,
        [string] $Body,
        [string] $OutFile
    )
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Method            = $Method
    $request.Timeout           = $TimeoutSeconds * 1000
    $request.ReadWriteTimeout  = $TimeoutSeconds * 1000
    $request.UserAgent         = 'CloudBackupScript/1.1'
    # Redirects are not followed: HttpWebRequest would re-send the Authorization
    # header to wherever the server points, including a different host. A redirect
    # is reported as an error instead, telling the user to fix ServerUrl.
    $request.AllowAutoRedirect = $false
    $request.KeepAlive         = $true
    $request.Headers.Add('Authorization', $authHeader)
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $request.Headers.Add($k, $ExtraHeaders[$k]) } }

    if ($Body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentType   = 'application/xml; charset=utf-8'
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }

    $response = $null
    try {
        $response = $request.GetResponse()
        $code = [int]$response.StatusCode
        if ($code -ge 300 -and $code -lt 400) {
            $location = $response.Headers['Location']
            throw "Server redirected ($code) to '$location'. Set ServerUrl to the final address (typically the https:// form) - redirects are not followed."
        }
        $responseStream = $response.GetResponseStream()
        if ($OutFile) {
            $file = [IO.File]::Open($OutFile, 'Create', 'Write', 'None')
            try { $responseStream.CopyTo($file, 81920) } finally { $file.Dispose() }
            return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Content = $null }
        }
        $reader = New-Object IO.StreamReader($responseStream, [Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Content = $text }
    } catch [Net.WebException] {
        $status = 0
        # Captured before the switch: 'switch' rebinds $_ to the value being tested, so
        # $_.Exception inside a switch branch refers to the status code, not the error.
        $webMessage = $_.Exception.Message
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        switch ($status) {
            401 { throw "401 Unauthorized for $Url - check Username and the app password (Nextcloud: Settings > Security > Devices & sessions > Create new app password)." }
            403 { throw "403 Forbidden for $Url - the account may lack access, or two-factor auth requires an app password." }
            404 { throw "404 Not Found for $Url - check ServerUrl, Username and RemoteRoot." }
            default { throw "$Method $Url failed ($status): $webMessage" }
        }
    } finally {
        if ($response) { $response.Dispose() }
    }
}

function Invoke-WithRetry {
    param([Parameter(Mandatory)][scriptblock] $Action, [string] $What = 'request')
    $attempt = 0
    while ($true) {
        $attempt++
        try { return & $Action }
        catch {
            $message = $_.Exception.Message
            # Never retry an error that will not fix itself.
            if ($message -match '^(401|403|404) ' -or $attempt -ge $Retries) { throw }
            $delay = [Math]::Min(60, [Math]::Pow(2, $attempt))
            Write-Log "$What failed (attempt $attempt/$Retries): $message - retrying in $delay s" 'WARN'
            Start-Sleep -Seconds $delay
        }
    }
}

# oc:fileid is the stable per-file identifier on ownCloud/Nextcloud and survives a move.
# oc:checksums exposes a content hash Nextcloud computed at upload time - present only
# for files uploaded through a client that provided one, absent otherwise. Plain WebDAV
# servers simply omit both from the 200 propstat.
$propfindBody = @'
<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <d:getetag/>
    <oc:fileid/>
    <oc:checksums/>
  </d:prop>
</d:propfind>
'@

function Get-DavChildren {
    # Lists the direct children of a remote directory (path relative to the WebDAV root).
    param([string] $RelPath)

    $url = ConvertTo-DavUrl $RelPath
    $response = Invoke-WithRetry -What "PROPFIND /$RelPath" -Action {
        Invoke-DavRequest -Url $url -Method 'PROPFIND' -ExtraHeaders @{ Depth = '1' } -Body $propfindBody
    }

    $xml = [xml] $response.Content
    $ns  = New-Object Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('d', 'DAV:')
    $ns.AddNamespace('oc', 'http://owncloud.org/ns')

    $self = $RelPath.Trim('/')
    foreach ($node in $xml.SelectNodes('//d:response', $ns)) {
        $hrefNode = $node.SelectSingleNode('d:href', $ns)
        if (-not $hrefNode) { continue }
        $href = $hrefNode.InnerText
        $path = if ($href -match '^https?://') { ([Uri]$href).AbsolutePath } else { $href }
        $path = [Uri]::UnescapeDataString($path)
        # Exact-prefix match: '/files/sylvain' must not swallow '/files/sylvain2'.
        if ($path -ne $davBasePath -and -not $path.StartsWith($davBasePath + '/')) { continue }

        $rel = $path.Substring($davBasePath.Length).Trim('/')
        if ($rel -eq $self) { continue }   # the collection itself

        # Unescaping happens after the prefix check, so a hostile href could smuggle
        # dot segments past it. Never let a remote path climb out of LocalRoot.
        $segments = $rel -split '/'
        if ($segments -contains '..' -or $segments -contains '.') {
            Write-Log "ignored suspicious server path: $rel" 'WARN'
            continue
        }

        $ok = $node.SelectSingleNode("d:propstat[contains(d:status,'200 OK')]/d:prop", $ns)
        if (-not $ok) { continue }

        $isDir = $null -ne $ok.SelectSingleNode('d:resourcetype/d:collection', $ns)

        $size = [long]0
        $sizeNode = $ok.SelectSingleNode('d:getcontentlength', $ns)
        if ($sizeNode -and $sizeNode.InnerText) { [void][long]::TryParse($sizeNode.InnerText, [ref] $size) }

        $modified = [DateTime]::MinValue
        $modNode = $ok.SelectSingleNode('d:getlastmodified', $ns)
        if ($modNode -and $modNode.InnerText) {
            try { $modified = [DateTime]::Parse($modNode.InnerText, [Globalization.CultureInfo]::InvariantCulture) } catch { }
        }

        $etag = ''
        $etagNode = $ok.SelectSingleNode('d:getetag', $ns)
        if ($etagNode) { $etag = $etagNode.InnerText -replace '^W/', '' -replace '"', '' }

        $fileId = ''
        $idNode = $ok.SelectSingleNode('oc:fileid', $ns)
        if ($idNode) { $fileId = $idNode.InnerText.Trim() }

        # Nextcloud packs one or more "ALGO:hex" tokens, space-separated, into a single
        # <oc:checksum> element, e.g. "SHA1:abc... MD5:def...".
        $checksums = @{}
        $checksumNode = $ok.SelectSingleNode('oc:checksums/oc:checksum', $ns)
        if ($checksumNode -and $checksumNode.InnerText) {
            foreach ($token in ($checksumNode.InnerText.Trim() -split '\s+')) {
                $parts = $token -split ':', 2
                if ($parts.Count -eq 2 -and $parts[1]) { $checksums[$parts[0].ToUpperInvariant()] = $parts[1] }
            }
        }

        [pscustomobject]@{
            RelPath   = $rel
            IsDir     = $isDir
            Size      = $size
            Modified  = $modified
            ETag      = $etag
            FileId    = $fileId
            Checksums = $checksums
        }
    }
}

# ----------------------------------------------------------- local paths -----

function ConvertTo-LocalPath {
    param([string] $Root, [string] $RelPath)
    $path = [IO.Path]::Combine($Root, ($RelPath -replace '/', '\'))
    if ($path.Length -ge 240 -and $path -match '^[A-Za-z]:\\') {
        $path = '\\?\' + $path   # opt into long-path handling for deep trees
    }
    return $path
}

function New-ParentDirectory {
    param([string] $Path)
    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Get-TimeKey {
    param([DateTime] $Utc)
    return $Utc.ToString('yyyyMMddHHmmss')   # second resolution: what WebDAV reports
}

function ConvertTo-ExtendedPath {
    # \\?\ form, so enumeration is not capped at MAX_PATH on deep trees.
    param([string] $Path)
    if ($Path -like '\\?\*') { return $Path }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -like '\\*') { return '\\?\UNC\' + $full.Substring(2) }
    if ($full -match '^[A-Za-z]:\\') { return '\\?\' + $full }
    return $full
}

function Get-LocalRelativeFile {
    <#
        Walks LocalRoot and emits every file's path relative to it, '/'-separated, so it can
        be compared against remote paths. Uses .NET enumeration rather than Get-ChildItem
        -Recurse: on a tree of a few hundred thousand files the difference is minutes.

        Mirrors the remote walk's skipping rules - an excluded directory is not descended
        into, exactly as on the server side - otherwise everything beneath an excluded
        folder would look like an orphan.
    #>
    param([Parameter(Mandatory)][string] $Root, [string[]] $SkipFullPaths = @())

    $found = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push([pscustomobject]@{ Full = (ConvertTo-ExtendedPath $Root); Rel = '' })

    $skip = New-Object 'System.Collections.Generic.HashSet[string]'([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $SkipFullPaths) { if ($p) { [void]$skip.Add((ConvertTo-ExtendedPath $p)) } }

    while ($stack.Count -gt 0) {
        $node = $stack.Pop()

        try { $subdirs = @([IO.Directory]::EnumerateDirectories($node.Full)) }
        catch { Write-Log "cannot list local folder '$($node.Rel)' - $($_.Exception.Message)" 'WARN'; continue }

        foreach ($sub in $subdirs) {
            if ($skip.Contains($sub.TrimEnd('\'))) { continue }   # _trash / _versions
            $name = [IO.Path]::GetFileName($sub)
            $childRel = if ($node.Rel) { $node.Rel + '/' + $name } else { $name }
            if (Test-Excluded $childRel) { continue }
            $stack.Push([pscustomobject]@{ Full = $sub; Rel = $childRel })
        }

        try { $files = @([IO.Directory]::EnumerateFiles($node.Full)) }
        catch { Write-Log "cannot list local files in '$($node.Rel)' - $($_.Exception.Message)" 'WARN'; continue }

        foreach ($f in $files) {
            $name = [IO.Path]::GetFileName($f)
            $rel  = if ($node.Rel) { $node.Rel + '/' + $name } else { $name }
            if (Test-Excluded $rel) { continue }
            $found.Add($rel)
        }
    }
    return $found
}

function Get-FileHashes {
    # Streams the file once through all requested algorithms - avoids re-reading a large
    # file per algorithm when both a SHA-256 baseline and a server-supplied SHA1/MD5
    # cross-check are wanted in the same pass.
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string[]] $Algorithms)
    $hashers = @{}
    try {
        foreach ($name in $Algorithms) {
            $hashers[$name] = switch ($name) {
                'SHA256' { [Security.Cryptography.SHA256]::Create() }
                'SHA1'   { [Security.Cryptography.SHA1]::Create() }
                'MD5'    { [Security.Cryptography.MD5]::Create() }
                default  { throw "unsupported hash algorithm: $name" }
            }
        }
        $stream = [IO.File]::OpenRead($Path)
        try {
            $buffer = New-Object byte[] 1MB
            while ($true) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                foreach ($h in $hashers.Values) { [void]$h.TransformBlock($buffer, 0, $read, $null, 0) }
            }
            foreach ($h in $hashers.Values) { [void]$h.TransformFinalBlock(@(), 0, 0) }
        } finally { $stream.Dispose() }

        $result = @{}
        foreach ($name in $hashers.Keys) { $result[$name] = [BitConverter]::ToString($hashers[$name].Hash) -replace '-', '' }
        return $result
    } finally {
        foreach ($h in $hashers.Values) { $h.Dispose() }
    }
}

$invalidChars = @([IO.Path]::GetInvalidFileNameChars() | Where-Object { $_ -ne [char]'/' -and $_ -ne [char]'\' })

function Test-Excluded {
    param([string] $RelPath)
    $leaf = ($RelPath -split '/')[-1]
    foreach ($pattern in $Exclude) {
        if ($RelPath -like $pattern) { return $true }
        if ($leaf -like $pattern) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- state ------

$statePath = [string](Get-Prop $cfg 'StatePath' (Join-Path $PSScriptRoot ('state-{0}.json' -f $configTag)))
$oldState = @{}
if ($Full) {
    Write-Log '-Full specified: ignoring saved state, re-verifying every file.'
} elseif (Test-Path -LiteralPath $statePath) {
    try {
        $loaded = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $loaded.PSObject.Properties) {
            $oldState[$property.Name] = @{
                ETag   = [string](Get-Prop $property.Value 'ETag' '')
                Size   = [long](Get-Prop $property.Value 'Size' 0)
                FileId = [string](Get-Prop $property.Value 'FileId' '')   # absent in states written before v1.1
                Hash   = [string](Get-Prop $property.Value 'Hash' '')     # absent in states written before v1.2, or for enrolled-without-checksum files
            }
        }
        Write-Log "Loaded state for $($oldState.Count) file(s) from $statePath" 'DEBUG'
    } catch {
        Write-Log "State file unreadable ($($_.Exception.Message)) - falling back to a full comparison." 'WARN'
        $oldState = @{}
    }
}

# ----------------------------------------------------------------- run -------

$startedAt = Get-Date
$runStamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
Write-Log "=== Backup started: $ServerUrl (user $Username), remote '/$RemoteRoot' -> $LocalRoot ==="
if ($DryRun) { Write-Log 'DRY RUN - nothing will be written locally.' 'WARN' }

if ($Verify) { Write-Log '-Verify specified: every unchanged local file will be rehashed and checked.' }

$newState = @{}
$stats = [ordered]@{
    Directories = 0; Scanned = 0; Downloaded = 0; Unchanged = 0; Moved = 0
    Versioned   = 0; Skipped = 0; Removed = 0; Orphaned = 0; Failed = 0; Bytes = [long]0; SavedBytes = [long]0
    ChecksumConfirmed = 0; TrustedUnverified = 0; CorruptionFound = 0; Unverifiable = 0; Baselined = 0
}
$exitCode = 0

try {
    if (-not (Test-Path -LiteralPath $LocalRoot)) {
        if ($DryRun) { Write-Log "Would create $LocalRoot" }
        else { New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null }
    }

    # --- phase 1: enumerate the remote tree ----------------------------------
    # Everything is collected before anything is transferred: a move can only be
    # recognised once both the old and the new path are known.

    $remoteFiles = New-Object 'System.Collections.Generic.List[object]'
    # Every path the server told us about, whatever we then did with it. Windows compares
    # paths case-insensitively, so this must too - otherwise a case difference between the
    # server and the local copy would make a perfectly good file look orphaned.
    $remoteRels = New-Object 'System.Collections.Generic.HashSet[string]'([StringComparer]::OrdinalIgnoreCase)
    $enumerationComplete = $true

    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($RemoteRoot)

    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        $stats.Directories++

        try { $children = @(Get-DavChildren -RelPath $dir) }
        catch {
            Write-Log "Cannot list '/$dir': $($_.Exception.Message)" 'ERROR'
            $stats.Failed++
            $enumerationComplete = $false   # disables the orphan sweep for this run
            if ($_.Exception.Message -match '^(401|403) ' -or $dir -eq $RemoteRoot) { throw }
            # An unlistable directory must not read as a remote deletion of its
            # contents: carry every previously known file under it forward.
            $dirRel = if ($RemoteRoot) { $dir.Substring($RemoteRoot.Length).Trim('/') } else { $dir.Trim('/') }
            foreach ($key in @($oldState.Keys)) {
                if ($key.StartsWith($dirRel + '/')) { $newState[$key] = $oldState[$key] }
            }
            continue
        }

        foreach ($item in $children) {
            # Path relative to RemoteRoot - this is what mirrors into LocalRoot.
            $rel = if ($RemoteRoot) { $item.RelPath.Substring($RemoteRoot.Length).Trim('/') } else { $item.RelPath }
            if (-not $rel) { continue }

            # Recorded before any exclusion or skip decision: the question this answers is
            # "does the server have something at this path", not "did we back it up".
            if (-not $item.IsDir) { [void]$remoteRels.Add($rel) }

            if (Test-Excluded $rel) {
                Write-Log "excluded: $rel" 'DEBUG'
                $stats.Skipped++
                # Carry the old entry over, otherwise a newly added exclusion would look
                # like a remote deletion and trash the local copy.
                if ($oldState.ContainsKey($rel)) { $newState[$rel] = $oldState[$rel] }
                continue
            }

            $badChar = @($rel.ToCharArray() | Where-Object { $invalidChars -contains $_ })
            if ($badChar.Count -gt 0) {
                Write-Log "skipped (name not valid on Windows): $rel" 'WARN'
                $stats.Skipped++
                continue
            }

            if ($item.IsDir) {
                $queue.Enqueue($item.RelPath)
                $localDir = ConvertTo-LocalPath $LocalRoot $rel
                if (-not (Test-Path -LiteralPath $localDir)) {
                    if ($DryRun) { Write-Log "would create dir: $rel" }
                    else { New-Item -ItemType Directory -Path $localDir -Force | Out-Null }
                }
                continue
            }

            $stats.Scanned++

            if ($MaxFileSizeMB -gt 0 -and $item.Size -gt ($MaxFileSizeMB * 1MB)) {
                Write-Log ('skipped (larger than {0} MB): {1}' -f $MaxFileSizeMB, $rel) 'WARN'
                $stats.Skipped++
                if ($oldState.ContainsKey($rel)) { $newState[$rel] = $oldState[$rel] }
                continue
            }

            # Hash is filled in during phase 3, once it is known whether the file was
            # downloaded, carried forward unchanged, or trusted at enrollment.
            $newState[$rel] = @{ ETag = $item.ETag; Size = $item.Size; FileId = $item.FileId; Hash = '' }
            $remoteFiles.Add([pscustomobject]@{
                Rel       = $rel
                RelPath   = $item.RelPath
                Size      = $item.Size
                Modified  = $item.Modified
                ETag      = $item.ETag
                FileId    = $item.FileId
                Checksums = $item.Checksums
            })
        }
    }

    # --- phase 2: what disappeared, and what could be a move source ----------

    $vanished = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($key in $oldState.Keys) { if (-not $newState.ContainsKey($key)) { [void]$vanished.Add($key) } }

    # Index vanished paths whose local file still exists, under every identity we can
    # form: fileid (authoritative), etag+size, and name+size+mtime (heuristic, for
    # servers that expose neither a fileid nor a move-stable etag).
    $moveIndex = @{}
    if ($DetectMoves) {
        foreach ($rel in $vanished) {
            $source = ConvertTo-LocalPath $LocalRoot $rel
            # Anything here is best-effort: failing to index a move candidate only costs a
            # re-download, so a file that vanishes between the test and the stat (a log the
            # sync client is rotating, a dropped network drive) must not abort the run.
            try {
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
                $entry = $oldState[$rel]
                $sourceFile = Get-Item -LiteralPath $source -ErrorAction Stop
            } catch {
                Write-Log "could not examine $rel for move detection - $($_.Exception.Message)" 'DEBUG'
                continue
            }
            $keys = @()
            if ($entry.FileId) { $keys += ('id:' + $entry.FileId) }
            if ($entry.ETag)   { $keys += ('et:{0}|{1}' -f $entry.ETag, $entry.Size) }
            $keys += ('nm:{0}|{1}|{2}' -f ($rel -split '/')[-1], $sourceFile.Length,
                                          (Get-TimeKey $sourceFile.LastWriteTimeUtc))
            foreach ($k in $keys) {
                if (-not $moveIndex.ContainsKey($k)) { $moveIndex[$k] = New-Object 'System.Collections.Generic.List[string]' }
                $moveIndex[$k].Add($rel)
            }
        }
    }
    $moveConsumed = New-Object 'System.Collections.Generic.HashSet[string]'

    # --- phase 3: transfer ----------------------------------------------------

    foreach ($file in $remoteFiles) {
      $rel = $file.Rel
      # One unreadable path must never abort a run that may already have taken hours. Any
      # error handling a single file is recorded against that file and the walk continues;
      # the download itself has its own, more specific handler further down.
      try {
        $localPath = ConvertTo-LocalPath $LocalRoot $rel
        $localExists = Test-Path -LiteralPath $localPath -PathType Leaf

        # -- move detection: adopt the local copy from its previous path --------
        if (-not $localExists -and $DetectMoves -and $moveIndex.Count -gt 0) {
            $lookup = @()
            # fileid is authoritative and matches even if the content also changed;
            # the other two only identify an unmodified copy.
            if ($file.FileId) { $lookup += ('id:' + $file.FileId) }
            if ($file.ETag)   { $lookup += ('et:{0}|{1}' -f $file.ETag, $file.Size) }
            if ($file.Modified -ne [DateTime]::MinValue) {
                $lookup += ('nm:{0}|{1}|{2}' -f ($rel -split '/')[-1], $file.Size,
                                                (Get-TimeKey $file.Modified.ToUniversalTime()))
            }

            $sourceRel = $null
            foreach ($k in $lookup) {
                if (-not $moveIndex.ContainsKey($k)) { continue }
                foreach ($candidate in @($moveIndex[$k])) {
                    if ($moveConsumed.Contains($candidate)) { continue }
                    $candidatePath = ConvertTo-LocalPath $LocalRoot $candidate
                    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) { $sourceRel = $candidate; break }
                }
                if ($sourceRel) { break }
            }

            if ($sourceRel) {
                $sourcePath = ConvertTo-LocalPath $LocalRoot $sourceRel
                if ($DryRun) {
                    Write-Log "would move locally: $sourceRel -> $rel"
                    $stats.Moved++
                    $stats.SavedBytes += $file.Size
                    [void]$moveConsumed.Add($sourceRel)
                    [void]$vanished.Remove($sourceRel)
                    continue
                }
                try {
                    New-ParentDirectory $localPath
                    Move-Item -LiteralPath $sourcePath -Destination $localPath -Force
                    [void]$moveConsumed.Add($sourceRel)
                    [void]$vanished.Remove($sourceRel)
                    $stats.Moved++
                    $stats.SavedBytes += $file.Size
                    Write-Log "moved locally: $sourceRel -> $rel"
                    # The server regenerates the ETag on a move, so the old ETag says
                    # nothing about the new path. Drop any stale entry and let the
                    # size + mtime comparison below decide whether the content also
                    # changed - a pure move then needs no transfer at all.
                    $oldState.Remove($rel)
                    $localExists = $true
                } catch {
                    # Counters are only incremented after a successful Move-Item, so
                    # there is nothing to roll back here - just fall through to a
                    # normal download.
                    Write-Log "could not move $sourceRel -> $rel ($($_.Exception.Message)); downloading instead" 'WARN'
                }
            }
        }

        # -- change detection ---------------------------------------------------
        $needsDownload = $true
        $carryHash = ''
        if ($localExists) {
          # Everything that reads the local copy sits inside this guard. A file can vanish
          # between the existence test above and the read below - a sync client's temporary
          # transfer file, or a network share dropping a handle. That is not a failure: treat
          # the copy as absent and let the normal download path deal with it.
          try {
            $localFile = Get-Item -LiteralPath $localPath -ErrorAction Stop
            if ($oldState.ContainsKey($rel)) {
                $known = $oldState[$rel]
                if ($known.ETag -and $known.ETag -eq $file.ETag -and $localFile.Length -eq $file.Size) {
                    $needsDownload = $false
                    $carryHash = $known.Hash   # preserve the existing baseline across an unchanged run

                    if ($known.Hash) {
                        if ($Verify) {
                            $localHash = (Get-FileHashes -Path $localPath -Algorithms @('SHA256')).SHA256
                            if ($localHash -ne $known.Hash) {
                                Write-Log "VERIFY: local content diverged from its recorded hash - forcing re-download: $rel" 'WARN'
                                $needsDownload = $true
                                $carryHash = ''
                                $stats.CorruptionFound++
                            }
                        }
                    } elseif ($BaselineLocal) {
                        # Adopts whatever is on disk as the reference. This does NOT confirm
                        # the file is correct - it only makes future -Verify runs meaningful.
                        if ($DryRun) {
                            Write-Log "would adopt a baseline hash for: $rel" 'DEBUG'
                        } else {
                            $carryHash = (Get-FileHashes -Path $localPath -Algorithms @('SHA256')).SHA256
                            Write-Log "baseline adopted from the local copy (content NOT validated): $rel" 'DEBUG'
                        }
                        $stats.Baselined++
                    } elseif ($Verify) {
                        Write-Log "VERIFY: no recorded hash for $rel (run once with -BaselineLocal to adopt the current local content as its baseline) - cannot confirm it is intact" 'WARN'
                        $stats.Unverifiable++
                    }
                }
            } elseif ($localFile.Length -eq $file.Size -and
                      $file.Modified -ne [DateTime]::MinValue -and
                      [Math]::Abs(($localFile.LastWriteTimeUtc - $file.Modified.ToUniversalTime()).TotalSeconds) -le 2) {
                # No state entry - first run over a file that already exists locally.
                # Size + mtime alone cannot prove the content is intact; cross-check
                # against a server-supplied checksum when the server offers one.
                $remoteAlgo = @('SHA256', 'SHA1', 'MD5') | Where-Object { $file.Checksums.ContainsKey($_) } | Select-Object -First 1

                if ($remoteAlgo) {
                    $algos = @('SHA256')
                    if ($remoteAlgo -ne 'SHA256') { $algos += $remoteAlgo }
                    $localHashes = Get-FileHashes -Path $localPath -Algorithms $algos
                    if ($localHashes[$remoteAlgo] -ieq $file.Checksums[$remoteAlgo]) {
                        $needsDownload = $false
                        $carryHash = $localHashes['SHA256']
                        $stats.ChecksumConfirmed++
                        Write-Log "enrolled, content confirmed against server $remoteAlgo checksum: $rel" 'DEBUG'
                    } else {
                        Write-Log "content does not match the server's $remoteAlgo checksum - re-downloading enrolled file: $rel" 'WARN'
                        $stats.CorruptionFound++
                    }
                } else {
                    # No checksum published for this file: trusted by size + mtime alone,
                    # same as before hashing existed. No baseline hash is recorded, so a
                    # later -Verify run will flag it as unverifiable rather than silently
                    # passing it.
                    $needsDownload = $false
                    $stats.TrustedUnverified++
                    if ($BaselineLocal -and -not $DryRun) {
                        $carryHash = (Get-FileHashes -Path $localPath -Algorithms @('SHA256')).SHA256
                        $stats.Baselined++
                    }
                    Write-Log "enrolled by size+mtime only - no server checksum available to confirm content: $rel" 'DEBUG'
                }
            }
          } catch {
            Write-Log "local copy of $rel could not be read ($($_.Exception.Message)) - treating as missing" 'DEBUG'
            $localExists   = $false
            $needsDownload = $true
            $carryHash     = ''
          }
        }
        $newState[$rel].Hash = $carryHash

        if (-not $needsDownload) {
            $stats.Unchanged++
            continue
        }

        if ($DryRun) {
            if ($localExists -and $KeepVersions) { Write-Log "would keep previous version of: $rel"; $stats.Versioned++ }
            Write-Log ('would download: {0} ({1:N0} bytes)' -f $rel, $file.Size)
            $stats.Downloaded++
            $stats.Bytes += $file.Size
            continue
        }

        # -- download -----------------------------------------------------------
        $tempPath = $localPath + '.part'
        try {
            $url = ConvertTo-DavUrl $file.RelPath
            Invoke-WithRetry -What "GET $rel" -Action {
                Invoke-DavRequest -Url $url -Method 'GET' -OutFile $tempPath
            } | Out-Null

            $downloaded = (Get-Item -LiteralPath $tempPath).Length
            if ($file.Size -gt 0 -and $downloaded -ne $file.Size) {
                throw "size mismatch: expected $($file.Size) bytes, got $downloaded"
            }

            # Recorded now so every file this script fetches has a -Verify baseline from
            # here on, regardless of how it was matched at enrollment.
            $newState[$rel].Hash = (Get-FileHashes -Path $tempPath -Algorithms @('SHA256')).SHA256

            # Retire the previous content only once the replacement is safely on disk.
            if ($localExists -and $KeepVersions) {
                $versionTarget = ConvertTo-LocalPath ([IO.Path]::Combine($VersionsPath, $runStamp)) $rel
                try {
                    New-ParentDirectory $versionTarget
                    Move-Item -LiteralPath $localPath -Destination $versionTarget -Force
                    $stats.Versioned++
                    Write-Log "previous version kept: $rel" 'DEBUG'
                } catch {
                    Write-Log "could not keep previous version of $rel - $($_.Exception.Message)" 'WARN'
                }
            }

            Move-Item -LiteralPath $tempPath -Destination $localPath -Force
            if ($file.Modified -ne [DateTime]::MinValue) {
                (Get-Item -LiteralPath $localPath).LastWriteTimeUtc = $file.Modified.ToUniversalTime()
            }

            $stats.Downloaded++
            $stats.Bytes += $downloaded
            Write-Log ('downloaded: {0} ({1:N0} bytes)' -f $rel, $downloaded)
        } catch {
            Write-Log "FAILED: $rel - $($_.Exception.Message)" 'ERROR'
            $stats.Failed++
            $newState.Remove($rel)   # so the next run retries it
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
      } catch {
        # Reached only for failures outside the download handler above: stat'ing the local
        # copy, move detection, hashing. Record and move on.
        Write-Log "FAILED (skipped): $rel - $($_.Exception.Message)" 'ERROR'
        $stats.Failed++
        $newState.Remove($rel)   # so the next run retries it
      }
    }

    # --- phase 4: paths that really disappeared -------------------------------

    if ($vanished.Count -gt 0) {
        if (-not $DeleteRemoved) {
            Write-Log "$($vanished.Count) tracked file(s) no longer exist remotely; kept locally (DeleteRemoved is false)."
            foreach ($rel in $vanished) {
                Write-Log "gone remotely, kept: $rel" 'DEBUG'
                $newState[$rel] = $oldState[$rel]   # keep tracking, so it is reported only once
            }
        } else {
            $trashRoot = [IO.Path]::Combine($TrashPath, $runStamp)
            foreach ($rel in $vanished) {
                $localPath = ConvertTo-LocalPath $LocalRoot $rel
                if (-not (Test-Path -LiteralPath $localPath)) { continue }
                if ($DryRun) { Write-Log "would move to trash: $rel"; $stats.Removed++; continue }
                try {
                    $target = ConvertTo-LocalPath $trashRoot $rel
                    New-ParentDirectory $target
                    Move-Item -LiteralPath $localPath -Destination $target -Force
                    $stats.Removed++
                    Write-Log "moved to trash: $rel"
                } catch {
                    Write-Log "could not trash $rel - $($_.Exception.Message)" 'ERROR'
                    $stats.Failed++
                    $newState[$rel] = $oldState[$rel]
                }
            }
        }
    }

    # --- phase 4b: local files the server has never heard of ------------------
    # Same destination and retention as a remote deletion, but a much bigger blast radius:
    # these files were never downloaded by this script, so every guard below is about not
    # sweeping something on incomplete or misconfigured information.

    if ($TrashLocalOrphans) {
        if (-not $enumerationComplete) {
            Write-Log 'Orphan sweep skipped: a remote folder failed to list this run, so a local file with no counterpart cannot be told apart from one whose folder was never read.' 'WARN'
        } elseif ($remoteRels.Count -eq 0) {
            Write-Log 'Orphan sweep skipped: the server reported no files at all - refusing to treat the whole local tree as orphaned.' 'WARN'
        } elseif (-not (Test-Path -LiteralPath $LocalRoot)) {
            Write-Log 'Orphan sweep skipped: LocalRoot does not exist yet.' 'DEBUG'
        } else {
            $localFiles = Get-LocalRelativeFile -Root $LocalRoot -SkipFullPaths @($TrashPath, $VersionsPath)

            $orphans = New-Object 'System.Collections.Generic.List[string]'
            foreach ($rel in $localFiles) {
                if ($rel -like '*.part') { continue }             # our own interrupted download
                if ($remoteRels.Contains($rel)) { continue }      # server has it
                if ($newState.ContainsKey($rel)) { continue }     # tracked, incl. kept-after-remote-delete
                $orphans.Add($rel)
            }

            $share = if ($localFiles.Count -gt 0) { 100.0 * $orphans.Count / $localFiles.Count } else { 0 }
            if ($MaxOrphanPercent -gt 0 -and $localFiles.Count -ge 20 -and $share -gt $MaxOrphanPercent) {
                # A wrong RemoteRoot makes almost everything look orphaned. Refuse rather
                # than empty the mirror into _trash on a config mistake.
                Write-Log ('Orphan sweep REFUSED: {0} of {1} local files ({2:N1}%) have no counterpart on the server, above the {3}% limit. Check RemoteRoot/LocalRoot. Nothing was moved.' -f `
                    $orphans.Count, $localFiles.Count, $share, $MaxOrphanPercent) 'ERROR'
                $stats.Failed++

                # A bare percentage is not diagnosable. Write the candidates out so the
                # pattern behind them can actually be looked at before anything is moved.
                try {
                    $report = Join-Path $logDir ('orphans-{0}-{1}.txt' -f $configTag, $runStamp)
                    $orphans | Set-Content -LiteralPath $report -Encoding UTF8
                    Write-Log "the full list of paths considered orphaned was written to $report"
                } catch {
                    Write-Log "could not write the orphan report - $($_.Exception.Message)" 'WARN'
                }
                foreach ($sample in ($orphans | Select-Object -First 15)) {
                    Write-Log "    orphan candidate: $sample"
                }
            } elseif ($orphans.Count -eq 0) {
                Write-Log "Orphan sweep: nothing local without a counterpart ($($localFiles.Count) file(s) checked)." 'DEBUG'
            } else {
                $orphanTrash = [IO.Path]::Combine($TrashPath, $runStamp)
                Write-Log "Orphan sweep: $($orphans.Count) local file(s) have no counterpart on the server."
                foreach ($rel in $orphans) {
                    $localPath = ConvertTo-LocalPath $LocalRoot $rel
                    if ($DryRun) { Write-Log "would move orphan to trash: $rel"; $stats.Orphaned++; continue }
                    try {
                        $target = ConvertTo-LocalPath $orphanTrash $rel
                        New-ParentDirectory $target
                        Move-Item -LiteralPath $localPath -Destination $target -Force
                        $stats.Orphaned++
                        Write-Log "orphan moved to trash: $rel"
                    } catch {
                        Write-Log "could not trash orphan $rel - $($_.Exception.Message)" 'ERROR'
                        $stats.Failed++
                    }
                }
            }
        }
    }

    # --- phase 5: persist state ----------------------------------------------

    if (-not $DryRun) {
        $tempState = $statePath + '.tmp'
        ($newState | ConvertTo-Json -Depth 4 -Compress) | Set-Content -LiteralPath $tempState -Encoding UTF8
        Move-Item -LiteralPath $tempState -Destination $statePath -Force
    }
} catch {
    Write-Log "Backup aborted: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'DEBUG'
    $exitCode = 2
} finally {
    # -------------------------------------------------------- housekeeping ---
    if (-not $DryRun) {
        foreach ($area in @(
            @{ Path = $TrashPath;    Days = $TrashRetentionDays;    Label = 'trash' },
            @{ Path = $VersionsPath; Days = $VersionRetentionDays;  Label = 'versions' })) {
            if ($area.Days -gt 0 -and (Test-Path -LiteralPath $area.Path)) {
                Get-ChildItem -LiteralPath $area.Path -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-$area.Days) } |
                    ForEach-Object {
                        Write-Log "purging old $($area.Label): $($_.Name)"
                        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
            }
        }
        if ($LogRetentionDays -gt 0) {
            Get-ChildItem -LiteralPath $logDir -Filter 'backup-*.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }

    $elapsed = (Get-Date) - $startedAt
    Write-Log ('=== Finished in {0:hh\:mm\:ss} | dirs {1}, files {2}, downloaded {3} ({4:N1} MB), unchanged {5}, moved {6} ({7:N1} MB not re-transferred), versioned {8}, skipped {9}, removed {10}, failed {11} ===' -f `
        $elapsed, $stats.Directories, $stats.Scanned, $stats.Downloaded, ($stats.Bytes / 1MB), `
        $stats.Unchanged, $stats.Moved, ($stats.SavedBytes / 1MB), $stats.Versioned, `
        $stats.Skipped, $stats.Removed, $stats.Failed)

    if ($stats.Orphaned -gt 0) {
        Write-Log ('    orphan sweep: {0} local file(s) with no counterpart on the server {1} {2}' -f `
            $stats.Orphaned, $(if ($DryRun) { 'would be moved to' } else { 'moved to' }),
            [IO.Path]::Combine($TrashPath, $runStamp))
    }

    if ($stats.Baselined -gt 0) {
        Write-Log ('    baseline: SHA-256 adopted for {0} local file(s) that had none. Their current content is now the reference for -Verify; it was not itself validated.' -f $stats.Baselined)
    }

    if ($stats.ChecksumConfirmed -gt 0 -or $stats.TrustedUnverified -gt 0 -or $stats.CorruptionFound -gt 0 -or $stats.Unverifiable -gt 0) {
        Write-Log ('    integrity: {0} enrolled+checksum-confirmed, {1} enrolled with no server checksum to check, {2} corruption caught{3}, {4} had no baseline to verify against' -f `
            $stats.ChecksumConfirmed, $stats.TrustedUnverified, $stats.CorruptionFound, `
            $(if ($stats.CorruptionFound -gt 0) { ' (re-downloaded)' } else { '' }), $stats.Unverifiable)
    }

    if ($lockStream) {
        $lockStream.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

if ($exitCode -eq 0 -and $stats.Failed -gt 0) { $exitCode = 1 }
exit $exitCode
