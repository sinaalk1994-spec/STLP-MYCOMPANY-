param(
    [string]$JavaHome,
    [string]$BuildTools,
    [string]$AndroidJar
)
$ErrorActionPreference = 'Stop'
$projectDir = $PSScriptRoot
$workspaceDir = Split-Path $projectDir -Parent
if (-not $JavaHome) {
    if ($env:JAVA_HOME) { $JavaHome = $env:JAVA_HOME }
    else { $JavaHome = Join-Path $workspaceDir 'tmp/android-build/jdk/jdk-17.0.20.1+1' }
}
if (-not $BuildTools) {
    if ($env:ANDROID_HOME) { $BuildTools = Join-Path $env:ANDROID_HOME 'build-tools/35.0.0' }
    else { $BuildTools = Join-Path $workspaceDir 'tmp/android-build/build-tools/android-15' }
}
if (-not $AndroidJar) {
    if ($env:ANDROID_HOME) { $AndroidJar = Join-Path $env:ANDROID_HOME 'platforms/android-35/android.jar' }
    else { $AndroidJar = Join-Path $workspaceDir 'tmp/android-build/platform/android-35/android.jar' }
}
foreach ($required in @((Join-Path $JavaHome 'bin/javac.exe'), (Join-Path $BuildTools 'aapt2.exe'), $AndroidJar)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing Android build prerequisite: $required" }
}
function Run-Tool([string]$tool, [string[]]$toolArgs) {
    & $tool @toolArgs
    if ($LASTEXITCODE -ne 0) { throw "$tool failed (exit $LASTEXITCODE)." }
}
$buildDir = Join-Path $projectDir 'build'
$classDir = Join-Path $buildDir 'classes'
$dexDir = Join-Path $buildDir 'dex'
$testDir = Join-Path $buildDir 'tests'
$signDir = Join-Path $projectDir '.signing'
$distDir = Join-Path $projectDir 'dist'
foreach ($dir in @($buildDir, $classDir, $dexDir, $testDir, $signDir, $distDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
$javac = Join-Path $JavaHome 'bin/javac.exe'
$java = Join-Path $JavaHome 'bin/java.exe'
$sources = @(Get-ChildItem -LiteralPath (Join-Path $projectDir 'app/src/main/java/ir/tehbatri/admin') -Filter '*.java' | ForEach-Object FullName)
Run-Tool $javac (@('-encoding', 'UTF-8', '-source', '17', '-target', '17', '-classpath', $AndroidJar, '-d', $classDir) + $sources)
Run-Tool $javac @('-encoding', 'UTF-8', '-d', $testDir, (Join-Path $projectDir 'app/src/main/java/ir/tehbatri/admin/UrlPolicy.java'), (Join-Path $projectDir 'tests/UrlPolicyTest.java'))
Run-Tool $java @('-cp', $testDir, 'ir.tehbatri.admin.UrlPolicyTest')

$resources = Join-Path $buildDir 'resources.zip'
$aapt = Join-Path $BuildTools 'aapt2.exe'
Run-Tool $aapt @('compile', '--dir', (Join-Path $projectDir 'app/src/main/res'), '-o', $resources)
# The Gradle source manifest uses namespace; direct aapt2 linking requires the package attribute.
$manifest = Get-Content -LiteralPath (Join-Path $projectDir 'app/src/main/AndroidManifest.xml') -Raw
$manifest = $manifest.Replace('<manifest ', '<manifest package="ir.tehbatri.admin" ')
$buildManifest = Join-Path $buildDir 'AndroidManifest.xml'
[IO.File]::WriteAllText($buildManifest, $manifest, [Text.UTF8Encoding]::new($false))
$unsignedApk = Join-Path $buildDir 'unsigned.apk'
Run-Tool $aapt @('link', '-o', $unsignedApk, '-I', $AndroidJar, '--manifest', $buildManifest, '--min-sdk-version', '26', '--target-sdk-version', '35', $resources)
$classesJar = Join-Path $buildDir 'classes.jar'
Run-Tool (Join-Path $JavaHome 'bin/jar.exe') @('--create', '--file', $classesJar, '-C', $classDir, '.')
Run-Tool $java @('-cp', (Join-Path $BuildTools 'lib/d8.jar'), 'com.android.tools.r8.D8', '--release', '--min-api', '26', '--lib', $AndroidJar, '--output', $dexDir, $classesJar)
# ZIP entries are added without altering the Android resource table.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($unsignedApk, [IO.Compression.ZipArchiveMode]::Update)
try {
    foreach ($dex in Get-ChildItem -LiteralPath $dexDir -Filter '*.dex') {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $dex.FullName, $dex.Name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $zip.Dispose() }
$alignedApk = Join-Path $buildDir 'aligned.apk'
Run-Tool (Join-Path $BuildTools 'zipalign.exe') @('-f', '-p', '4', $unsignedApk, $alignedApk)

$keystore = Join-Path $signDir 'tehran-volt-release.jks'
$passwordFile = Join-Path $signDir 'password.txt'
if ((Test-Path -LiteralPath $keystore) -and -not (Test-Path -LiteralPath $passwordFile)) {
    throw 'Signing password missing. Restore the signing backup; do not replace the release key.'
}
if (-not (Test-Path -LiteralPath $keystore)) {
    $random = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($random) } finally { $generator.Dispose() }
    [IO.File]::WriteAllText($passwordFile, [Convert]::ToBase64String($random), [Text.UTF8Encoding]::new($false))
    Run-Tool (Join-Path $JavaHome 'bin/keytool.exe') @('-genkeypair', '-keystore', $keystore, '-storetype', 'JKS', '-storepass:file', $passwordFile, '-keypass:file', $passwordFile, '-alias', 'tehranvolt', '-keyalg', 'RSA', '-keysize', '3072', '-validity', '10000', '-dname', 'CN=Tehran Volt, O=Tehbatri, C=IR')
}
$apk = Join-Path $distDir 'TehranVolt-1.0.0.apk'
$signer = Join-Path $BuildTools 'lib/apksigner.jar'
Run-Tool $java @('-jar', $signer, 'sign', '--ks', $keystore, '--ks-key-alias', 'tehranvolt', '--ks-pass', "file:$passwordFile", '--v4-signing-enabled', 'false', '--out', $apk, $alignedApk)
Run-Tool $java @('-jar', $signer, 'verify', '--verbose', '--print-certs', $apk)
Run-Tool (Join-Path $BuildTools 'zipalign.exe') @('-c', '-p', '4', $apk)
$hash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $distDir 'SHA256SUMS.txt'), "$hash  TehranVolt-1.0.0.apk`n", [Text.UTF8Encoding]::new($false))
Write-Host "APK ready: $apk"
