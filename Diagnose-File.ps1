#Requires -Version 5.1
<#
.SYNOPSIS
    Explains why one file is (or is not) re-downloaded by Backup-Cloud.ps1.

.DESCRIPTION
    Puts the three things the decision depends on side by side - what the server reports,
    what state.json remembers, and what is actually on disk - and names the comparison that
    fails. Run it twice in a row: a server ETag that differs between two runs is itself the
    answer, and points at the server rather than at the backup.

.PARAMETER ConfigPath
    The same config the backup uses.

.PARAMETER RelPath
    Path of the file relative to RemoteRoot, '/'-separated, exactly as it appears in the log,
    e.g. "Administration/Membres/Acces.../FILE.pdf"

.EXAMPLE
    .\Diagnose-File.ps1 -ConfigPath .\polygones.json -RelPath "Administration/Membres/x.pdf"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ConfigPath,
    [Parameter(Mandatory)][string] $RelPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol =
    [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

function Get-Prop {
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $Default }
    $v = $Object.$Name
    if ($null -eq $v) { return $Default }
    if (($v -is [string]) -and $v.Trim() -eq '') { return $Default }
    return $v
}

$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ServerUrl  = ([string](Get-Prop $cfg 'ServerUrl')).TrimEnd('/')
$Username   = [string](Get-Prop $cfg 'Username')
$LocalRoot  = [string](Get-Prop $cfg 'LocalRoot')
$RemoteRoot = ([string](Get-Prop $cfg 'RemoteRoot' '/')).Trim('/')

$enc = Get-Prop $cfg 'PasswordEncrypted'
if ($enc) {
    $sec  = ConvertTo-SecureString -String ([string]$enc)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
} else {
    $Password = [string](Get-Prop $cfg 'Password')
}
$auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Username + ':' + $Password)))

$configTag = [IO.Path]::GetFileNameWithoutExtension($ConfigPath)
$statePath = [string](Get-Prop $cfg 'StatePath' (Join-Path $PSScriptRoot ('state-{0}.json' -f $configTag)))

