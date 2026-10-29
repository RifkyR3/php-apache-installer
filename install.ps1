#Requires -Version 5.1
<#
.SYNOPSIS
    Automated installer and configurator for PHP, Apache, Nginx, Composer, PIE, Xdebug, and Imagick on Windows.

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
    [Parameter(Position = 0)]
    [ValidateSet('install', 'menu', 'check')]
    [string]$Action = 'install',

    [switch]$Menu,
    [switch]$Check,

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
    [Nullable[bool]]$InstallPie,
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
        InstallPie         = Resolve-BooleanOption 'InstallPie'         'INSTALL_PIE'         $true
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
    $phpBinDir = Join-Path $phpDir "bin"

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
        PhpBinDir    = $phpBinDir
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
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$TargetDir,
        [Parameter(Mandatory = $true)][string]$FileName,
        [bool]$ForceDownload = $false,
        [string]$ExpectedHash = '',
        [int]$MaxRetries = 3
    )

    $targetPath = Join-Path $TargetDir $FileName
    $needDownload = $ForceDownload -or (-not (Test-Path -LiteralPath $targetPath))

    # If file exists, verify cached copy before skipping download
    if (-not $needDownload) {
        if (-not [string]::IsNullOrWhiteSpace($ExpectedHash)) {
            if (-not (Test-FileChecksum -Path $targetPath -ExpectedHash $ExpectedHash)) {
                Write-Warning "Cached file '$FileName' failed SHA-256 verification (corrupted or outdated). Removing..."
                Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
                $needDownload = $true
            }
        }
        elseif ($FileName.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase)) {
            $zipValid = $true
            try {
                $za = [System.IO.Compression.ZipFile]::OpenRead($targetPath)
                $null = $za.Entries
                $za.Dispose()
            }
            catch {
                $zipValid = $false
            }
            if (-not $zipValid) {
                Write-Warning "Cached file '$FileName' is an invalid zip archive. Removing..."
                Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
                $needDownload = $true
            }
        }
    }

    # If cached file is valid, skip download early
    if (-not $needDownload) {
        if (-not [string]::IsNullOrWhiteSpace($ExpectedHash)) {
            Write-Output "Already exists & verified (SHA-256): $targetPath"
        }
        else {
            Write-Output "Already exists: $targetPath"
        }
        return
    }

    if (-not $PSCmdlet.ShouldProcess($targetPath, "Download from $Url")) {
        return
    }

    # Execute download with automatic retry on network failure, corrupt archive, or SHA-256 mismatch
    $attempt = 0
    $downloadSuccess = $false

    while ($attempt -lt $MaxRetries -and -not $downloadSuccess) {
        $attempt++
        if ($attempt -gt 1) {
            Write-Host "  -> Attempt $attempt/${MaxRetries}: Re-downloading $FileName..." -ForegroundColor Yellow
        } else {
            Write-Output "Downloading $FileName to $TargetDir"
        }

        try {
            Download-File $Url $targetPath
        }
        catch {
            if ($attempt -ge $MaxRetries) {
                throw "Download failed after $MaxRetries attempts: $Url. Error: $_"
            }
            Write-Warning "Download attempt $attempt failed: $_. Retrying..."
            Start-Sleep -Seconds (2 * $attempt)
            continue
        }

        if (-not (Test-Path -LiteralPath $targetPath)) {
            continue
        }

        # Validate post-download checksum if hash is specified
        if (-not [string]::IsNullOrWhiteSpace($ExpectedHash)) {
            if (-not (Test-FileChecksum -Path $targetPath -ExpectedHash $ExpectedHash)) {
                Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
                if ($attempt -lt $MaxRetries) {
                    Write-Warning "Downloaded file '$FileName' failed SHA-256 verification (corrupted or mismatch). Auto-retrying ($attempt/$MaxRetries)..."
                    Start-Sleep -Seconds (2 * $attempt)
                    continue
                } else {
                    throw "Downloaded file $FileName failed SHA-256 checksum verification after $MaxRetries attempts: $Url"
                }
            }
            Write-Host "  -> SHA-256 checksum verified for $FileName" -ForegroundColor Green
        }

        # Validate zip integrity if the downloaded file is an archive
        if ($FileName.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase)) {
            $zipValid = $true
            try {
                $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($targetPath)
                $null = $zipArchive.Entries
                $zipArchive.Dispose()
            }
            catch {
                $zipValid = $false
            }

            if (-not $zipValid) {
                Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
                if ($attempt -lt $MaxRetries) {
                    Write-Warning "Downloaded file '$FileName' is an invalid zip archive. Auto-retrying ($attempt/$MaxRetries)..."
                    Start-Sleep -Seconds (2 * $attempt)
                    continue
                } else {
                    throw "Downloaded file $FileName is not a valid zip archive after $MaxRetries attempts: $Url"
                }
            }
        }

        $downloadSuccess = $true
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
    Write-Output "PHP bin path: $($Config.PhpBinDir)"
    Write-Output "PHP versions: $($Config.Versions -join ', ')"
    Write-Output "Download PHP packages: $($Config.Flags.DownloadPhp)"
    Write-Output "Install Xdebug: $($Config.Flags.InstallXdebug)"
    Write-Output "Install Imagick: $($Config.Flags.InstallImagick)"
    Write-Output "Install Composer: $($Config.Flags.InstallComposer)"
    Write-Output "Install PIE: $($Config.Flags.InstallPie)"
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

    Write-Host ""
    Write-Host ">>> [Phase 1/7] Installing Visual C++ Redistributables via winget..." -ForegroundColor Cyan
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

    Write-Host ""
    Write-Host ">>> [Phase 2/7] Checking & Downloading Required Packages (to $($Config.TmpDir))..." -ForegroundColor Cyan

    $baseUrl = $Manifests.BaseUrl
    $tmpDir = $Config.TmpDir

    # Download Composer packages if enabled
    if ($Config.Flags.InstallComposer) {
        Write-Host "  -> Verifying Composer binaries..." -ForegroundColor DarkGray
        Save-PackageFile -Url $baseUrl.COMPOSER -TargetDir $tmpDir -FileName "composer.phar" -ForceDownload $false
        Save-PackageFile -Url $baseUrl.COMPOSER_LTS -TargetDir $tmpDir -FileName "composer-lts.phar" -ForceDownload $false
    }

    # Download PIE package if enabled (always freshly downloaded at the start, purging cached copy)
    if ($Config.Flags.InstallPie) {
        Write-Host "  -> Downloading latest PIE binary (always fresh upstream release)..." -ForegroundColor DarkGray
        $pieTmpFile = Join-Path $tmpDir "pie.phar"
        if (Test-Path -LiteralPath $pieTmpFile) {
            Remove-Item -LiteralPath $pieTmpFile -Force -ErrorAction SilentlyContinue
        }
        Save-PackageFile -Url $baseUrl.PIE -TargetDir $tmpDir -FileName "pie.phar" -ForceDownload $true
    }

    # Download PHP and extension packages
    $vCount = $Config.Versions.Count
    $vIdx = 0
    foreach ($version in $Config.Versions) {
        $vIdx++
        $phpData = Get-ObjectProperty $Manifests.PhpVersions $version
        if ($null -eq $phpData) {
            Write-Warning "Version '$version' not found in php-versions.json manifest; skipping."
            continue
        }

        # Resolve PHP package properties
        $phpName     = Get-ObjectProperty $phpData "name"
        $phpDownload = Get-ObjectProperty $phpData "download"
        $phpBaseFile = if ($Config.BuildType -eq "NTS") { $phpName } else { $phpName.Replace("-nts", "") }
        $phpSha      = if ($Config.BuildType -eq "NTS") { Get-ObjectProperty $phpData "sha256" } else { $null }
        $phpUrl = if ($phpDownload -eq "release") {
            "$($baseUrl.PHP_RELEASE)$phpBaseFile"
        } else {
            "$($baseUrl.PHP)$phpBaseFile"
        }

        Write-Host "  -> [$vIdx/$vCount] Checking PHP $version package ($phpBaseFile)..." -ForegroundColor DarkGray
        try {
            Save-PackageFile -Url $phpUrl -TargetDir $tmpDir -FileName $phpBaseFile -ForceDownload $Config.Flags.DownloadPhp -ExpectedHash $phpSha
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
            Write-Host "     * Checking Xdebug for PHP $version ($xdebugFile)..." -ForegroundColor DarkGray
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
                Write-Host "     * Checking Imagick for PHP $version ($imagickFile)..." -ForegroundColor DarkGray
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
        Write-Host "  -> Checking Apache HTTPD package ($apacheFileName)..." -ForegroundColor DarkGray
        Save-PackageFile -Url $apacheUrl -TargetDir $tmpDir -FileName $apacheFileName -ForceDownload $Config.Flags.DownloadApache

        $fcgiUrl = $baseUrl.APACHE_FCGI
        $fcgiFileName = [System.IO.Path]::GetFileName($fcgiUrl)
        Write-Host "  -> Checking mod_fcgid module package ($fcgiFileName)..." -ForegroundColor DarkGray
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

        Write-Host "  -> Checking Nginx web server package ($nginxBaseFile)..." -ForegroundColor DarkGray
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

    # Disable duplicate initiations (e.g. extension=mysqli example vs real extension)
    Disable-DuplicatePhpIniDirectives -IniPath $DestinationIniPath
}

function Disable-DuplicatePhpIniDirectives {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IniPath
    )

    if (-not (Test-Path -LiteralPath $IniPath)) {
        Write-Warning "PHP configuration file not found at: $IniPath"
        return
    }

    $lines = [System.IO.File]::ReadAllLines($IniPath)
    $modified = $false
    $extOccurrences = @{}

    # 1. Scan active extension initiations and directives
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*[;#]' -or [string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        # Check for extension or zend_extension directive
        if ($line -match '^\s*(?<type>extension|zend_extension)\s*=\s*(?<quote>["'']?)(?<target>[^"''\r\n;]+)\k<quote>') {
            $rawTarget = $matches['target'].Trim()
            $normTarget = [System.IO.Path]::GetFileNameWithoutExtension($rawTarget) -replace '^php_', ''
            $key = "$($matches['type']):$normTarget".ToLowerInvariant()

            # Check if this occurrence is located inside an example/doc block
            $start = [Math]::Max(0, $i - 6)
            $contextBefore = ($lines[$start..$i] -join "`n")
            $end = [Math]::Min($lines.Length - 1, $i + 4)
            $contextAfter = ($lines[$i..$end] -join "`n")

            $isExample = ($contextBefore -match ';\s*For example:' -or
                          $contextBefore -match ';\s*syntax:' -or
                          $contextAfter -match ';\s*When the extension library')

            if (-not $extOccurrences.ContainsKey($key)) {
                $extOccurrences[$key] = [System.Collections.Generic.List[PSCustomObject]]::new()
            }

            $extOccurrences[$key].Add([PSCustomObject]@{
                Index      = $i
                RawLine    = $line
                IsExample  = $isExample
                NormTarget = $normTarget
            })
        }
        # Check for extension_dir directive
        elseif ($line -match '^\s*(?<directive>extension_dir)\s*=\s*(?<value>[^;\r\n]+)') {
            $key = "directive:extension_dir"
            if (-not $extOccurrences.ContainsKey($key)) {
                $extOccurrences[$key] = [System.Collections.Generic.List[PSCustomObject]]::new()
            }
            $extOccurrences[$key].Add([PSCustomObject]@{
                Index      = $i
                RawLine    = $line
                IsExample  = $false
                NormTarget = "extension_dir"
            })
        }
    }

    # 2. Process duplicates and disable redundant lines
    foreach ($key in $extOccurrences.Keys) {
        $list = $extOccurrences[$key]
        if ($list.Count -le 1) {
            continue
        }

        # Determine which occurrence to keep:
        # Prefer the first non-example occurrence (e.g. from the extension list).
        # If all are non-examples, keep the first one.
        $nonExamples = @($list | Where-Object { -not $_.IsExample })
        $keepItem = if ($nonExamples.Count -gt 0) {
            $nonExamples[0]
        } else {
            $list[0]
        }

        foreach ($item in $list) {
            if ($item.Index -eq $keepItem.Index) {
                continue
            }

            # Disable duplicate occurrence by commenting it out with ';'
            $lines[$item.Index] = ";$($lines[$item.Index])"
            $modified = $true
            Write-Output "Disabled duplicate PHP initiation (Line $($item.Index + 1)): $($item.RawLine)"
        }
    }

    if ($modified) {
        [System.IO.File]::WriteAllLines($IniPath, $lines, [System.Text.Encoding]::UTF8)
        Write-Output "Deduplicated active initiations in: $IniPath"
    }
}

