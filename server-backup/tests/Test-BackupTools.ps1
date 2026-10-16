#requires -Version 5.1
param([string]$ToolsPath = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
function Assert($Condition,[string]$Message) { if(-not $Condition){throw $Message}; $script:checks++ }
function Expect-Failure([scriptblock]$Action,[string]$Message) {
    $failed=$false
    try { & $Action } catch { $failed=$true }
    Assert $failed $Message
}
$checks=0
$tools=(Resolve-Path -LiteralPath $ToolsPath).Path
foreach($name in @('Backup-UnionServer.ps1','Verify-UnionBackup.ps1')){
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $tools $name),[ref]$tokens,[ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) "$name must parse"
    if($name -eq 'Backup-UnionServer.ps1'){
        foreach($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
            Invoke-Expression $definition.Extent.Text
        }
    }
}
$fixture=Join-Path $env:TEMP ('UnionBackupTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try{
    Assert ((Full-Path 'C:\') -eq 'C:\') 'Drive root retained'
    Assert (Is-Within 'C:\a\b' 'C:\a') 'Child containment'
    Assert (Is-Within 'C:\a' 'C:\a') 'Same path containment'
    Assert (Is-Within 'C:\a' 'C:\') 'Drive containment'
    Assert (-not (Is-Within 'C:\ab' 'C:\a')) 'Sibling prefix rejected'
    Assert (-not (Is-Within 'C:\a\..\outside' 'C:\a')) 'Traversal rejected'
    Assert ((Config-FilePath 'C:\certs\site.pem' 'C:\caddy') -eq 'C:\certs\site.pem') 'Absolute certificate path retained'
    Assert ((Config-FilePath 'keys\site.pem' 'C:\caddy') -eq 'C:\caddy\keys\site.pem') 'Relative certificate path resolved'
    $referencedEnvironment=@{ROOT='C:\storage'};$caddyUserEnvironment=@{}
    Assert ((Expand-CaddyValue '{$ROOT}\caddy') -eq 'C:\storage\caddy') 'Caddy variable expanded'
    Expect-Failure {Expand-CaddyValue '{$UNION_BACKUP_TEST_NONEXISTENT_VAR}'} 'Unresolved Caddy variable fails'
    $sourceDir=Join-Path $fixture 'source'
    New-Item -ItemType Directory -Path $sourceDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $sourceDir '.env'),'secret fixture only')
    [IO.File]::SetAttributes((Join-Path $sourceDir '.env'),[IO.FileAttributes]::Hidden)
    [IO.File]::WriteAllText((Join-Path $sourceDir 'certificate.pem'),'CERT FIXTURE')
    [IO.File]::WriteAllText((Join-Path $sourceDir 'access.log'),'first')
    Assert (@(Tree-Files $sourceDir).Count -eq 3) 'Hidden files enumerated'
    $sources=New-Object Collections.ArrayList
    Add-Source 'fixture' $sourceDir
    Add-Source 'nested' (Join-Path $sourceDir '.env')
    Assert ($sources.Count -eq 1) 'Already included sources deduplicated'
    Expect-Failure { Add-Source 'drive' 'C:\' } 'Whole drive source rejected'
    $baseline=Critical-State $sources[0]
    [IO.File]::WriteAllText((Join-Path $sourceDir 'access.log'),'second')
    Assert (Same-State $baseline (Critical-State $sources[0])) 'Growing logs do not invalidate configuration snapshot'
    [IO.File]::WriteAllText((Join-Path $sourceDir 'certificate.pem'),'CHANGED FIXTURE')
    Assert (-not (Same-State $baseline (Critical-State $sources[0]))) 'Changing HTTPS file invalidates snapshot'
    $run=Join-Path $fixture 'backup'
    New-Item -ItemType Directory -Path $run | Out-Null
    try { Copy-Source $sources[0] $run } catch { Get-Content -LiteralPath (Join-Path $run 'copy.log') | Out-Host; throw }
    $copied=Join-Path (Join-Path $run $sources[0].BackupRelative) '.env'
    Assert ((Get-FileHash -LiteralPath $copied).Hash -eq (Get-FileHash -LiteralPath (Join-Path $sourceDir '.env')).Hash) 'Robocopy includes hidden secrets'
    Expect-Failure {Copy-Source ([pscustomobject]@{BackupRelative='..\outside';IsDirectory=$false;Source=$copied}) $run} 'Copy traversal rejected'
    $junction=Join-Path $sourceDir 'junction'
    New-Item -ItemType Junction -Path $junction -Target $run | Out-Null
    Expect-Failure {@(Tree-Files $sourceDir)} 'Linked directories fail closed'
    # Delete only the junction itself, never its contents.
    [IO.Directory]::Delete($junction)

    # Mocks prevent all real service operations. Only extracted functions run.
    function Stop-Service {param($Name,$ErrorAction) [void]$script:ops.Add('stop');if($script:stopFails){throw 'fixture stop error'} }
    function Start-Service {param($Name,$ErrorAction) [void]$script:ops.Add('start');if($script:startFails){throw 'fixture start error'} }
    function Get-Service {param($Name) $fake=[pscustomobject]@{};Add-Member -InputObject $fake -MemberType ScriptMethod -Name WaitForStatus -Value {param($Status,$Timeout)};return $fake }
    function Copy-Source {param($Source,$RunRoot) [void]$script:ops.Add('copy');if($script:copyFails){throw 'fixture copy error'} }
    $stopFails=$false;$copyFails=$false;$startFails=$false
    $ops=New-Object Collections.ArrayList;$pause=@{Paused=$false}
    Copy-SiteSnapshot $null $run 'FakeService' $true $pause
    Assert (($ops -join ',') -eq 'stop,copy,start' -and -not $pause.Paused) 'Running site stopped and restarted'
    $ops.Clear();$copyFails=$true
    Expect-Failure {Copy-SiteSnapshot $null $run 'FakeService' $true $pause} 'Copy failure propagated'
    Assert (($ops -join ',') -eq 'stop,copy,start' -and -not $pause.Paused) 'Copy failure still restarts site'
    $ops.Clear();$copyFails=$false;$stopFails=$true
    Expect-Failure {Copy-SiteSnapshot $null $run 'FakeService' $true $pause} 'Stop failure propagated'
    Assert (($ops -join ',') -eq 'stop,start' -and -not $pause.Paused) 'Stop failure attempts recovery'
    $ops.Clear();$stopFails=$false;$startFails=$true
    Expect-Failure {Copy-SiteSnapshot $null $run 'FakeService' $true $pause} 'Start failure propagated'
    Assert $pause.Paused 'Outer recovery remains enabled after restart failure'
    $ops.Clear();$startFails=$false;$pause.Paused=$false
    Copy-SiteSnapshot $null $run 'FakeService' $false $pause
    Assert (($ops -join ',') -eq 'copy') 'Originally stopped site stays stopped'

    $verify=Join-Path $tools 'Verify-UnionBackup.ps1'
    $entry=[pscustomobject]@{Path=$copied.Substring($run.Length+1);Length=(Get-Item -LiteralPath $copied -Force).Length;SHA256=(Get-FileHash -LiteralPath $copied).Hash}
    $entry | Export-Csv -LiteralPath (Join-Path $run 'SHA256SUMS.csv') -NoTypeInformation
    Write-Json (Join-Path $run 'summary.json') @{Status='Complete'}
    & $verify -BackupPath $run
    Assert $true 'Valid backup passes verifier'
    [IO.File]::SetAttributes($copied,[IO.FileAttributes]::Normal)
    [IO.File]::WriteAllText($copied,'corrupt fixture')
    Expect-Failure {& $verify -BackupPath $run} 'Tampered backup rejected'
    Remove-Item -LiteralPath $copied -Force
    Expect-Failure {& $verify -BackupPath $run} 'Missing backup file rejected'
    $entry.Path='..\outside';$entry|Export-Csv -LiteralPath (Join-Path $run 'SHA256SUMS.csv') -NoTypeInformation
    Expect-Failure {& $verify -BackupPath $run} 'Unsafe checksum path rejected'
    Write-Json (Join-Path $run 'summary.json') @{Status='INCOMPLETE'}
    Expect-Failure {& $verify -BackupPath $run} 'Incomplete backup rejected'
    Write-Host "PASS: $checks assertions on PowerShell $($PSVersionTable.PSVersion)"
} finally {
    $resolvedFixture=[IO.Path]::GetFullPath($fixture)
    $expectedParent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $resolvedFixture.StartsWith($expectedParent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedFixture) -notlike 'UnionBackupTest-*'){throw 'Unsafe test cleanup path'}
    if(Test-Path -LiteralPath (Join-Path $resolvedFixture 'source\junction')){[IO.Directory]::Delete((Join-Path $resolvedFixture 'source\junction'))}
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
