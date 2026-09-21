#Requires -Version 5.1
<#
.SYNOPSIS
    Automated installer and configurator for PHP, Apache, Nginx, Composer, Xdebug, and Imagick on Windows.

.DESCRIPTION
    Orchestrates the download, extraction, configuration, and path registration of multiple PHP versions
    alongside Apache HTTPD and/or Nginx web servers. Configuration is primarily loaded from .env and source JSON
    manifests, with optional command-line parameter overrides.

.EXAMPLE
    pwsh -NoProfile .\install.ps1

.EXAMPLE
    pwsh -NoProfile .\install.ps1 -PhpVersions "v8.2, v8.5" -InstallApache:$false
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PhpVersions,
    [string]$InstallDir,
    [string]$HtdocsDir,
    [string]$BuildType,
    [string]$ApacheBase,
    [string]$NginxBase,
    [Nullable[bool]]$InstallVCRedist,
    [Nullable[bool]]$DownloadPhp,
    [Nullable[bool]]$InstallXdebug,
    [Nullable[bool]]$InstallImagick,
    [Nullable[bool]]$InstallComposer,
    [Nullable[bool]]$InstallApache,
    [Nullable[bool]]$DownloadApache,
    [Nullable[bool]]$InstallNginx,
    [Nullable[bool]]$DownloadNginx,
    [Nullable[bool]]$RegisterPhpPath,
    [Nullable[bool]]$RegisterApachePath,
    [Nullable[bool]]$RegisterNginxPath,
    [Nullable[bool]]$CleanTmpDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- 1. Dependencies & Helpers ---

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = (Get-Location).Path
}

. (Join-Path $ScriptRoot "01Include.ps1")
. (Join-Path $ScriptRoot "02Function.ps1")

function Resolve-AppPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseDir,
        [string]$InputPath,
        [string]$DefaultPath
    )

    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        return $DefaultPath
    }

    $trimmed = $InputPath.Replace('/', '\').Trim()
    if ($trimmed -eq '.' -or $trimmed -eq '.\') {
        return $BaseDir
    }

    if ([System.IO.Path]::IsPathRooted($trimmed)) {
        return [System.IO.Path]::GetFullPath($trimmed)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $trimmed))
}

