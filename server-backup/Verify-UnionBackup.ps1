#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BackupPath)
$ErrorActionPreference='Stop'
$root=(Resolve-Path -LiteralPath $BackupPath).Path.TrimEnd('\')
$summary=Get-Content -LiteralPath (Join-Path $root 'summary.json') -Raw | ConvertFrom-Json
if ($summary.Status -ne 'Complete') { throw 'This backup is marked incomplete.' }
$entries=@(Import-Csv -LiteralPath (Join-Path $root 'SHA256SUMS.csv'))
if (-not $entries.Count) { throw 'Empty backup checksum manifest.' }
$failures=New-Object System.Collections.ArrayList
foreach($entry in $entries) {
    $file=[IO.Path]::GetFullPath((Join-Path $root $entry.Path))
    if(-not $file.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe path in checksum manifest.'}
    if(-not (Test-Path -LiteralPath $file -PathType Leaf)){[void]$failures.Add($entry.Path);continue}
    if((Get-Item -LiteralPath $file -Force).Length -ne [long]$entry.Length -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.SHA256){[void]$failures.Add($entry.Path)}
}
if($failures.Count){$failures|ForEach-Object{Write-Warning "Mismatch/missing: $_"};throw "$($failures.Count) backup files failed verification."}
Write-Host "VERIFIED: $($entries.Count) files match their SHA-256 checksums." -ForegroundColor Green