function Install-PhpVersion {
    [CmdletBinding(SupportsShouldProcess = $true)]
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

    if (-not $PSCmdlet.ShouldProcess("PHP $Version (alias: $versionAlias)", "Extract and configure in $phpExtractDir")) {
        return $phpExtractDir
    }

    Write-Host ""
    Write-Host ">>> Extracting & Configuring PHP $Version (alias: $versionAlias)..." -ForegroundColor Cyan

    # Clean previous extraction directory
    if (Test-Path -LiteralPath $phpExtractDir) {
        Write-Host "  -> [1/6] Cleaning existing directory $phpExtractDir..." -ForegroundColor DarkGray
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
    Write-Host "  -> [1/6] Extracting $phpBaseFile to $phpExtractDir..." -ForegroundColor DarkGray
    Expand-Archive -LiteralPath $zipPath -DestinationPath $phpExtractDir

    # Determine Xdebug path if enabled
    $xdebugExtPath = Join-Path $phpExtractDir "ext\php_xdebug.dll"
    $xdebugProp = Get-ObjectProperty $phpData "xdebug"
    if ($Config.Flags.InstallXdebug -and -not [string]::IsNullOrWhiteSpace($xdebugProp)) {
        $xdebugFileName = if ($Config.BuildType -eq "NTS") { $xdebugProp } else { $xdebugProp.Replace("-nts", "") }
        $sourceXdebug = Join-Path $Config.TmpDir $xdebugFileName
        if (Test-Path -LiteralPath $sourceXdebug) {
            Write-Host "  -> [2/6] Installing Xdebug extension ($xdebugFileName)..." -ForegroundColor DarkGray
            Copy-Item -LiteralPath $sourceXdebug -Destination $xdebugExtPath -Force
        }
    } else {
        Write-Host "  -> [2/6] Skipping Xdebug (disabled or not configured)" -ForegroundColor DarkGray
    }

    # Extract and copy Imagick DLLs if enabled
    $imagickProp = Get-ObjectProperty $phpData "imagick"
    $hasImagick = $Config.Flags.InstallImagick -and -not [string]::IsNullOrWhiteSpace($imagickProp)
    if ($hasImagick) {
        $imagickFileName = if ($Config.BuildType -eq "NTS") { $imagickProp } else { $imagickProp.Replace("-nts", "") }
        $imagickZip = Join-Path $Config.TmpDir $imagickFileName

        if (Test-Path -LiteralPath $imagickZip) {
            Write-Host "  -> [3/6] Extracting and deploying Imagick extension ($imagickFileName)..." -ForegroundColor DarkGray
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
    } else {
        Write-Host "  -> [3/6] Skipping Imagick (disabled or not configured)" -ForegroundColor DarkGray
    }

    # Configure php.ini
    Write-Host "  -> [4/6] Configuring php.ini (enabling extensions, base settings, xdebug, imagick)..." -ForegroundColor DarkGray
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

    # Check and disable duplicate initiations after Configure-PhpIni finishes
    Disable-DuplicatePhpIniDirectives -IniPath $targetIni

    # Generate versioned binary aliases
    Write-Host "  -> [5/6] Generating CLI binary aliases: php${versionAlias}.exe & php${versionAlias}-cgi.exe..." -ForegroundColor DarkGray
    Copy-Item -LiteralPath (Join-Path $phpExtractDir "php.exe") -Destination (Join-Path $phpExtractDir "php${versionAlias}.exe") -Force
    Copy-Item -LiteralPath (Join-Path $phpExtractDir "php-cgi.exe") -Destination (Join-Path $phpExtractDir "php${versionAlias}-cgi.exe") -Force

    # Configure Composer if enabled
    if ($Config.Flags.InstallComposer) {
        Write-Host "  -> [6/6] Deploying Composer (composer${versionAlias}.bat)..." -ForegroundColor DarkGray
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
    } else {
        Write-Host "  -> [6/6] Skipping Composer (disabled)" -ForegroundColor DarkGray
    }

    # Configure PIE if enabled (requires PHP 8.1+)
    if ($Config.Flags.InstallPie) {
        $pieMinVer = 81
        if ([int]$versionAlias -ge $pieMinVer) {
            Write-Host "  -> [7/7] Deploying PIE (pie${versionAlias}.bat)..." -ForegroundColor DarkGray
            $pieSource = Join-Path $Config.TmpDir "pie.phar"
            if (Test-Path -LiteralPath $pieSource) {
                Copy-Item -LiteralPath $pieSource -Destination (Join-Path $phpExtractDir "pie.phar") -Force
            }

            $pieBatTemplate = Join-Path $SourceDir "pie.bat"
            if (Test-Path -LiteralPath $pieBatTemplate) {
                Copy-Item -LiteralPath $pieBatTemplate -Destination (Join-Path $phpExtractDir "pie.bat") -Force
                Copy-Item -LiteralPath $pieBatTemplate -Destination (Join-Path $phpExtractDir "pie${versionAlias}.bat") -Force
            }
        } else {
            Write-Host "  -> [7/7] Skipping PIE (requires PHP 8.1+)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  -> [7/7] Skipping PIE (disabled)" -ForegroundColor DarkGray
    }

    Write-Host "  [OK] PHP $Version installed successfully in $phpExtractDir" -ForegroundColor Green
    return $phpExtractDir
}

function Install-ApacheServer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$Config,
        [Parameter(Mandatory = $true)][PSCustomObject]$Manifests,
        [Parameter(Mandatory = $true)][string]$SourceDir
    )

    $apacheDir = $Config.ApacheDir
    $apacheBin = Join-Path $apacheDir "bin"
    if (-not $PSCmdlet.ShouldProcess("Apache HTTPD Server", "Extract and configure in $apacheDir")) {
        return $apacheBin
    }

    Write-Host ""
    Write-Host ">>> Installing and Configuring Apache HTTPD Server..." -ForegroundColor Cyan

    if (Test-Path -LiteralPath $apacheDir) {
        Write-Host "  -> [1/4] Cleaning previous Apache directory $apacheDir..." -ForegroundColor DarkGray
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
    Write-Host "  -> [1/4] Extracting Apache HTTPD ($apacheFileName) to $apacheDir..." -ForegroundColor DarkGray
    $tmpApacheDir = Join-Path $Config.TmpDir "APACHE"
    if (Test-Path -LiteralPath $tmpApacheDir) { Remove-Item -LiteralPath $tmpApacheDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpApacheDir | Out-Null
    Expand-Archive -LiteralPath $tmpApacheZip -DestinationPath $tmpApacheDir

    $subDir = Get-ChildItem -LiteralPath $tmpApacheDir -Directory | Select-Object -First 1 -ExpandProperty Name
    Move-Item -LiteralPath (Join-Path $tmpApacheDir $subDir) -Destination $apacheDir

    # Extract mod_fcgid
    Write-Host "  -> [2/4] Installing FastCGI module (mod_fcgid.so)..." -ForegroundColor DarkGray
    $tmpFcgiDir = Join-Path $Config.TmpDir "APACHE_FCGI"
    if (Test-Path -LiteralPath $tmpFcgiDir) { Remove-Item -LiteralPath $tmpFcgiDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpFcgiDir | Out-Null
    Expand-Archive -LiteralPath $tmpFcgiZip -DestinationPath $tmpFcgiDir

    $fcgiModule = Join-Path $tmpFcgiDir "mod_fcgid.so"
    if (Test-Path -LiteralPath $fcgiModule) {
        Move-Item -LiteralPath $fcgiModule -Destination (Join-Path $apacheDir "modules\mod_fcgid.so") -Force
    }

    # Configure httpd.conf
    Write-Host "  -> [3/4] Configuring httpd.conf and multi-port PHP FastCGI handlers..." -ForegroundColor DarkGray
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
    Write-Host "  -> [4/4] Deploying virtual host templates and management scripts..." -ForegroundColor DarkGray
    $hostConfDir = Join-Path $apacheDir "conf\extra\host"
    New-Item -ItemType Directory -Path $hostConfDir -Force | Out-Null
    Copy-Item -Path (Join-Path $SourceDir "apache\host\*") -Destination $hostConfDir -Recurse -Force

    # Copy utility scripts
    $binDir = Join-Path $apacheDir "bin"
    Copy-Item -LiteralPath (Join-Path $SourceDir "apache\apacheRegister.ps1") -Destination (Join-Path $binDir "apacheRegister.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $SourceDir "apache\apacheUnistall.ps1") -Destination (Join-Path $binDir "apacheUnistall.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $SourceDir "apache\apacheTest.ps1") -Destination (Join-Path $binDir "apacheTest.ps1") -Force

    Write-Host "  [OK] Apache HTTPD configured successfully in $apacheDir" -ForegroundColor Green
    return $binDir
}

function Install-NginxServer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$Config,
        [Parameter(Mandatory = $true)][string]$SourceDir
    )

    $nginxDir = $Config.NginxDir
    if (-not $PSCmdlet.ShouldProcess("Nginx Web Server", "Extract and configure in $nginxDir")) {
        return $nginxDir
    }

    Write-Host ""
    Write-Host ">>> Installing and Configuring Nginx Web Server..." -ForegroundColor Cyan

    if (Test-Path -LiteralPath $nginxDir) {
        Write-Host "  -> [1/3] Cleaning previous Nginx directory $nginxDir..." -ForegroundColor DarkGray
        Remove-Item -LiteralPath $nginxDir -Recurse -Force
    }

    $tmpNginxZip = Join-Path $Config.TmpDir $Config.NginxBase

    # Extract Nginx
    Write-Host "  -> [1/3] Extracting $($Config.NginxBase) to $nginxDir..." -ForegroundColor DarkGray
    $tmpNginxDir = Join-Path $Config.TmpDir "NGINX"
    if (Test-Path -LiteralPath $tmpNginxDir) { Remove-Item -LiteralPath $tmpNginxDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpNginxDir | Out-Null
    Expand-Archive -LiteralPath $tmpNginxZip -DestinationPath $tmpNginxDir

    $subDir = Get-ChildItem -LiteralPath $tmpNginxDir -Directory | Select-Object -First 1 -ExpandProperty Name
    Move-Item -LiteralPath (Join-Path $tmpNginxDir $subDir) -Destination $nginxDir

    # Configure nginx.conf
    Write-Host "  -> [2/3] Configuring nginx.conf with document root ($($Config.HtdocsDir))..." -ForegroundColor DarkGray
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
    Write-Host "  -> [3/3] Deploying server block configurations and webserver_nginx.bat..." -ForegroundColor DarkGray
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

    Write-Host "  [OK] Nginx Web Server configured successfully in $nginxDir" -ForegroundColor Green
    return $nginxDir
}

function Register-EnvironmentPaths {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string[]]$PathsToRegister,
        [string]$PhpDir = ''
    )

    $validPaths = @($PathsToRegister | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($validPaths.Count -gt 0) {
        $combined = $validPaths -join ";"
        if ($PSCmdlet.ShouldProcess("User Environment Variable 'Path'", "Register entries: $combined")) {
            Write-Output "Registering entries to User Path: $combined"
            Register-Path-Web -PathsToRegister $validPaths -PhpDir $PhpDir
        }
    }
}

function Clear-TemporaryFiles {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$TmpDir)

    if (Test-Path -LiteralPath $TmpDir) {
        if ($PSCmdlet.ShouldProcess($TmpDir, "Remove temporary directory and all contents")) {
            Write-Output "Cleaning temporary directory: $TmpDir"
            Remove-Item -LiteralPath $TmpDir -Recurse -Force
        }
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
    Write-Host ""
    Write-Host ">>> [Phase 3/7] Extracting & Configuring PHP Versions ($($config.Versions.Count) target(s))..." -ForegroundColor Cyan
    $pathsToRegister = @()
    $phpIndex = 0
    foreach ($ver in $config.Versions) {
        $phpIndex++
        Write-Host ""
        Write-Host "--- [$phpIndex/$($config.Versions.Count)] Processing PHP $ver ---" -ForegroundColor Yellow
        $installedPath = Install-PhpVersion `
            -Version $ver `
            -Config $config `
            -Manifests $manifests `
            -SourceDir $sourceDir
    }

    # Step 3.1: Create PHP bin directory and generate CLI binary links (php, php-cgi, composer & pie)
    Write-Host ""
    Write-Host ">>> Deploying PHP, PHP-CGI, Composer & PIE CLI links in bin ($($config.PhpBinDir))..." -ForegroundColor Cyan
    Deploy-PhpBinLinks -PhpDir $config.PhpDir -PhpBinDir $config.PhpBinDir -Manifests $manifests

    if ($config.Flags.RegisterPhpPath -and (Test-Path -LiteralPath $config.PhpBinDir)) {
        $pathsToRegister += $config.PhpBinDir
    }

    # Step 4: Install and configure Apache HTTPD
    if ($config.Flags.InstallApache) {
        Write-Host ""
        Write-Host ">>> [Phase 4/7] Installing Apache HTTPD Web Server..." -ForegroundColor Cyan
        $apacheBin = Install-ApacheServer -Config $config -Manifests $manifests -SourceDir $sourceDir
        if ($config.Flags.RegisterApachePath -and $apacheBin) {
            $pathsToRegister += $apacheBin
        }
    }

    # Step 5: Install and configure Nginx
    if ($config.Flags.InstallNginx) {
        Write-Host ""
        Write-Host ">>> [Phase 5/7] Installing Nginx Web Server..." -ForegroundColor Cyan
        $nginxPath = Install-NginxServer -Config $config -SourceDir $sourceDir
        if ($config.Flags.RegisterNginxPath -and $nginxPath) {
            $pathsToRegister += $nginxPath
        }
    }

    # Step 6: Temporary directory cleanup
    if ($config.Flags.CleanTmpDir) {
        Write-Host ""
        Write-Host ">>> [Phase 6/7] Cleaning Temporary Directory..." -ForegroundColor Cyan
        Clear-TemporaryFiles -TmpDir $config.TmpDir
    }

    # Step 7: System environment path registration
    if ($pathsToRegister.Count -gt 0) {
        Write-Host ""
        Write-Host ">>> [Phase 7/7] Registering User Environment Paths..." -ForegroundColor Cyan
        Register-EnvironmentPaths -PathsToRegister $pathsToRegister -PhpDir $config.PhpDir
    }

    Write-Host ""
    Write-Host "=================================================================================" -ForegroundColor Green
    Write-Host " INSTALLATION COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "=================================================================================" -ForegroundColor Green
    Write-Host " Installed PHP     : $($config.Versions -join ', ')" -ForegroundColor White
    Write-Host " PHP CLI Bin (PATH): $($config.PhpBinDir)" -ForegroundColor White
    if ($config.Flags.InstallApache) {
        Write-Host " Apache Server     : $($config.ApacheDir)" -ForegroundColor White
    }
    if ($config.Flags.InstallNginx) {
        Write-Host " Nginx Server      : $($config.NginxDir)" -ForegroundColor White
    }
    Write-Host " Document Root     : $($config.HtdocsDir)" -ForegroundColor White
    Write-Host " Server Controller : Run '.\control.bat' to start and manage servers" -ForegroundColor Cyan
    Write-Host "=================================================================================" -ForegroundColor Green
}

# --- 4. Interactive UI & Pre-Flight Utilities ---

function Pause-InstallerConsole {
    Write-Host ""
    Write-Host "Press Enter to return to menu..." -ForegroundColor DarkGray
    [void][System.Console]::ReadLine()
}

function Show-ConfigSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][PSCustomObject]$Config)

    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host " ACTIVE INSTALLATION CONFIGURATION (.env)" -ForegroundColor White
    Write-Host "===================================================" -ForegroundColor Cyan
    Write-Host " Install Directory : $($Config.InstallDir)"
    Write-Host " Apache Directory  : $($Config.ApacheDir)"
    Write-Host " Nginx Directory   : $($Config.NginxDir)"
    Write-Host " PHP Directory     : $($Config.PhpDir)"
    Write-Host " PHP Bin Directory : $($Config.PhpBinDir)"
    Write-Host " Document Root     : $($Config.HtdocsDir)"
    Write-Host " Temporary Path    : $($Config.TmpDir)"
    Write-Host " PHP Build Type    : $($Config.BuildType)"
    Write-Host " PHP Versions      : $($Config.Versions -join ', ')"
    Write-Host " Apache Base       : $($Config.ApacheBase)"
    Write-Host " Nginx Base        : $($Config.NginxBase)"
    Write-Host " Feature Flags:" -ForegroundColor Yellow
    Write-Host "   Install Apache      : $($Config.Flags.InstallApache)"
    Write-Host "   Install Nginx       : $($Config.Flags.InstallNginx)"
    Write-Host "   Install Composer    : $($Config.Flags.InstallComposer)"
    Write-Host "   Install PIE         : $($Config.Flags.InstallPie)"
    Write-Host "   Install Xdebug      : $($Config.Flags.InstallXdebug)"
    Write-Host "   Install Imagick     : $($Config.Flags.InstallImagick)"
    Write-Host "   Install VC Redist   : $($Config.Flags.InstallVCRedist)"
    Write-Host "   Register PHP Path   : $($Config.Flags.RegisterPhpPath)"
    Write-Host "   Register Apache Path: $($Config.Flags.RegisterApachePath)"
    Write-Host "   Register Nginx Path : $($Config.Flags.RegisterNginxPath)"
    Write-Host "   Clean Temp Dir      : $($Config.Flags.CleanTmpDir)"
    Write-Host "===================================================" -ForegroundColor Cyan
}