function Get-ObjectProperty {
    [CmdletBinding()]
    param(
        $Object,
        [string]$PropertyName
    )

    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function Get-InstallerConfig {
    [CmdletBinding()]
    param(
        [hashtable]$CliParams,
        [string]$RootDirectory,
        [PSCustomObject]$Manifests = $null
    )

    function Resolve-BooleanOption {
        param([string]$ParamName, [string]$EnvVarName, [bool]$Default = $false)
        if ($CliParams.ContainsKey($ParamName) -and $null -ne $CliParams[$ParamName]) {
            return [bool]$CliParams[$ParamName]
        }
        $envVal = [System.Environment]::GetEnvironmentVariable($EnvVarName)
        return Get-BoolFromEnv $envVal $Default
    }

    function Resolve-StringOption {
        param([string]$ParamName, [string]$EnvVarName, [string]$Default = '')
        if ($CliParams.ContainsKey($ParamName) -and -not [string]::IsNullOrWhiteSpace($CliParams[$ParamName])) {
            return [string]$CliParams[$ParamName]
        }
        $envVal = [System.Environment]::GetEnvironmentVariable($EnvVarName)
        if (-not [string]::IsNullOrWhiteSpace($envVal)) {
            return $envVal
        }
        return $Default
    }

    $flags = [PSCustomObject]@{
        InstallVCRedist    = Resolve-BooleanOption 'InstallVCRedist'    'INSTALL_VCREDIST'    $true
        DownloadPhp        = Resolve-BooleanOption 'DownloadPhp'        'DOWNLOAD_PHP'        $true
        InstallXdebug      = Resolve-BooleanOption 'InstallXdebug'      'INSTALL_XDEBUG'      $true
        InstallImagick     = Resolve-BooleanOption 'InstallImagick'     'INSTALL_IMAGICK'     $true
        RegisterPhpPath    = Resolve-BooleanOption 'RegisterPhpPath'    'REGISTER_PATH_PHP'   $false
        InstallComposer    = Resolve-BooleanOption 'InstallComposer'    'INSTALL_COMPOSER'    $true
        InstallApache      = Resolve-BooleanOption 'InstallApache'      'INSTALL_APACHE'      $true
        DownloadApache     = Resolve-BooleanOption 'DownloadApache'     'DOWNLOAD_APACHE'     $true
        RegisterApachePath = Resolve-BooleanOption 'RegisterApachePath' 'REGISTER_PATH_APACHE' $false
        InstallNginx       = Resolve-BooleanOption 'InstallNginx'       'INSTALL_NGINX'       $false
        DownloadNginx      = Resolve-BooleanOption 'DownloadNginx'      'DOWNLOAD_NGINX'      $false
        RegisterNginxPath  = Resolve-BooleanOption 'RegisterNginxPath'  'REGISTER_PATH_NGINX'  $false
        CleanTmpDir        = Resolve-BooleanOption 'CleanTmpDir'        'CLEAN_TMP_DIR'       $false
    }

    $rawInstallDir = Resolve-StringOption 'InstallDir' 'INSTALL_DIR' $RootDirectory
    $installRoot = Resolve-AppPath -BaseDir $RootDirectory -InputPath $rawInstallDir -DefaultPath $RootDirectory

    $apacheDir = Join-Path $installRoot "apache"
    $nginxDir = Join-Path $installRoot "nginx"
    $phpDir = Join-Path $installRoot "PHP"

    $rawHtdocs = Resolve-StringOption 'HtdocsDir' 'HTDOCS_DIR' ''
    $defaultHtdocs = Join-Path $apacheDir "htdocs"
    $htdocsDir = Resolve-AppPath -BaseDir $installRoot -InputPath $rawHtdocs -DefaultPath $defaultHtdocs

    $defaultPhpVersions = "v5.4, v5.5, v5.6, v7.0, v7.1, v7.2, v7.3, v7.4, v8.0, v8.1, v8.2, v8.3, v8.4, v8.5"
    $rawVersions = Resolve-StringOption 'PhpVersions' 'INSTALL_PHP_VERSION' $defaultPhpVersions
    $versionList = @(
        $rawVersions.Replace('"', '').Replace("'", "").Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $buildType = Resolve-StringOption 'BuildType' 'PHP_BUILD_TYPE' 'NTS'

    $manifestApacheBase = if ($Manifests -and (Get-ObjectProperty $Manifests.BaseUrl "APACHE_BASE")) {
        Get-ObjectProperty $Manifests.BaseUrl "APACHE_BASE"
    } else {
        "httpd-2.4.68-260920-Win64-VS18.zip"
    }

    $manifestNginxBase = if ($Manifests -and (Get-ObjectProperty $Manifests.BaseUrl "NGINX_BASE")) {
        Get-ObjectProperty $Manifests.BaseUrl "NGINX_BASE"
    } else {
        "nginx-1.28.0.zip"
    }

    # ApacheBase and NginxBase are now configured via source/baseUrl.json (or overridden explicitly via CLI parameter)
    $apacheBase = if ($CliParams.ContainsKey('ApacheBase') -and -not [string]::IsNullOrWhiteSpace($CliParams['ApacheBase'])) {
        [string]$CliParams['ApacheBase']
    } else {
        $manifestApacheBase
    }

    $nginxBase = if ($CliParams.ContainsKey('NginxBase') -and -not [string]::IsNullOrWhiteSpace($CliParams['NginxBase'])) {
        [string]$CliParams['NginxBase']
    } else {
        $manifestNginxBase
    }

    $tmpDir = Join-Path $RootDirectory "tmp"
    if (-not (Test-Path -LiteralPath $tmpDir)) {
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        Write-Output "Created TMP directory: $tmpDir"
    }

    return [PSCustomObject]@{
        Flags        = $flags
        InstallDir   = $installRoot
        ApacheDir    = $apacheDir
        NginxDir     = $nginxDir
        PhpDir       = $phpDir
        HtdocsDir    = $htdocsDir
        TmpDir       = $tmpDir
        Versions     = $versionList
        BuildType    = $buildType
        ApacheBase   = $apacheBase
        NginxBase    = $nginxBase
        PathEnvName  = "WEBSERV"
    }
}

function Get-SourceManifests {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourceDir)

    function Load-JsonFile([string]$FileName) {
        $filePath = Join-Path $SourceDir $FileName
        if (-not (Test-Path -LiteralPath $filePath)) {
            throw "Required manifest file not found: $filePath"
        }
        return Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json
    }

    return [PSCustomObject]@{
        BaseUrl     = Load-JsonFile "baseUrl.json"
        PhpVersions = Load-JsonFile "php-versions.json"
        Extensions  = Load-JsonFile "php-config-extension.json"
        BaseConfig  = Load-JsonFile "php-config-base.json"
        Xdebug      = Load-JsonFile "php-config-xdebug.json"
        Imagick     = Load-JsonFile "php-config-imagick.json"
    }
}

function Save-PackageFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$TargetDir,
        [Parameter(Mandatory = $true)][string]$FileName,
        [bool]$ForceDownload = $false
    )

    $targetPath = Join-Path $TargetDir $FileName
    if ($ForceDownload) {
        Write-Output "Downloading $FileName to $TargetDir"
        Download-File $Url $targetPath
    }
    else {
        Check-Download $Url $TargetDir $FileName
    }

    if (-not (Test-Path -LiteralPath $targetPath)) {
        throw "Failed to obtain file: $targetPath"
    }

    # Validate zip integrity if the downloaded file is an archive
    if ($FileName.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase)) {
        try {
            $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($targetPath)
            $null = $zipArchive.Entries
            $zipArchive.Dispose()
        }
        catch {
            Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
            throw "Downloaded file $FileName is not a valid zip archive (server may have returned an HTML error page or corrupted content): $Url"
        }
    }
}

