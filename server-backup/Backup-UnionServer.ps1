#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$AppPath = 'C:\sites\union-app',
    [string]$BackupRoot = 'C:\UnionFullBackups',
    [string]$AppService = 'UnionApp',
    [string[]]$CaddyDataPath = @(),
    [string[]]$ExtraPath = @(),
    [switch]$InspectOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$sources = New-Object System.Collections.ArrayList
$selectedServices = @{}
$referencedEnvironment = @{}
$caddyUserEnvironment = @{}
$siteResolvedEnvironment = @{}

function Full-Path([string]$Value) {
    $absolute = [IO.Path]::GetFullPath($Value)
    $root = [IO.Path]::GetPathRoot($absolute)
    if ($absolute.TrimEnd('\') -eq $root.TrimEnd('\')) { return $root }
    return $absolute.TrimEnd('\')
}
function Is-Within([string]$Child, [string]$Parent) {
    $c = Full-Path $Child; $p = Full-Path $Parent
    return $c.Equals($p, [StringComparison]::OrdinalIgnoreCase) -or $c.StartsWith($p.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Write-Json([string]$File, $Value) {
    [IO.File]::WriteAllText($File, (ConvertTo-Json -InputObject $Value -Depth 20), [Text.UTF8Encoding]::new($false))
}
function Add-Source([string]$Role, [string]$Location) {
    if (-not $Location -or -not (Test-Path -LiteralPath $Location)) { return }
    $resolved = Full-Path ((Resolve-Path -LiteralPath $Location).Path)
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved)) { throw 'A whole drive cannot be used as a file-backup source.' }
    foreach ($existing in $sources) {
        if (Is-Within $resolved $existing.Source) { return }
    }
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked source requires explicit review: $resolved" }
    [void]$sources.Add([pscustomobject]@{ Role=$Role; Source=$resolved; IsDirectory=[bool]$item.PSIsContainer; BackupRelative=('files\{0:D2}-{1}' -f $sources.Count,$Role) })
}
function Tree-Files([string]$Directory) {
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Directory)
    while ($stack.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $stack.Pop() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Junction/symlink requires review before a full backup: $($item.FullName)" }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) } else { $item }
        }
    }
}
function Source-Files($Source) {
    if ($Source.IsDirectory) { Tree-Files $Source.Source } else { Get-Item -LiteralPath $Source.Source -Force }
}
function Source-Relative($Source, [string]$File) {
    if ($Source.IsDirectory) { return $File.Substring($Source.Source.Length).TrimStart('\') }
    return [IO.Path]::GetFileName($File)
}
function Read-ServiceEnvironment([string]$Name) {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name + '\Parameters'
    if (-not (Test-Path -LiteralPath $key)) { return }
    $properties = Get-ItemProperty -LiteralPath $key
    foreach ($propertyName in @('AppEnvironment','AppEnvironmentExtra')) {
        $property = $properties.PSObject.Properties[$propertyName]
        if ($property) {
            foreach ($line in @($property.Value)) {
                if ($line -match '^([^=]+)=(.*)$') { $referencedEnvironment[$matches[1]] = $matches[2] }
            }
        }
    }
}
function Expand-CaddyValue([string]$Value) {
    $expanded = $Value
    foreach ($token in [regex]::Matches($Value, '\{\$([A-Za-z_][A-Za-z0-9_]*)\}')) {
        $name = $token.Groups[1].Value
        $envValue = if ($referencedEnvironment.ContainsKey($name)) { $referencedEnvironment[$name] } else { [Environment]::GetEnvironmentVariable($name,'Machine') }
        if ($null -eq $envValue -and $caddyUserEnvironment.ContainsKey($name)) { $envValue = $caddyUserEnvironment[$name] }
        if ($null -eq $envValue) { throw "Cannot resolve Caddy environment variable $name. Set it for this backup or supply its file path explicitly." }
        $referencedEnvironment[$name] = $envValue
        $expanded = $expanded.Replace($token.Value,$envValue)
    }
    return $expanded
}
function Config-FilePath([string]$Value, [string]$Base) {
    $valueExpanded = Expand-CaddyValue $Value
    if ([IO.Path]::IsPathRooted($valueExpanded)) { return Full-Path $valueExpanded }
    return Full-Path (Join-Path $Base $valueExpanded)
}
function Copy-Source($Source, [string]$RunRoot) {
    $dest = Join-Path $RunRoot $Source.BackupRelative
    if (-not (Is-Within $dest $RunRoot) -or (Full-Path $dest) -eq (Full-Path $RunRoot)) { throw 'Unsafe backup destination' }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    if ($Source.IsDirectory) {
        & robocopy.exe $Source.Source $dest /E /COPY:DAT /DCOPY:DAT /Z /R:1 /W:1 /XJ /NP /NFL /NDL /NJH /NJS ("/LOG+:" + (Join-Path $RunRoot 'copy.log')) | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Copy failed for $($Source.Role); robocopy exit $LASTEXITCODE. See copy.log." }
    } else { Copy-Item -LiteralPath $Source.Source -Destination (Join-Path $dest ([IO.Path]::GetFileName($Source.Source))) -Force }
}
function Copy-SiteSnapshot($Source, [string]$RunRoot, [string]$ServiceName, [bool]$WasRunning, $PauseState) {
    try {
        if ($WasRunning) {
            $PauseState.Paused=$true
            Stop-Service -Name $ServiceName -ErrorAction Stop
            (Get-Service -Name $ServiceName).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60))
        }
        Copy-Source $Source $RunRoot
    } finally {
        if ($PauseState.Paused) {
            Start-Service -Name $ServiceName -ErrorAction Stop
            (Get-Service -Name $ServiceName).WaitForStatus('Running',[TimeSpan]::FromSeconds(60))
            $PauseState.Paused=$false
        }
    }
}
function Critical-State($Source) {
    $state = @{}
    foreach ($file in @(Source-Files $Source)) {
        # Logs may grow while Caddy keeps HTTPS available; they are still copied, but are not configuration state.
        if ($file.Name -match '(?i)\.log(?:\.|$)' -or $file.FullName -match '(?i)[\\/]logs[\\/]') { continue }
        $relative = Source-Relative $Source $file.FullName
        $state[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return ,$state
}
function Same-State($Left,$Right) {
    if ($Left.Count -ne $Right.Count) { return $false }
    foreach ($key in $Left.Keys) { if (-not $Right.ContainsKey($key) -or $Left[$key] -ne $Right[$key]) { return $false } }
    return $true
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as Administrator on the SERVER.' }
if (-not (Test-Path -LiteralPath (Join-Path $AppPath 'package.json'))) { throw "Site not found: $AppPath" }
$AppPath = Full-Path ((Resolve-Path -LiteralPath $AppPath).Path)
$BackupRoot = Full-Path $BackupRoot
if ($BackupRoot -eq [IO.Path]::GetPathRoot($BackupRoot)) { throw 'Choose a dedicated backup directory, not a drive root.' }
$allServices = @(Get-CimInstance Win32_Service)
$appInfo = $allServices | Where-Object Name -eq $AppService | Select-Object -First 1
if (-not $appInfo) { throw "Site service not found: $AppService" }
$selectedServices[$appInfo.Name] = $appInfo
Read-ServiceEnvironment $appInfo.Name
foreach ($name in $referencedEnvironment.Keys) { $siteResolvedEnvironment[$name] = $referencedEnvironment[$name] }
$referencedEnvironment = @{}
Add-Source 'site' $AppPath

# The live process identifies the actual Caddy binary and its service, instead of assuming the current user's profile.
$caddyProcesses = @(Get-CimInstance Win32_Process -Filter "Name='caddy.exe'")
if ($caddyProcesses.Count -ne 1) { throw 'Expected one running Caddy process. Inspect the server before taking a full HTTPS backup.' }
$caddyProcess = $caddyProcesses[0]
if (-not $caddyProcess.ExecutablePath) { throw 'Cannot read the running Caddy executable path.' }
$CaddyDirectory = Split-Path $caddyProcess.ExecutablePath -Parent
$walkId = [uint32]$caddyProcess.ProcessId
for ($i=0; $i -lt 10 -and $walkId -gt 0; $i++) {
    $ancestor = Get-CimInstance Win32_Process -Filter "ProcessId=$walkId"
    if (-not $ancestor -or $ancestor.Name -in @('services.exe','svchost.exe','wininit.exe','taskeng.exe','taskhostw.exe')) { break }
    foreach ($service in @($allServices | Where-Object ProcessId -eq $walkId)) {
        $selectedServices[$service.Name] = $service
        Read-ServiceEnvironment $service.Name
    }
    $walkId = [uint32]$ancestor.ParentProcessId
}
Add-Source 'caddy' $CaddyDirectory
$caddyOwner = Invoke-CimMethod -InputObject $caddyProcess -MethodName GetOwnerSid
if ($caddyOwner.ReturnValue -ne 0) { throw 'Cannot identify the Caddy account for TLS storage discovery.' }
$caddyUserEnvKey = 'Registry::HKEY_USERS\' + $caddyOwner.Sid + '\Environment'
if (Test-Path -LiteralPath $caddyUserEnvKey) {
    foreach ($property in (Get-ItemProperty -LiteralPath $caddyUserEnvKey).PSObject.Properties) {
        if ($property.Name -notlike 'PS*') { $caddyUserEnvironment[$property.Name] = [string]$property.Value }
    }
}

$caddyWorkDir = $CaddyDirectory
foreach ($service in $selectedServices.Values) {
    if ($service.Name -eq $AppService) { continue }
    $parameterKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $service.Name + '\Parameters'
    if (Test-Path -LiteralPath $parameterKey) {
        $settings = Get-ItemProperty -LiteralPath $parameterKey
        if ($settings.PSObject.Properties['AppDirectory']) { $caddyWorkDir = $settings.AppDirectory }
    }
}
$configPath = Join-Path $caddyWorkDir 'Caddyfile'
if ($caddyProcess.CommandLine -match '--config(?:=|\s+)(?:"([^"]+)"|(\S+))') {
    $configArgument = if ($matches[1]) { $matches[1] } else { $matches[2] }
    $configPath = Config-FilePath $configArgument $caddyWorkDir
}
if (-not (Test-Path -LiteralPath $configPath)) { throw "Caddy configuration not found: $configPath. A --resume/API-only setup needs its active configuration identified first." }
Add-Source 'caddy-config' $configPath

# Include service-account and user Caddy defaults; XDG overrides are handled separately.
$profileRoots = @(
    (Join-Path $env:SystemRoot 'System32\config\systemprofile'),
    (Join-Path $env:SystemRoot 'SysWOW64\config\systemprofile'),
    (Join-Path $env:SystemRoot 'ServiceProfiles\LocalService'),
    (Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService')
)
$profileRoots += @(Get-CimInstance Win32_UserProfile | Select-Object -ExpandProperty LocalPath)
foreach ($profileRoot in @($profileRoots | Select-Object -Unique)) {
    if ($profileRoot) { Add-Source 'caddy-profile' (Join-Path $profileRoot 'AppData\Roaming\Caddy') }
}
foreach ($envName in @('XDG_DATA_HOME','XDG_CONFIG_HOME')) {
    $envValue = if ($referencedEnvironment.ContainsKey($envName)) { $referencedEnvironment[$envName] } else { [Environment]::GetEnvironmentVariable($envName,'Machine') }
    if (-not $envValue -and $caddyUserEnvironment.ContainsKey($envName)) { $envValue = $caddyUserEnvironment[$envName] }
    if ($envValue) {
        $referencedEnvironment[$envName] = $envValue
        $xdgPath = Join-Path $envValue 'caddy'
        if (-not (Test-Path -LiteralPath $xdgPath)) { throw "Configured Caddy XDG folder not found: $xdgPath" }
        Add-Source 'caddy-xdg' $xdgPath
    }
}
if ($referencedEnvironment.ContainsKey('APPDATA')) { Add-Source 'caddy-appdata' (Join-Path $referencedEnvironment['APPDATA'] 'Caddy') }
foreach ($extra in @($CaddyDataPath) + @($ExtraPath)) {
    if (-not (Test-Path -LiteralPath $extra)) { throw "Explicit source missing: $extra" }
    Add-Source 'extra' $extra
}

# Resolve imported configuration, filesystem storage roots and explicit TLS certificate/key files.
$configQueue = New-Object 'System.Collections.Generic.Queue[string]'
$configQueue.Enqueue($configPath)
$seenConfigs = @{}
while ($configQueue.Count) {
    $currentConfig = $configQueue.Dequeue()
    if ($seenConfigs.ContainsKey($currentConfig)) { continue }
    $seenConfigs[$currentConfig] = $true
    $configText = Expand-CaddyValue (Get-Content -LiteralPath $currentConfig -Raw)
    if ($configText.TrimStart().StartsWith('{') -and $currentConfig -match '\.json$') {
        throw 'JSON Caddy configuration detected. Review storage/certificate paths explicitly before a complete backup.'
    }
    foreach ($storage in [regex]::Matches($configText,'(?m)^\s*storage\s+([A-Za-z0-9_-]+)')) {
        if ($storage.Groups[1].Value -ne 'file_system') { throw 'External Caddy storage requires its own backup; no full backup has been taken.' }
    }
    foreach ($storage in [regex]::Matches($configText,'(?s)storage\s+file_system\s*\{([^}]+)\}')) {
        $block = $storage.Groups[1].Value
        if ($block -match '(?m)^\s*root\s+(?:"([^"]+)"|(\S+))') {
            $rootValue = if ($matches[1]) { $matches[1] } else { $matches[2] }
            $storagePath = Config-FilePath $rootValue $caddyWorkDir
            if (-not (Test-Path -LiteralPath $storagePath)) { throw "Caddy storage folder missing: $storagePath" }
            Add-Source 'caddy-storage' $storagePath
        }
    }
    foreach ($line in ($configText -split '\r?\n')) {
        if ($line -match '^\s*tls\s+(?:"([^"]+)"|(\S+))\s+(?:"([^"]+)"|(\S+))\s*(?:\{|#.*)?$') {
            $certValue = if ($matches[1]) { $matches[1] } else { $matches[2] }
            $keyValue = if ($matches[3]) { $matches[3] } else { $matches[4] }
            if ($certValue -match '\.(?:pem|crt|cer)$|[:/\\]' -or $keyValue -match '\.(?:pem|key)$|[:/\\]' -or (Test-Path -LiteralPath (Config-FilePath $certValue $caddyWorkDir))) {
                foreach ($tlsValue in @($certValue,$keyValue)) {
                    $tlsPath = Config-FilePath $tlsValue $caddyWorkDir
                    if (-not (Test-Path -LiteralPath $tlsPath)) { throw "Referenced HTTPS certificate/key is missing: $tlsPath" }
                    Add-Source 'https-file' $tlsPath
                }
            }
        }
        if ($line -match '^\s*import\s+(?:"([^"]+)"|(\S+))(?:\s.*)?$') {
            $importValue = if ($matches[1]) { $matches[1] } else { $matches[2] }
            $importPath = Config-FilePath $importValue (Split-Path $currentConfig -Parent)
            if ($importValue -match '[/\\.*]' -or (Test-Path -LiteralPath $importPath)) {
                $importedFiles = @(Get-ChildItem -Path $importPath -File -ErrorAction SilentlyContinue)
                foreach ($imported in $importedFiles) { Add-Source 'caddy-import' $imported.FullName; $configQueue.Enqueue($imported.FullName) }
                if (-not $importedFiles.Count -and $importValue -notmatch '[*?]') { throw "Imported Caddy file missing: $importPath" }
            }
        }
    }
}

$nodeCommand = Get-Command node.exe -ErrorAction Stop
Add-Source 'node-runtime' (Split-Path $nodeCommand.Source -Parent)
foreach ($service in $selectedServices.Values) {
    if ($service.PathName -match '^(?:"([^"]+)"|(\S+))') {
        $wrapper = if ($matches[1]) { $matches[1] } else { $matches[2] }
        if (Test-Path -LiteralPath $wrapper) { Add-Source 'service-wrapper' $wrapper }
    }
}

$dbNames = 'DATABASE_URL|DIRECT_URL|MONGO_URI|MONGODB_URI|MONGODB_URL|DB_HOST|MYSQL_HOST|PGHOST|POSTGRES_HOST|SQLSERVER_CONNECTION_STRING|ConnectionStrings__DefaultConnection'
$envRefPattern = @'
process\.env(?:\.([A-Za-z_][A-Za-z0-9_]*)|\[['"]([A-Za-z_][A-Za-z0-9_]*)['"]\])
'@
foreach ($sourceFolder in @('app','src','lib','components','scripts')) {
    $sourceDirectory = Join-Path $AppPath $sourceFolder
    if (-not (Test-Path -LiteralPath $sourceDirectory)) { continue }
    foreach ($sourceFile in @(Tree-Files $sourceDirectory | Where-Object Extension -in @('.js','.ts','.tsx','.mjs','.cjs'))) {
        foreach ($envRef in [regex]::Matches([string](Get-Content -LiteralPath $sourceFile.FullName -Raw), $envRefPattern.Trim())) {
            $name = if ($envRef.Groups[1].Success) { $envRef.Groups[1].Value } else { $envRef.Groups[2].Value }
            if (-not $siteResolvedEnvironment.ContainsKey($name)) {
                $machineValue = [Environment]::GetEnvironmentVariable($name,'Machine')
                if ($null -ne $machineValue) { $siteResolvedEnvironment[$name] = $machineValue }
            }
        }
    }
}
foreach ($name in @($siteResolvedEnvironment.Keys)) {
    if ($name -match ('^(?:' + $dbNames + ')$') -and $siteResolvedEnvironment[$name]) { throw "Site database variable $name requires a native database backup." }
}
foreach ($envFile in Get-ChildItem -LiteralPath $AppPath -Force -File | Where-Object Name -Like '.env*') {
    foreach ($match in [regex]::Matches([string](Get-Content -LiteralPath $envFile.FullName -Raw), ('(?im)^\s*(?:export\s+)?(' + $dbNames + ')\s*=\s*(.+)$'))) {
        $value = $match.Groups[2].Value.Trim().Trim('"').Trim("'")
        if ($value -and $value -notmatch '^(?:file:|sqlite:)') { throw "External database variable $($match.Groups[1].Value) detected. A database-native dump is required before calling this a full backup." }
        if ($value) { throw 'SQLite connection URL detected. Confirm database/WAL paths explicitly before taking a full backup.' }
    }
}
foreach ($name in @($referencedEnvironment.Keys)) {
    if ($name -match ('^(?:' + $dbNames + ')$') -and $referencedEnvironment[$name]) { throw "Service database variable $name requires a native database backup." }
}

$totalBytes = [long]0
$certificateCount = 0
foreach ($source in $sources) {
    if (Is-Within $BackupRoot $source.Source) { throw "Backup directory must be outside source: $($source.Source)" }
    foreach ($file in @(Source-Files $source)) {
        $totalBytes += $file.Length
        if ($source.Role -match 'caddy|https' -and $file.Extension -match '^\.(pem|crt|cer|key|pfx|p12)$') { $certificateCount++ }
    }
}
if (-not $certificateCount) { throw 'No HTTPS certificate/key files were found. Supply the real TLS storage path with -CaddyDataPath or -ExtraPath first.' }
Write-Host ("Sources: {0}; approximately {1:N2} GB; certificate/key files: {2}" -f $sources.Count,($totalBytes/1GB),$certificateCount)
$sources | Select-Object Role,Source | Format-Table -AutoSize | Out-Host
if ($InspectOnly) { Write-Host 'Inspection complete. No service was stopped and no backup was written.'; return }
$driveRoot = [IO.Path]::GetPathRoot($BackupRoot)
$driveInfo = New-Object IO.DriveInfo($driveRoot)
if ($driveInfo.AvailableFreeSpace -lt ($totalBytes * 1.15 + 512MB)) { throw 'Not enough free space for the full backup and verification metadata.' }
$runRoot = Join-Path $BackupRoot ('UnionFull-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $runRoot | Out-Null
& icacls.exe $runRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot secure the backup directory; no site files were copied.' }
$metadata = Join-Path $runRoot 'metadata'
New-Item -ItemType Directory -Path $metadata | Out-Null
$wasRunning = (Get-Service -Name $AppService).Status -eq 'Running'
$pauseState = @{ Paused=$false }
$success = $false
try {
    Write-Json (Join-Path $metadata 'restore-paths.json') @($sources)
    Write-Json (Join-Path $metadata 'services.json') @($selectedServices.Values | Select-Object Name,DisplayName,StartMode,StartName,PathName,State)
    Write-Json (Join-Path $metadata 'service-environment.private.json') @{ Site=$siteResolvedEnvironment; CaddyReferenced=$referencedEnvironment }
    Write-Json (Join-Path $metadata 'runtime.json') @{ NodeVersion=(& $nodeCommand.Source --version); CaddyVersion=(& $caddyProcess.ExecutablePath version); Computer=$env:COMPUTERNAME; AppService=$AppService; WasRunning=$wasRunning; CaddyConfiguration=$configPath; CapturedUtc=[DateTime]::UtcNow.ToString('o') }
    foreach ($service in $selectedServices.Values) {
        $safeName = $service.Name -replace '[^a-zA-Z0-9_.-]','_'
        & reg.exe export ('HKLM\SYSTEM\CurrentControlSet\Services\' + $service.Name) (Join-Path $metadata ($safeName + '.reg')) /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not export service registry: $($service.Name)" }
        & sc.exe sdshow $service.Name | Set-Content -LiteralPath (Join-Path $metadata ($safeName + '-security.txt')) -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { throw "Could not read service security: $($service.Name)" }
    }
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        foreach ($task in @(Get-ScheduledTask | Where-Object { $_.TaskName -like 'Union*' -or $_.TaskName -like '*Caddy*' })) {
            $safeTask = ($task.TaskPath + $task.TaskName) -replace '[^a-zA-Z0-9_.-]','_'
            Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Set-Content -LiteralPath (Join-Path $metadata ('task-' + $safeTask + '.xml')) -Encoding UTF8
        }
    }
    if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        Get-NetFirewallRule | Where-Object { $_.DisplayName -match '(?i)Union|Caddy|tehbatri' } | Export-Clixml -LiteralPath (Join-Path $metadata 'firewall-rules.xml')
        Get-NetFirewallRule | Where-Object { $_.DisplayName -match '(?i)Union|Caddy|tehbatri' } | Get-NetFirewallPortFilter | Export-Clixml -LiteralPath (Join-Path $metadata 'firewall-ports.xml')
    }
    Write-Host 'Pausing UnionApp for the site/data copy...'
    Copy-SiteSnapshot ($sources | Where-Object Role -eq 'site' | Select-Object -First 1) $runRoot $AppService $wasRunning $pauseState
    Write-Host 'Site copy complete; copying Caddy/HTTPS and runtime files...'
    foreach ($source in @($sources | Where-Object Role -ne 'site')) {
        if ($source.Role -match 'caddy|https') {
            $before = Critical-State $source
            Copy-Source $source $runRoot
            $after = Critical-State $source
            if (-not (Same-State $before $after)) { throw 'Caddy/HTTPS files changed during copying. The backup is incomplete; rerun after certificate/config changes have settled.' }
            foreach ($relative in $before.Keys) {
                $copied = Join-Path (Join-Path $runRoot $source.BackupRelative) $relative
                if ((Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ne $before[$relative]) { throw "HTTPS/config verification failed for $($source.Role)." }
            }
        } else { Copy-Source $source $runRoot }
    }
    foreach ($source in $sources) {
        $aclName = ($source.BackupRelative -replace '^files\\','') + '.acl'
        & icacls.exe $source.Source /save (Join-Path $metadata $aclName) /t /c /q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not save source file permissions for $($source.Role). See the partial backup." }
        $source | Add-Member -NotePropertyName AclFile -NotePropertyValue ('metadata\' + $aclName)
        $source | Add-Member -NotePropertyName AclRestoreBase -NotePropertyValue (Split-Path $source.Source -Parent)
    }
    Write-Json (Join-Path $metadata 'restore-paths.json') @($sources)
    $restoreGuide = @'
RESTORE NOTES
1. This is a site/Caddy/runtime file backup, not a Windows bare-metal image or a DNS/provider account export.
2. Read metadata/restore-paths.json for every original source and its files/NN-role backup location.
3. Verify SHA256SUMS.csv before restoring. Stop only the intended site service before copying its site tree.
4. Restore the ENTIRE site, including .env, data, hidden secrets, uploads, .next and node_modules. Do not replace it with an old GitHub checkout.
5. Restore Caddy config, explicit certificate/key files, and Caddy profile/storage folders to the documented paths. Keep private-key permissions restricted.
   File DACL exports and their restore base directories are recorded in restore-paths.json. Review them before using icacls /restore on a replacement server.
6. Restore the matching Node and NSSM binaries/paths, then recreate the selected services using services.json and .reg as references. Do not import service registry blindly on a different server.
7. Passwords for Windows service accounts and Task Scheduler logon credentials are NOT recoverable from these registry/XML exports; re-enter them if custom accounts are used.
8. Process environment inherits machine/user settings. NSSM service environment, machine variables referenced with process.env.NAME in site source, and Caddy variables referenced by config are captured. Dynamically computed variable names, unlisted source folders and non-NSSM service-user profile secrets need separate review.
9. Caddy remains running while copied. Required config/TLS files were hashed before and after copying and compared with the copies. Log files may continue growing.
10. Test the restored site on an isolated server first. Check login, data counts, uploads, file downloads, HTTPS, and startup after reboot.
11. Keep another PRIVATE copy outside this server. Do not upload this backup (which contains credentials and TLS private keys) into the public app repository.
'@
    [IO.File]::WriteAllText((Join-Path $runRoot 'RESTORE.txt'),$restoreGuide,[Text.UTF8Encoding]::new($false))
    $hashes = foreach ($file in @(Tree-Files $runRoot)) {
        if ($file.FullName -in @((Join-Path $runRoot 'SHA256SUMS.csv'),(Join-Path $runRoot 'summary.json'))) { continue }
        [pscustomobject]@{ Path=$file.FullName.Substring($runRoot.Length+1); Length=$file.Length; SHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    }
    $hashes | Export-Csv -LiteralPath (Join-Path $runRoot 'SHA256SUMS.csv') -NoTypeInformation -Encoding UTF8
    Write-Json (Join-Path $runRoot 'summary.json') @{ Status='Complete'; BackupPath=$runRoot; Files=@($hashes).Count; Bytes=($hashes | Measure-Object Length -Sum).Sum; AppServiceStatus=(Get-Service -Name $AppService).Status.ToString(); CertificateKeyFilesFound=$certificateCount; CompletedUtc=[DateTime]::UtcNow.ToString('o'); Caveats=@('Not a Windows system image','No external database configured in inspected site env files or NSSM env','Custom Windows account passwords need separate recovery','Keep an off-server private copy') }
    $success=$true
    Write-Host "BACKUP COMPLETE: $runRoot" -ForegroundColor Green
    Write-Host 'Contains site data, account/session secrets and TLS PRIVATE KEYS. Keep this directory private.'
    Write-Host 'Share only summary.json to confirm the result; do not share service-environment.private.json, .env or certificate keys.'
} finally {
    if ($pauseState.Paused -and $wasRunning) {
        try { Start-Service -Name $AppService -ErrorAction Stop; (Get-Service -Name $AppService).WaitForStatus('Running',[TimeSpan]::FromSeconds(60)) }
        catch { Write-Warning "URGENT: failed to restart $AppService. Start it manually and check its service logs." }
    }
    if (-not $success) {
        Write-Json (Join-Path $runRoot 'summary.json') @{ Status='INCOMPLETE'; BackupPath=$runRoot; AppServiceStatus=(Get-Service -Name $AppService).Status.ToString() }
        Write-Warning "Backup is INCOMPLETE. Do not use it as your only recovery copy: $runRoot"
    }
}