function Invoke-PreFlightCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$Config,
        [Parameter(Mandatory = $true)][PSCustomObject]$Manifests
    )

    Write-Host ""
    Write-Host "=================================================================================" -ForegroundColor Cyan
    Write-Host " PRE-FLIGHT VERIFICATION: PACKAGE CACHE & INTEGRITY STATUS" -ForegroundColor White
    Write-Host " Target Directory: $($Config.TmpDir)" -ForegroundColor DarkGray
    Write-Host "=================================================================================" -ForegroundColor Cyan

    $formatString = "{0,-16} | {1,-38} | {2,-16} | {3}"
    Write-Host ([string]::Format($formatString, "Target", "Package File Name", "Status", "Size")) -ForegroundColor DarkGray
    Write-Host ("-" * 85) -ForegroundColor DarkGray

    $items = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Composer
    if ($Config.Flags.InstallComposer) {
        $items.Add([PSCustomObject]@{ Target = "Composer"; File = "composer.phar" })
        $items.Add([PSCustomObject]@{ Target = "Composer-LTS"; File = "composer-lts.phar" })
    }

    # PHP PIE
    if ($Config.Flags.InstallPie) {
        $items.Add([PSCustomObject]@{ Target = "PHP PIE"; File = "pie.phar" })
    }

    # PHP versions
    foreach ($ver in $Config.Versions) {
        $entry = Get-ObjectProperty $Manifests.PhpVersions $ver
        if ($null -ne $entry) {
            $phpName = Get-ObjectProperty $entry "name"
            if ($phpName) {
                $phpBase = if ($Config.BuildType -eq "NTS") { $phpName } else { $phpName.Replace("-nts", "") }
                $phpSha  = if ($Config.BuildType -eq "NTS") { Get-ObjectProperty $entry "sha256" } else { $null }
                $items.Add([PSCustomObject]@{ Target = "PHP $ver"; File = $phpBase; ExpectedHash = $phpSha })
            }
            if ($Config.Flags.InstallXdebug) {
                $xd = Get-ObjectProperty $entry "xdebug"
                if ($xd) {
                    $xdBase = if ($Config.BuildType -eq "NTS") { $xd } else { $xd.Replace("-nts", "") }
                    $items.Add([PSCustomObject]@{ Target = "Xdebug $ver"; File = $xdBase })
                }
            }
            if ($Config.Flags.InstallImagick) {
                $im = Get-ObjectProperty $entry "imagick"
                if ($im) {
                    $imBase = if ($Config.BuildType -eq "NTS") { $im } else { $im.Replace("-nts", "") }
                    $items.Add([PSCustomObject]@{ Target = "Imagick $ver"; File = $imBase })
                }
            }
        }
    }

    # Apache
    if ($Config.Flags.InstallApache) {
        $items.Add([PSCustomObject]@{ Target = "Apache HTTPD"; File = $Config.ApacheBase })
        $fcgiName = [System.IO.Path]::GetFileName($Manifests.BaseUrl.APACHE_FCGI)
        $items.Add([PSCustomObject]@{ Target = "mod_fcgid"; File = $fcgiName })
    }

    # Nginx
    if ($Config.Flags.InstallNginx) {
        $items.Add([PSCustomObject]@{ Target = "Nginx Server"; File = $Config.NginxBase })
    }

    $validCount = 0
    $readyCount = 0
    $missingCount = 0
    $corruptCount = 0

    foreach ($item in $items) {
        $fullPath = Join-Path $Config.TmpDir $item.File
        $exists = Test-Path -LiteralPath $fullPath
        $status = "MISSING"
        $statusColor = "Yellow"
        $sizeStr = "-"

        if ($exists) {
            $fileInfo = Get-Item -LiteralPath $fullPath
            $sizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
            $sizeStr = "$sizeMB MB"

            $expectedHash = if ($item.PSObject.Properties['ExpectedHash']) { $item.ExpectedHash } else { $null }

            if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
                $hashMatch = Test-FileChecksum -Path $fullPath -ExpectedHash $expectedHash
                if ($hashMatch) {
                    $status = "VALID (SHA-256)"
                    $statusColor = "Green"
                    $validCount++
                } else {
                    $status = "HASH MISMATCH"
                    $statusColor = "Red"
                    $corruptCount++
                }
            } elseif ($item.File.EndsWith(".zip", [System.StringComparison]::OrdinalIgnoreCase)) {
                $zipValid = $true
                try {
                    $za = [System.IO.Compression.ZipFile]::OpenRead($fullPath)
                    $null = $za.Entries
                    $za.Dispose()
                } catch {
                    $zipValid = $false
                }

                if ($zipValid) {
                    $status = "READY"
                    $statusColor = "Green"
                    $readyCount++
                } else {
                    $status = "CORRUPT ZIP"
                    $statusColor = "Red"
                    $corruptCount++
                }
            } else {
                $status = "READY"
                $statusColor = "Green"
                $readyCount++
            }
        } else {
            $missingCount++
        }

        Write-Host ([string]::Format($formatString, $item.Target, $item.File, $status, $sizeStr)) -ForegroundColor $statusColor
    }

    Write-Host ("-" * 85) -ForegroundColor DarkGray
    Write-Host "Total Packages Checked: $($items.Count) | Valid (SHA-256): $validCount | Ready: $readyCount | Missing: $missingCount | Corrupt: $corruptCount" -ForegroundColor Cyan
}