function Show-InstallerBanner {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    Write-Output "=== php-apache-installer configuration ==="
    Write-Output "Install root: $($Config.InstallDir)"
    Write-Output "Apache install path: $($Config.ApacheDir)"
    Write-Output "Nginx install path: $($Config.NginxDir)"
    Write-Output "PHP install path: $($Config.PhpDir)"
    Write-Output "PHP versions: $($Config.Versions -join ', ')"
    Write-Output "Download PHP packages: $($Config.Flags.DownloadPhp)"
    Write-Output "Install Xdebug: $($Config.Flags.InstallXdebug)"
    Write-Output "Install Imagick: $($Config.Flags.InstallImagick)"
    Write-Output "Install Composer: $($Config.Flags.InstallComposer)"
    Write-Output "Install Apache: $($Config.Flags.InstallApache)"
    Write-Output "Download Apache packages: $($Config.Flags.DownloadApache)"
    Write-Output "Register Apache path: $($Config.Flags.RegisterApachePath)"
    Write-Output "Install Nginx: $($Config.Flags.InstallNginx)"
    Write-Output "Download Nginx packages: $($Config.Flags.DownloadNginx)"
    Write-Output "Register Nginx path: $($Config.Flags.RegisterNginxPath)"
    Write-Output "Register PHP path: $($Config.Flags.RegisterPhpPath)"
    Write-Output "Install VC Redist: $($Config.Flags.InstallVCRedist)"
    Write-Output "Clean temp directory after run: $($Config.Flags.CleanTmpDir)"
    Write-Output "=== start installation ==="
}

# --- 2. Phase Implementations ---

function Invoke-VCRedistInstall {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        Write-Warning "VC Redist manifest not found at: $ManifestPath"
        return
    }

    Write-Output "Installing all VCRedist packages"
    if ($PSCmdlet.ShouldProcess("Visual C++ Redistributables", "Install via winget")) {
        winget import -i $ManifestPath --accept-package-agreements --accept-source-agreements --disable-interactivity
    }
}

