. .\01Include.ps1
. .\02Function.ps1

$tmpDir = "${PWD}\tmp\";
if (-not (Test-Path -Path $tmpDir)) {
    Write-Output "Create TMP"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
}

# Install directory defaults to current directory or .env configuration
$installDir = Path-Cleaning ${PWD} $env:INSTALL_DIR;
$phpDir = "${installDir}\PHP\";

$basePhpVersion = "v5.4, v5.5, v5.6, v7.0, v7.1, v7.2, v7.3, v7.4, v8.0, v8.1, v8.2, v8.3, v8.4, v8.5";
$whatToInstall = [string]::IsNullOrWhiteSpace($env:INSTALL_PHP_VERSION) ? $basePhpVersion : [string]$env:INSTALL_PHP_VERSION;
$whatToInstall = $whatToInstall.Replace('"', '').Replace("'", "").Split(",");

$phpSourceVersions = Get-Content .\source\php-versions.json | Out-String | ConvertFrom-Json;
$baseUrl = Get-Content .\source\baseUrl.json | Out-String | ConvertFrom-Json;
$baseUrlPie = $baseUrl.PIE;

$pie = "pie.phar";
$pieMinimumVersion = 81;
$tmpPie = Join-Path $tmpDir $pie

# Always force fresh download from upstream - never reuse existing cached tmp copy
if (Test-Path -LiteralPath $tmpPie) {
    Remove-Item -LiteralPath $tmpPie -Force -ErrorAction SilentlyContinue
    Write-Output "Purged previous cached PIE binary from tmp"
}

Write-Host ">>> Downloading latest PHP PIE from upstream ($baseUrlPie)..." -ForegroundColor Cyan
Download-File $baseUrlPie $tmpPie

$updatedCount = 0
foreach ($version in $whatToInstall) {
    $verKey = $version.Trim()
    $phpData = $phpSourceVersions.$verKey;
    if ($null -eq $phpData) { continue }

    $phpVersionDir = $phpData.alias;
    if ([int]$phpVersionDir -lt $pieMinimumVersion) {
        continue
    }

    $phpDirExtract = "${phpDir}${phpVersionDir}\";
    if (-not (Test-Path -LiteralPath $phpDirExtract)) {
        continue
    }

    Copy-Item $tmpPie "${phpDirExtract}\pie.phar" -Force;
    
    $pieInstallVer = "${phpDirExtract}\pie${phpVersionDir}.bat";
    Copy-Item .\source\pie.bat $pieInstallVer -Force;

    $pieInstall = "${phpDirExtract}\pie.bat";
    Copy-Item .\source\pie.bat $pieInstall -Force;

    Write-Host "  -> Updated PIE in PHP ${phpVersionDir}" -ForegroundColor Green
    $updatedCount++
}

Write-Host ""
Write-Host ">>> Refreshing PHP, Composer & PIE CLI links in bin..." -ForegroundColor Cyan
Deploy-PhpBinLinks -PhpDir $phpDir
Write-Host ">>> Done! Successfully updated PIE across $updatedCount PHP version(s)." -ForegroundColor Green