function Invoke-CustomInstallWizard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootDirectory,
        [Parameter(Mandatory = $true)][PSCustomObject]$Manifests
    )

    Write-Host ""
    Write-Host "=== Custom Installation Wizard ===" -ForegroundColor Cyan
    Write-Host "Available versions in manifest: $(($Manifests.PhpVersions.PSObject.Properties.Name) -join ', ')" -ForegroundColor DarkGray
    Write-Host "Enter PHP versions to install (comma-separated, e.g. 'v8.2, v8.4' or leave empty for all):"
    $userVersions = Read-Host "PHP Versions"

    $askApache = Read-Host "Install Apache HTTPD Server? (Y/n)"
    $doApache = ($askApache -notmatch '^(n|no)$')

    $askNginx = Read-Host "Install Nginx Web Server? (y/N)"
    $doNginx = ($askNginx -match '^(y|yes)$')

    $askComposer = Read-Host "Install Composer (latest & LTS)? (Y/n)"
    $doComposer = ($askComposer -notmatch '^(n|no)$')

    $askPie = Read-Host "Install PHP PIE (Extension installer for PHP 8.1+)? (Y/n)"
    $doPie = ($askPie -notmatch '^(n|no)$')

    $askXdebug = Read-Host "Install Xdebug Extension? (Y/n)"
    $doXdebug = ($askXdebug -notmatch '^(n|no)$')

    $askImagick = Read-Host "Install Imagick Extension? (Y/n)"
    $doImagick = ($askImagick -notmatch '^(n|no)$')

    $askVc = Read-Host "Install Visual C++ Redistributable via winget? (Y/n)"
    $doVc = ($askVc -notmatch '^(n|no)$')

    $wizardParams = @{
        InstallApache   = $doApache
        InstallNginx    = $doNginx
        InstallComposer = $doComposer
        InstallPie      = $doPie
        InstallXdebug   = $doXdebug
        InstallImagick  = $doImagick
        InstallVCRedist = $doVc
    }

    if (-not [string]::IsNullOrWhiteSpace($userVersions)) {
        $wizardParams['PhpVersions'] = $userVersions
    }

    Write-Host ""
    Write-Host "Proceed with custom installation? (y/N)" -ForegroundColor Yellow
    $confirm = Read-Host
    if ($confirm -match '^(y|yes)$') {
        Invoke-Installer -BoundParameters $wizardParams -RootDirectory $RootDirectory
    } else {
        Write-Host "Custom installation cancelled." -ForegroundColor Yellow
    }
}