function Download-InstallerPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$Config,
        [Parameter(Mandatory = $true)][PSCustomObject]$Manifests
    )

    $baseUrl = $Manifests.BaseUrl
    $tmpDir = $Config.TmpDir

    # Download Composer packages if enabled
    if ($Config.Flags.InstallComposer) {
        Save-PackageFile -Url $baseUrl.COMPOSER -TargetDir $tmpDir -FileName "composer.phar" -ForceDownload $false
        Save-PackageFile -Url $baseUrl.COMPOSER_LTS -TargetDir $tmpDir -FileName "composer-lts.phar" -ForceDownload $false
    }

    # Download PHP and extension packages
    foreach ($version in $Config.Versions) {
        $phpData = Get-ObjectProperty $Manifests.PhpVersions $version
        if ($null -eq $phpData) {
            Write-Warning "Version '$version' not found in php-versions.json manifest; skipping."
            continue
        }

        # Resolve PHP package properties
        $phpName     = Get-ObjectProperty $phpData "name"
        $phpDownload = Get-ObjectProperty $phpData "download"
        $phpBaseFile = if ($Config.BuildType -eq "NTS") { $phpName } else { $phpName.Replace("-nts", "") }
        $phpUrl = if ($phpDownload -eq "release") {
            "$($baseUrl.PHP_RELEASE)$phpBaseFile"
        } else {
            "$($baseUrl.PHP)$phpBaseFile"
        }

        try {
            Save-PackageFile -Url $phpUrl -TargetDir $tmpDir -FileName $phpBaseFile -ForceDownload $Config.Flags.DownloadPhp
        }
        catch {
            Write-Error "Failed to download PHP $version`: $_"
            throw "Installation halted due to failed PHP download: $version"
        }

        # Download Xdebug if enabled
        $xdebugProp = Get-ObjectProperty $phpData "xdebug"
        if ($Config.Flags.InstallXdebug -and -not [string]::IsNullOrWhiteSpace($xdebugProp)) {
            $xdebugFile = if ($Config.BuildType -eq "NTS") { $xdebugProp } else { $xdebugProp.Replace("-nts", "") }
            $xdebugUrl = "$($baseUrl.XDEBUG)$xdebugFile"
            try {
                Save-PackageFile -Url $xdebugUrl -TargetDir $tmpDir -FileName $xdebugFile -ForceDownload $false
            }
            catch {
                Write-Error "Failed to download Xdebug $xdebugFile`: $_"
                throw "Installation halted due to failed Xdebug download."
            }
        }

        # Download Imagick if enabled
        $imagickProp = Get-ObjectProperty $phpData "imagick"
        if ($Config.Flags.InstallImagick -and -not [string]::IsNullOrWhiteSpace($imagickProp)) {
            $imagickFile = if ($Config.BuildType -eq "NTS") { $imagickProp } else { $imagickProp.Replace("-nts", "") }
            if ($imagickFile -match '^php_imagick-([^-]+)-') {
                $imagickVer = $Matches[1]
                $imagickUrl = "$($baseUrl.IMAGICK)$imagickVer/$imagickFile"
                try {
                    Save-PackageFile -Url $imagickUrl -TargetDir $tmpDir -FileName $imagickFile -ForceDownload $false
                }
                catch {
                    Write-Error "Failed to download Imagick $imagickFile`: $_"
                    throw "Installation halted due to failed Imagick download."
                }
            }
        }
    }

    # Download Apache packages if enabled
    if ($Config.Flags.InstallApache) {
        $apacheFileName = $Config.ApacheBase
        $apacheUrl = "$($baseUrl.APACHE)/$apacheFileName"
        Save-PackageFile -Url $apacheUrl -TargetDir $tmpDir -FileName $apacheFileName -ForceDownload $Config.Flags.DownloadApache

        $fcgiUrl = $baseUrl.APACHE_FCGI
        $fcgiFileName = [System.IO.Path]::GetFileName($fcgiUrl)
        Save-PackageFile -Url $fcgiUrl -TargetDir $tmpDir -FileName $fcgiFileName -ForceDownload $Config.Flags.DownloadApache
    }

    # Download Nginx package if enabled
    if ($Config.Flags.InstallNginx) {
        $nginxBaseFile = $Config.NginxBase
        $nginxUrl = if ($baseUrl.NGINX -match 'github\.com/nginx/nginx/releases/download') {
            $tag = if ($nginxBaseFile -match '^nginx-(\d+\.\d+\.\d+)\.zip$') { "release-$($Matches[1])" } else { "release-1.30.5" }
            "$($baseUrl.NGINX.TrimEnd('/'))/$tag/$nginxBaseFile"
        } else {
            "$($baseUrl.NGINX.TrimEnd('/'))/$nginxBaseFile"
        }

        try {
            Save-PackageFile -Url $nginxUrl -TargetDir $tmpDir -FileName $nginxBaseFile -ForceDownload $Config.Flags.DownloadNginx
        }
        catch {
            Write-Error "Failed to download Nginx $nginxBaseFile`: $_"
            throw "Installation halted due to failed Nginx download: $nginxBaseFile"
        }
    }
}