# ------------------------------------------------------------------ server ----
$remoteRel = if ($RemoteRoot) { "$RemoteRoot/$RelPath" } else { $RelPath }
$escaped = ($remoteRel.Trim('/') -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
$url = '{0}/remote.php/dav/files/{1}/{2}' -f $ServerUrl, [Uri]::EscapeDataString($Username), $escaped

$body = @'
<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop><d:getcontentlength/><d:getlastmodified/><d:getetag/><oc:fileid/><oc:checksums/></d:prop>
</d:propfind>
'@

function Invoke-Propfind {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Method = 'PROPFIND'
    $req.Headers.Add('Authorization', $auth)
    $req.Headers.Add('Depth', '0')
    $req.ContentType = 'application/xml; charset=utf-8'
    $req.AllowAutoRedirect = $false
    $b = [Text.Encoding]::UTF8.GetBytes($body)
    $req.ContentLength = $b.Length
    $s = $req.GetRequestStream(); $s.Write($b, 0, $b.Length); $s.Dispose()
    $resp = $req.GetResponse()
    $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd(); $sr.Dispose(); $resp.Dispose()

    $xml = [xml]$txt
    $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('d', 'DAV:'); $ns.AddNamespace('oc', 'http://owncloud.org/ns')
    $ok = $xml.SelectSingleNode("//d:propstat[contains(d:status,'200 OK')]/d:prop", $ns)
    if (-not $ok) { throw "server returned no 200 properties for $url" }

    $etagNode = $ok.SelectSingleNode('d:getetag', $ns)
    $sizeNode = $ok.SelectSingleNode('d:getcontentlength', $ns)
    $modNode  = $ok.SelectSingleNode('d:getlastmodified', $ns)
    $idNode   = $ok.SelectSingleNode('oc:fileid', $ns)
    $ckNode   = $ok.SelectSingleNode('oc:checksums/oc:checksum', $ns)

    $mod = [DateTime]::MinValue
    if ($modNode -and $modNode.InnerText) {
        try { $mod = [DateTime]::Parse($modNode.InnerText, [Globalization.CultureInfo]::InvariantCulture) } catch { }
    }
    [pscustomobject]@{
        ETag     = if ($etagNode) { $etagNode.InnerText -replace '^W/', '' -replace '"', '' } else { '' }
        Size     = if ($sizeNode -and $sizeNode.InnerText) { [long]$sizeNode.InnerText } else { [long]0 }
        Modified = $mod
        FileId   = if ($idNode) { $idNode.InnerText.Trim() } else { '' }
        Checksum = if ($ckNode) { $ckNode.InnerText.Trim() } else { '' }
    }
}

Write-Host "`n=== SERVER (two PROPFINDs, a few seconds apart) ===" -ForegroundColor Cyan
$r1 = Invoke-Propfind
Start-Sleep -Seconds 3
$r2 = Invoke-Propfind
"  ETag  #1 : {0}" -f $r1.ETag
"  ETag  #2 : {0}" -f $r2.ETag
"  stable   : {0}" -f ($r1.ETag -eq $r2.ETag)
"  Size     : {0}" -f $r1.Size
"  Modified : {0:u} (UTC)" -f $r1.Modified.ToUniversalTime()
"  FileId   : {0}" -f $r1.FileId
"  Checksum : {0}" -f $(if ($r1.Checksum) { $r1.Checksum } else { '<none published>' })

Write-Host "`n=== STATE (state.json) ===" -ForegroundColor Cyan
$known = $null
if (Test-Path -LiteralPath $statePath) {
    $loaded = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $match = $loaded.PSObject.Properties | Where-Object { $_.Name -eq $RelPath }
    if ($match) {
        $known = $match.Value
        "  ETag  : {0}" -f (Get-Prop $known 'ETag' '<empty>')
        "  Size  : {0}" -f (Get-Prop $known 'Size' 0)
        "  Hash  : {0}" -f $(if (Get-Prop $known 'Hash') { 'recorded' } else { '<none>' })
    } else {
        Write-Host "  NO ENTRY for this path." -ForegroundColor Yellow
        # Near-misses expose an invisible difference such as Unicode normalisation.
        $near = $loaded.PSObject.Properties.Name | Where-Object { $_.ToLowerInvariant() -replace '[^a-z0-9/.]', '' -eq ($RelPath.ToLowerInvariant() -replace '[^a-z0-9/.]', '') }
        foreach ($n in $near) {
            Write-Host "  but a near-identical key exists:" -ForegroundColor Yellow
            "    state : {0}" -f ([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($n)))
            "    asked : {0}" -f ([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($RelPath)))
        }
    }
} else {
    Write-Host "  state file not found: $statePath" -ForegroundColor Yellow
}

Write-Host "`n=== LOCAL DISK ===" -ForegroundColor Cyan
$localPath = [IO.Path]::Combine($LocalRoot, ($RelPath -replace '/', '\'))
if (Test-Path -LiteralPath $localPath -PathType Leaf) {
    $f = Get-Item -LiteralPath $localPath
    "  Size     : {0}" -f $f.Length
    "  Modified : {0:u} (UTC)" -f $f.LastWriteTimeUtc
    $skew = [Math]::Abs(($f.LastWriteTimeUtc - $r1.Modified.ToUniversalTime()).TotalSeconds)
    "  mtime differs from server by {0:N1} s (tolerance is 2 s)" -f $skew
} else {
    Write-Host "  NOT PRESENT at $localPath" -ForegroundColor Yellow
}

Write-Host "`n=== VERDICT ===" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
    Write-Host "  Local copy missing - it will be downloaded. Expected."
} elseif ($r1.ETag -ne $r2.ETag) {
    Write-Host "  The server's ETag changes between two consecutive requests." -ForegroundColor Red
    Write-Host "  Nothing can be cached against it; every run will re-download this file."
    Write-Host "  This is a server-side problem (often external/shared storage)."
} elseif ($null -eq $known) {
    Write-Host "  No state entry matches this path, so the file is treated as new each run." -ForegroundColor Red
    Write-Host "  If a near-identical key was listed above, the two spellings differ in bytes"
    Write-Host "  (Unicode normalisation) - report those two byte strings."
} elseif ((Get-Prop $known 'ETag' '') -ne $r1.ETag) {
    Write-Host "  The stored ETag differs from the server's, so the file looks changed." -ForegroundColor Red
    "    stored : {0}" -f (Get-Prop $known 'ETag' '<empty>')
    "    server : {0}" -f $r1.ETag
    Write-Host "  If the content has not changed, the server is regenerating ETags."
} elseif ((Get-Item -LiteralPath $localPath).Length -ne $r1.Size) {
    Write-Host "  Local size does not match the server's - it will be re-downloaded." -ForegroundColor Red
} else {
    Write-Host "  Everything matches; this file should NOT be re-downloaded." -ForegroundColor Green
}
Write-Host ''