function Show-InteractiveInstallMenu {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RootDirectory)

    $sourceDir = Join-Path $RootDirectory "source"
    $manifests = Get-SourceManifests -SourceDir $sourceDir

    while ($true) {
        $config = Get-InstallerConfig -CliParams @{} -RootDirectory $RootDirectory -Manifests $manifests

        Clear-Host
        Write-Host "===================================================" -ForegroundColor Cyan
        Write-Host " PHP & Web Server Installer for Windows" -ForegroundColor White
        Write-Host " Root Directory : $($config.InstallDir)" -ForegroundColor DarkGray
        Write-Host " Apache Package : $($config.ApacheBase)" -ForegroundColor DarkGray
        Write-Host " Nginx Package  : $($config.NginxBase)" -ForegroundColor DarkGray
        Write-Host " PHP Configured : $($config.Versions.Count) versions ($($config.Versions[0]) - $($config.Versions[-1]))" -ForegroundColor DarkGray
        Write-Host "===================================================" -ForegroundColor Cyan
        Write-Host " Installation Presets:" -ForegroundColor Yellow
        Write-Host " [1] Standard Installation (All configured in .env)"
        Write-Host " [2] Modern PHP Stack (PHP 8.2, 8.3, 8.4 + Apache + Composer)"
        Write-Host " [3] Single PHP Version (Interactive version selection)"
        Write-Host " [4] Web Server Only (Apache HTTPD or Nginx)"
        Write-Host " [5] Custom Installation Wizard (Custom versions & components)"
        Write-Host ""
        Write-Host " Verification & Utilities:" -ForegroundColor Yellow
        Write-Host " [6] Pre-Flight Check (Verify cached packages in tmp)"
        Write-Host " [7] View Active Configuration (.env summary)"
        Write-Host " [8] Clean Temporary Files (tmp directory)"
        Write-Host " [0] Exit"
        Write-Host "---------------------------------------------------" -ForegroundColor DarkGray

        $choice = Read-Host "Select option [0-8]"
        switch ($choice) {
            '1' {
                $confirm = Read-Host "Proceed with Standard Installation based on .env? (y/N)"
                if ($confirm -match '^(y|yes)$') {
                    Invoke-Installer -BoundParameters @{} -RootDirectory $RootDirectory
                } else {
                    Write-Host "Installation cancelled." -ForegroundColor Yellow
                }
                Pause-InstallerConsole
            }
            '2' {
                $confirm = Read-Host "Install Modern Stack (PHP 8.2, 8.3, 8.4 + Apache HTTPD + Composer & PIE)? (y/N)"
                if ($confirm -match '^(y|yes)$') {
                    $modernParams = @{
                        PhpVersions     = 'v8.2, v8.3, v8.4'
                        InstallApache   = $true
                        InstallNginx    = $false
                        InstallComposer = $true
                        InstallPie      = $true
                    }
                    Invoke-Installer -BoundParameters $modernParams -RootDirectory $RootDirectory
                } else {
                    Write-Host "Installation cancelled." -ForegroundColor Yellow
                }
                Pause-InstallerConsole
            }
            '3' {
                $targetVer = Read-Host "Enter PHP version to install (e.g. 8.2, 84, 7.4)"
                if (-not [string]::IsNullOrWhiteSpace($targetVer)) {
                    $cleanVer = if ($targetVer.StartsWith('v')) { $targetVer } else { "v$targetVer" }
                    if ($cleanVer -match '^v(\d)(\d)$') {
                        $cleanVer = "v$($matches[1]).$($matches[2])"
                    }
                    $withApache = Read-Host "Install Apache HTTPD web server alongside PHP? (Y/n)"
                    $installApache = ($withApache -notmatch '^(n|no)$')
                    $singleParams = @{
                        PhpVersions   = $cleanVer
                        InstallApache = $installApache
                        InstallNginx  = $false
                    }
                    Invoke-Installer -BoundParameters $singleParams -RootDirectory $RootDirectory
                }
                Pause-InstallerConsole
            }
            '4' {
                Write-Host "Select Web Server to install:"
                Write-Host " [1] Apache HTTPD Server"
                Write-Host " [2] Nginx Web Server"
                Write-Host " [3] Both Apache and Nginx"
                $srvChoice = Read-Host "Select [1-3]"
                $srvParams = @{
                    DownloadPhp     = $false
                    InstallXdebug   = $false
                    InstallImagick  = $false
                    InstallComposer = $false
                    PhpVersions     = ""
                }
                if ($srvChoice -eq '1') {
                    $srvParams['InstallApache'] = $true
                    $srvParams['InstallNginx'] = $false
                    Invoke-Installer -BoundParameters $srvParams -RootDirectory $RootDirectory
                } elseif ($srvChoice -eq '2') {
                    $srvParams['InstallApache'] = $false
                    $srvParams['InstallNginx'] = $true
                    Invoke-Installer -BoundParameters $srvParams -RootDirectory $RootDirectory
                } elseif ($srvChoice -eq '3') {
                    $srvParams['InstallApache'] = $true
                    $srvParams['InstallNginx'] = $true
                    Invoke-Installer -BoundParameters $srvParams -RootDirectory $RootDirectory
                }
                Pause-InstallerConsole
            }
            '5' {
                Invoke-CustomInstallWizard -RootDirectory $RootDirectory -Manifests $manifests
                Pause-InstallerConsole
            }
            '6' {
                Invoke-PreFlightCheck -Config $config -Manifests $manifests
                Pause-InstallerConsole
            }
            '7' {
                Show-ConfigSummary -Config $config
                Pause-InstallerConsole
            }
            '8' {
                $confirm = Read-Host "Clean all files in temporary directory ($($config.TmpDir))? (y/N)"
                if ($confirm -match '^(y|yes)$') {
                    Clear-TemporaryFiles -TmpDir $config.TmpDir
                    Write-Host "Temporary directory cleaned." -ForegroundColor Green
                }
                Pause-InstallerConsole
            }
            '0' {
                return
            }
            default {
                Write-Host "Invalid choice, select between 0 and 8." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# --- 5. Main Execution Entrypoint ---

$finalAction = $Action
if ($Menu)  { $finalAction = 'menu' }
if ($Check) { $finalAction = 'check' }

if ($finalAction -eq 'menu') {
    Show-InteractiveInstallMenu -RootDirectory $ScriptRoot
} elseif ($finalAction -eq 'check') {
    $sourceDir = Join-Path $ScriptRoot "source"
    $manifests = Get-SourceManifests -SourceDir $sourceDir
    $config = Get-InstallerConfig -CliParams $PSBoundParameters -RootDirectory $ScriptRoot -Manifests $manifests
    Invoke-PreFlightCheck -Config $config -Manifests $manifests
} else {
    Invoke-Installer -BoundParameters $PSBoundParameters -RootDirectory $ScriptRoot
}