function Configure-PhpIni {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IniTemplatePath,
        [Parameter(Mandatory = $true)][string]$DestinationIniPath,
        [Parameter(Mandatory = $true)][string]$PhpInstallDir,
        [Parameter(Mandatory = $true)][string]$VersionAlias,
        [Parameter(Mandatory = $true)][string]$ConfigType,
        [Parameter(Mandatory = $true)][PSCustomObject]$Manifests,
        [bool]$EnableXdebug = $false,
        [string]$XdebugDllPath = "",
        [bool]$EnableImagick = $false
    )

    if (-not (Test-Path -LiteralPath $IniTemplatePath)) {
        throw "Base php.ini template not found at: $IniTemplatePath"
    }

    $content = Get-Content -LiteralPath $IniTemplatePath -Raw

    # 1. Enable configured extensions in memory
    $extensions = Get-ObjectProperty $Manifests.Extensions $ConfigType
    if ($extensions) {
        foreach ($ext in $extensions) {
            $escaped = [regex]::Escape($ext)
            $content = [regex]::Replace($content, ";\s*$escaped", $ext)
        }
    }

    # 2. Append base configuration directives
    $phpForwardDir = $PhpInstallDir.Replace('\', '/')
    if (-not $phpForwardDir.EndsWith('/')) {
        $phpForwardDir += '/'
    }

    $baseDirectives = @($Manifests.BaseConfig.base)
    if ($baseDirectives.Count -gt 0) {
        $baseBlock = ($baseDirectives -join "`r`n").Replace('{PHP_INSTALL_DIR}', $phpForwardDir).Replace('{VERSION}', $VersionAlias)
        $content += "`r`n" + $baseBlock
    }

    # 3. Append Xdebug directives if enabled
    $xdebugDirectives = Get-ObjectProperty $Manifests.Xdebug $ConfigType
    if ($EnableXdebug -and $xdebugDirectives) {
        $xdebugBlock = ($xdebugDirectives -join "`r`n").Replace('php_xdebug.dll', $XdebugDllPath)
        $content += "`r`n" + $xdebugBlock
    }

    # 4. Append Imagick directives if enabled
    $imagickDirectives = Get-ObjectProperty $Manifests.Imagick $ConfigType
    if ($EnableImagick -and $imagickDirectives) {
        $imagickBlock = $imagickDirectives -join "`r`n"
        $content += "`r`n" + $imagickBlock
    }

    # Single write to disk
    Set-Content -LiteralPath $DestinationIniPath -Value $content -Encoding UTF8
}

