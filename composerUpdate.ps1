. .\01Include.ps1
. .\02Function.ps1

$tmpDir = "${PWD}\tmp\";
if (-not(Test-Path -Path $tmpDir)) {
    Write-Output("Create TMP");
    mkdir $tmpDir
}

# install default to current dir
$installDir = Path-Cleaning ${PWD} $env:INSTALL_DIR;

$phpDir = "${installDir}\PHP\";

$basePhpVersion = "v5.4, v5.5, v5.6, v7.0, v7.1, v7.2, v7.3, v7.4, v8.0, v8.1, v8.2, v8.3";
$whatToInstall = [string]::IsNullOrWhiteSpace($env:INSTALL_PHP_VERSION) ? $basePhpVersion : [string]$env:INSTALL_PHP_VERSION;
$whatToInstall = $whatToInstall.Replace('"', '').Replace("'", "").Split(",");

$phpSourceVersions = Get-Content .\source\php-versions.json | Out-String | ConvertFrom-Json;
$baseUrl = Get-Content .\source\baseUrl.json | Out-String | ConvertFrom-Json;
$baseUrlComposer = $baseUrl.COMPOSER;
$baseUrlComposerLts = $baseUrl.COMPOSER_LTS;

$composer = "composer.phar";
$composerLts = "composer-lts.phar";
$composerMinimumVersion = 72;

$tmpComposer = "${tmpDir}${composer}";
$tmpComposerLts = "${tmpDir}${composerLts}";

Download-File $baseUrlComposer $tmpComposer;
Download-File $baseUrlComposerLts $tmpComposerLts;

foreach ($version in $whatToInstall) {
    $phpData = $phpSourceVersions.$version;

    # Extract PHP
    $phpInstallDir = $phpDir;
    $phpVersionDir = $phpData.alias;
    $phpDirExtract = "${phpInstallDir}${phpVersionDir}\";

    $composerTmpInstalled = [int]$phpVersionDir -ge $composerMinimumVersion ? $tmpComposer : $tmpComposerLts;
    Copy-Item $composerTmpInstalled "${phpDirExtract}\composer.phar";
    
    $composerInstallVer = "${phpDirExtract}\composer${phpVersionDir}.bat";
    Copy-Item .\source\composer.bat $composerInstallVer;

    $composerInstall = "${phpDirExtract}\composer.bat";
    Copy-Item .\source\composer.bat $composerInstall;
}