function Install-PhpVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][PSCustomObject]$Config,
        [Parameter(Mandatory = $true)][PSCustomObject]$Manifests,
        [Parameter(Mandatory = $true)][string]$SourceDir
    )

    $phpData = Get-ObjectProperty $Manifests.PhpVersions $Version
    if ($null -eq $phpData) {
        Write-Warning "PHP version '$Version' configuration missing; skipping installation."
        return $null
    }

    $phpName      = Get-ObjectProperty $phpData "name"
    $versionAlias = Get-ObjectProperty $phpData "alias"
    $configType   = Get-ObjectProperty $phpData "config"
    $phpBaseFile  = if ($Config.BuildType -eq "NTS") { $phpName } else { $phpName.Replace("-nts", "") }
    $phpExtractDir = Join-Path $Config.PhpDir $versionAlias

    # Clean previous extraction directory
    if (Test-Path -LiteralPath $phpExtractDir) {
        Remove-Item -LiteralPath $phpExtractDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $phpExtractDir | Out-Null

    # Ensure shared PHP tmp directory exists
    $phpTmpDir = Join-Path $Config.PhpDir "tmp"
    if (-not (Test-Path -LiteralPath $phpTmpDir)) {
        New-Item -ItemType Directory -Path $phpTmpDir | Out-Null
    }

    # Extract PHP archive
    $zipPath = Join-Path $Config.TmpDir $phpBaseFile
    Write-Output "Extracting $phpBaseFile to $phpExtractDir"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $phpExtractDir

    # Determine Xdebug path if enabled
    $xdebugExtPath = Join-Path $phpExtractDir "ext\php_xdebug.dll"
    $xdebugProp = Get-ObjectProperty $phpData "xdebug"
    if ($Config.Flags.InstallXdebug -and -not [string]::IsNullOrWhiteSpace($xdebugProp)) {
        $xdebugFileName = if ($Config.BuildType -eq "NTS") { $xdebugProp } else { $xdebugProp.Replace("-nts", "") }
        $sourceXdebug = Join-Path $Config.TmpDir $xdebugFileName
        if (Test-Path -LiteralPath $sourceXdebug) {
            Copy-Item -LiteralPath $sourceXdebug -Destination $xdebugExtPath -Force
        }
    }

    # Extract and copy Imagick DLLs if enabled
    $imagickProp = Get-ObjectProperty $phpData "imagick"
    $hasImagick = $Config.Flags.InstallImagick -and -not [string]::IsNullOrWhiteSpace($imagickProp)
    if ($hasImagick) {
        $imagickFileName = if ($Config.BuildType -eq "NTS") { $imagickProp } else { $imagickProp.Replace("-nts", "") }
        $imagickZip = Join-Path $Config.TmpDir $imagickFileName

        if (Test-Path -LiteralPath $imagickZip) {
            $imagickTmp = Join-Path $Config.TmpDir "imagick_$versionAlias"
            if (Test-Path -LiteralPath $imagickTmp) { Remove-Item -LiteralPath $imagickTmp -Recurse -Force }
            New-Item -ItemType Directory -Path $imagickTmp | Out-Null

            Expand-Archive -LiteralPath $imagickZip -DestinationPath $imagickTmp

            # Copy php_imagick.dll to ext/
            $extDll = Join-Path $imagickTmp "php_imagick.dll"
            if (Test-Path -LiteralPath $extDll) {
                Copy-Item -LiteralPath $extDll -Destination (Join-Path $phpExtractDir "ext\php_imagick.dll") -Force
            }

            # Copy dependency DLLs (CORE_RL_*.dll, etc.) to PHP root folder
            Get-ChildItem -LiteralPath $imagickTmp -Filter "*.dll" | Where-Object { $_.Name -ne "php_imagick.dll" } | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $phpExtractDir $_.Name) -Force
            }

            Remove-Item -LiteralPath $imagickTmp -Recurse -Force
        }
    }

    # Configure php.ini
    $iniTemplate = Join-Path $phpExtractDir "php.ini-development"
    $targetIni = Join-Path $phpExtractDir "php.ini"
    Configure-PhpIni `
        -IniTemplatePath $iniTemplate `
        -DestinationIniPath $targetIni `
        -PhpInstallDir $Config.PhpDir `
        -VersionAlias $versionAlias `
        -ConfigType $configType `
        -Manifests $Manifests `
        -EnableXdebug $Config.Flags.InstallXdebug `
        -XdebugDllPath $xdebugExtPath `
        -EnableImagick $hasImagick

    # Generate versioned binary aliases
    Copy-Item -LiteralPath (Join-Path $phpExtractDir "php.exe") -Destination (Join-Path $phpExtractDir "php${versionAlias}.exe") -Force
    Copy-Item -LiteralPath (Join-Path $phpExtractDir "php-cgi.exe") -Destination (Join-Path $phpExtractDir "php${versionAlias}-cgi.exe") -Force

    # Configure Composer if enabled
    if ($Config.Flags.InstallComposer) {
        $composerMinVer = 72
        $composerSource = if ([int]$versionAlias -ge $composerMinVer) {
            Join-Path $Config.TmpDir "composer.phar"
        } else {
            Join-Path $Config.TmpDir "composer-lts.phar"
        }

        if (Test-Path -LiteralPath $composerSource) {
            Copy-Item -LiteralPath $composerSource -Destination (Join-Path $phpExtractDir "composer.phar") -Force
        }

        $composerBatTemplate = Join-Path $SourceDir "composer.bat"
        if (Test-Path -LiteralPath $composerBatTemplate) {
            Copy-Item -LiteralPath $composerBatTemplate -Destination (Join-Path $phpExtractDir "composer.bat") -Force
            Copy-Item -LiteralPath $composerBatTemplate -Destination (Join-Path $phpExtractDir "composer${versionAlias}.bat") -Force
        }
    }

    return $phpExtractDir
}

function Install-ApacheServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$Config,
        [Parameter(Mandatory = $true)][PSCustomObject]$Manifests,
        [Parameter(Mandatory = $true)][string]$SourceDir
    )

    $apacheDir = $Config.ApacheDir
    Write-Output "Install Apache ${apacheDir}"

    if (Test-Path -LiteralPath $apacheDir) {
        Remove-Item -LiteralPath $apacheDir -Recurse -Force
    }

    $apacheFileName = $Config.ApacheBase
    $tmpApacheZip = Join-Path $Config.TmpDir $apacheFileName

    $fcgiUrl = $Manifests.BaseUrl.APACHE_FCGI
    $fcgiFileName = [System.IO.Path]::GetFileName($fcgiUrl)
    $tmpFcgiZip = Join-Path $Config.TmpDir $fcgiFileName

    if (-not (Test-Path -LiteralPath $tmpApacheZip) -and (Test-Path -LiteralPath (Join-Path $Config.TmpDir "APACHE.zip"))) {
        $tmpApacheZip = Join-Path $Config.TmpDir "APACHE.zip"
    }
    if (-not (Test-Path -LiteralPath $tmpFcgiZip) -and (Test-Path -LiteralPath (Join-Path $Config.TmpDir "APACHE_FCGI.zip"))) {
        $tmpFcgiZip = Join-Path $Config.TmpDir "APACHE_FCGI.zip"
    }

    # Extract Apache
    $tmpApacheDir = Join-Path $Config.TmpDir "APACHE"
    if (Test-Path -LiteralPath $tmpApacheDir) { Remove-Item -LiteralPath $tmpApacheDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpApacheDir | Out-Null
    Expand-Archive -LiteralPath $tmpApacheZip -DestinationPath $tmpApacheDir

    $subDir = Get-ChildItem -LiteralPath $tmpApacheDir -Directory | Select-Object -First 1 -ExpandProperty Name
    Move-Item -LiteralPath (Join-Path $tmpApacheDir $subDir) -Destination $apacheDir

    # Extract mod_fcgid
    $tmpFcgiDir = Join-Path $Config.TmpDir "APACHE_FCGI"
    if (Test-Path -LiteralPath $tmpFcgiDir) { Remove-Item -LiteralPath $tmpFcgiDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpFcgiDir | Out-Null
    Expand-Archive -LiteralPath $tmpFcgiZip -DestinationPath $tmpFcgiDir

    $fcgiModule = Join-Path $tmpFcgiDir "mod_fcgid.so"
    if (Test-Path -LiteralPath $fcgiModule) {
        Move-Item -LiteralPath $fcgiModule -Destination (Join-Path $apacheDir "modules\mod_fcgid.so") -Force
    }

    # Configure httpd.conf
    $httpdConf = Join-Path $apacheDir "conf\httpd.conf"
    if (Test-Path -LiteralPath $httpdConf) {
        Move-Item -LiteralPath $httpdConf -Destination "$httpdConf.tmp" -Force
    }
    Copy-Item -LiteralPath (Join-Path $SourceDir "apache\httpd.conf") -Destination $httpdConf

    $apacheForward = $apacheDir.Replace('\', '/')
    $listenDirectives = $Config.Versions | ForEach-Object {
        $v = $_.Trim()
        $vData = Get-ObjectProperty $Manifests.PhpVersions $v
        $alias = if ($vData) { $vData.alias } else { "" }
        "Listen 80$alias"
    }

    $confContent = Get-Content -LiteralPath $httpdConf -Raw
    $confContent = $confContent.Replace('{{ROOT}}', $apacheForward)
    $confContent = $confContent.Replace('{{LISTEN_PORT}}', ($listenDirectives -join "`n"))
    Set-Content -LiteralPath $httpdConf -Value $confContent -Encoding UTF8

    # Configure httpd-vhosts.conf
    $vhostConf = Join-Path $apacheDir "conf\extra\httpd-vhosts.conf"
    if (Test-Path -LiteralPath $vhostConf) {
        Move-Item -LiteralPath $vhostConf -Destination "$vhostConf.tmp" -Force
    }
    Copy-Item -LiteralPath (Join-Path $SourceDir "apache\httpd-vhosts.conf") -Destination $vhostConf

    $htdocsForward = $Config.HtdocsDir.Replace('\', '/')
    $phpForward = $Config.PhpDir.Replace('\', '/')

    $vhostContent = Get-Content -LiteralPath $vhostConf -Raw
    $vhostContent = $vhostContent.Replace('{{HTDOCS}}', $htdocsForward)
    $vhostContent = $vhostContent.Replace('{{PHP}}', $phpForward)
    Set-Content -LiteralPath $vhostConf -Value $vhostContent -Encoding UTF8

    # Copy virtual host extra configurations
    $hostConfDir = Join-Path $apacheDir "conf\extra\host"
    New-Item -ItemType Directory -Path $hostConfDir -Force | Out-Null
    Copy-Item -Path (Join-Path $SourceDir "apache\host\*") -Destination $hostConfDir -Recurse -Force

    # Copy utility scripts
    $binDir = Join-Path $apacheDir "bin"
    Copy-Item -LiteralPath (Join-Path $SourceDir "apache\apacheRegister.ps1") -Destination (Join-Path $binDir "apacheRegister.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $SourceDir "apache\apacheUnistall.ps1") -Destination (Join-Path $binDir "apacheUnistall.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $SourceDir "apache\apacheTest.ps1") -Destination (Join-Path $binDir "apacheTest.ps1") -Force

    return $binDir
}

function Install-NginxServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$Config,
        [Parameter(Mandatory = $true)][string]$SourceDir
    )

    $nginxDir = $Config.NginxDir
    Write-Output "Install Nginx ${nginxDir}"

    if (Test-Path -LiteralPath $nginxDir) {
        Remove-Item -LiteralPath $nginxDir -Recurse -Force
    }

    $tmpNginxZip = Join-Path $Config.TmpDir $Config.NginxBase

    # Extract Nginx
    $tmpNginxDir = Join-Path $Config.TmpDir "NGINX"
    if (Test-Path -LiteralPath $tmpNginxDir) { Remove-Item -LiteralPath $tmpNginxDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpNginxDir | Out-Null
    Expand-Archive -LiteralPath $tmpNginxZip -DestinationPath $tmpNginxDir

    $subDir = Get-ChildItem -LiteralPath $tmpNginxDir -Directory | Select-Object -First 1 -ExpandProperty Name
    Move-Item -LiteralPath (Join-Path $tmpNginxDir $subDir) -Destination $nginxDir

    # Configure nginx.conf
    $conf = Join-Path $nginxDir "conf\nginx.conf"
    if (Test-Path -LiteralPath $conf) {
        Move-Item -LiteralPath $conf -Destination "$conf.tmp" -Force
    }
    Copy-Item -LiteralPath (Join-Path $SourceDir "nginx\nginx.conf") -Destination $conf

    $htdocsForward = $Config.HtdocsDir.Replace('\', '/')
    $confContent = Get-Content -LiteralPath $conf -Raw
    $confContent = $confContent.Replace('{{HTDOCS}}', $htdocsForward)
    Set-Content -LiteralPath $conf -Value $confContent -Encoding UTF8

    # Copy server block configurations
    $hostConfDir = Join-Path $nginxDir "conf\server"
    New-Item -ItemType Directory -Path $hostConfDir -Force | Out-Null
    Copy-Item -Path (Join-Path $SourceDir "nginx\server\*") -Destination $hostConfDir -Recurse -Force

    # Configure launcher batch script
    $runner = Join-Path $nginxDir "webserver_nginx.bat"
    Copy-Item -LiteralPath (Join-Path $SourceDir "nginx\webserver_nginx.bat") -Destination $runner -Force

    $runnerContent = Get-Content -LiteralPath $runner -Raw
    $runnerContent = $runnerContent.Replace('{{ROOT}}', $nginxDir)
    $runnerContent = $runnerContent.Replace('{{PHP_DIR}}', $Config.PhpDir)
    Set-Content -LiteralPath $runner -Value $runnerContent -Encoding UTF8

    return $nginxDir
}

function Register-EnvironmentPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PathName,
        [Parameter(Mandatory = $true)][string[]]$PathsToRegister
    )

    $validPaths = @($PathsToRegister | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($validPaths.Count -gt 0) {
        $combined = $validPaths -join ";"
        Write-Output "Registering environment paths to %$PathName%: $combined"
        Register-Path-Web $PathName $combined
    }
}

function Clear-TemporaryFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TmpDir)

    if (Test-Path -LiteralPath $TmpDir) {
        Write-Output "Cleaning temporary directory: $TmpDir"
        Remove-Item -LiteralPath $TmpDir -Recurse -Force
    }
}

# --- 3. Main Orchestrator ---

function Invoke-Installer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [hashtable]$BoundParameters,
        [string]$RootDirectory
    )

    $sourceDir = Join-Path $RootDirectory "source"
    $manifests = Get-SourceManifests -SourceDir $sourceDir
    $config = Get-InstallerConfig -CliParams $BoundParameters -RootDirectory $RootDirectory -Manifests $manifests

    Show-InstallerBanner -Config $config

    # Step 1: Optional Visual C++ Redistributables
    if ($config.Flags.InstallVCRedist) {
        $vcManifest = Join-Path $sourceDir "winget-VCRedist.json"
        Invoke-VCRedistInstall -ManifestPath $vcManifest
    }

    # Step 2: Download or verify all required packages upfront (fail-fast)
    Download-InstallerPackages -Config $config -Manifests $manifests

    # Step 3: Install and configure each PHP version
    $pathsToRegister = @()
    foreach ($ver in $config.Versions) {
        $installedPath = Install-PhpVersion `
            -Version $ver `
            -Config $config `
            -Manifests $manifests `
            -SourceDir $sourceDir

        if ($installedPath -and $config.Flags.RegisterPhpPath) {
            $pathsToRegister += $installedPath
        }
    }

    # Step 4: Install and configure Apache HTTPD
    if ($config.Flags.InstallApache) {
        $apacheBin = Install-ApacheServer -Config $config -Manifests $manifests -SourceDir $sourceDir
        if ($config.Flags.RegisterApachePath -and $apacheBin) {
            $pathsToRegister += $apacheBin
        }
    }

    # Step 5: Install and configure Nginx
    if ($config.Flags.InstallNginx) {
        $nginxPath = Install-NginxServer -Config $config -SourceDir $sourceDir
        if ($config.Flags.RegisterNginxPath -and $nginxPath) {
            $pathsToRegister += $nginxPath
        }
    }

    # Step 6: Temporary directory cleanup
    if ($config.Flags.CleanTmpDir) {
        Clear-TemporaryFiles -TmpDir $config.TmpDir
    }

    # Step 7: System environment path registration
    if ($pathsToRegister.Count -gt 0) {
        Register-EnvironmentPaths -PathName $config.PathEnvName -PathsToRegister $pathsToRegister
    }

    Write-Output "=== installation completed successfully ==="
}

# Execute orchestration
Invoke-Installer -BoundParameters $PSBoundParameters -RootDirectory $ScriptRoot