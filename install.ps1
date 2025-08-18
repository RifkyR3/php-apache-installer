# Load dependencies
. .\01Include.ps1
. .\02Function.ps1

# Configuration parameters with default values
$config = @{
    InstallVCRedist    = Get-BoolFromEnv $env:INSTALL_VCREDIST
    
    DownloadPhp        = Get-BoolFromEnv $env:DOWNLOAD_PHP
    InstallXdebug      = Get-BoolFromEnv $env:INSTALL_XDEBUG
    PhpPathRegister    = Get-BoolFromEnv $env:REGISTER_PATH_PHP
    
    InstallComposer    = Get-BoolFromEnv $env:INSTALL_COMPOSER
    
    InstallApache      = Get-BoolFromEnv $env:INSTALL_APACHE
    DownloadApache     = Get-BoolFromEnv $env:DOWNLOAD_APACHE
    ApachePathRegister = Get-BoolFromEnv $env:REGISTER_PATH_APACHE
    
    InstallNginx       = Get-BoolFromEnv $env:INSTALL_NGINX
    DownloadNginx      = Get-BoolFromEnv $env:DOWNLOAD_NGINX
    NginxPathRegister  = Get-BoolFromEnv $env:REGISTER_PATH_NGINX
    
    CleanTmpDir        = Get-BoolFromEnv $env:CLEAN_TMP_DIR
}

# Version and type configurations
$basePhpVersions = "v5.4, v5.5, v5.6, v7.0, v7.1, v7.2, v7.3, v7.4, v8.0, v8.1, v8.2, v8.3, v8.4"
$whatToInstall = if ([string]::IsNullOrWhiteSpace($env:INSTALL_PHP_VERSION)) { 
    $basePhpVersions 
}
else { 
    $env:INSTALL_PHP_VERSION 
}
$whatToInstall = $whatToInstall.Replace('"', '').Replace("'", "").Split(",").Trim()
$typeToInstall = "NTS"  # or "TS" for thread-safe version

# Directory configurations
$installDir = Path-Cleaning $PWD $env:INSTALL_DIR
$apacheDir = Join-Path $installDir "apache"
$nginxDir = Join-Path $installDir "nginx"
$phpDir = Join-Path $installDir "PHP"
$phpBaseConfig = "php.ini-development"
$htdocs = Path-Cleaning (Join-Path $apacheDir "htdocs") $env:HTDOCS_DIR

# Initialize paths and temp directory
$pathName = "WEBSERV"
$registerPath = @()
$tmpDir = Join-Path $PWD "tmp/"

if (-not (Test-Path -Path $tmpDir)) {
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    Write-Output "Created TMP directory"
}

# Load configuration files
$baseUrl = Get-Content .\source\baseUrl.json | ConvertFrom-Json
$phpSourceVersions = Get-Content .\source\php-versions.json | ConvertFrom-Json
$phpSourceConfigExtension = Get-Content .\source\php-config-extension.json | ConvertFrom-Json
$phpSourceConfigBase = Get-Content .\source\php-config-base.json | ConvertFrom-Json
$phpSourceConfigXdebug = Get-Content .\source\php-config-xdebug.json | ConvertFrom-Json

# Set progress preference
$ProgressPreference = 'SilentlyContinue'

# Install VCRedist if needed
if ($config.InstallVCRedist) {
    Write-Output "Installing all VCRedist packages"
    winget import -i .\source\winget-VCRedist.json --accept-package-agreements --accept-source-agreements --disable-interactivity
}

# Composer configuration
$composerConfig = @{
    Main           = "composer.phar"
    Lts            = "composer-lts.phar"
    MinimumVersion = 72
    MainPath       = Join-Path $tmpDir "composer.phar"
    LtsPath        = Join-Path $tmpDir "composer-lts.phar"
}

if ($config.InstallComposer) {
    Check-Download $baseUrl.COMPOSER $tmpDir $composerConfig.Main
    Check-Download $baseUrl.COMPOSER_LTS $tmpDir $composerConfig.Lts
}

# PHP Installation
foreach ($version in $whatToInstall) {
    $phpData = $phpSourceVersions.$version
        
    # Download PHP
    $phpBaseFile = if ($typeToInstall -eq "NTS") { $phpData.name } else { $phpData.name.Replace("-nts", "") }
    $url = if ($phpData.download -eq "release") { 
        "$($baseUrl.PHP_RELEASE)$phpBaseFile" 
    }
    else { 
        "$($baseUrl.PHP)$phpBaseFile" 
    }
        
    if ($config.DownloadPhp) {
        Write-Output "Downloading $phpBaseFile to $tmpDir"
        try {
            Download-File $url (Join-Path $tmpDir $phpBaseFile)
        }
        catch {
            Write-Error "Failed to download PHP $version`: $_"
            Write-Error "Cancelling installation due to failed download."
            exit 1  # Stops the entire script with error code
        }
    }
    else {
        try {
            Check-Download $url $tmpDir $phpBaseFile
        }
        catch {
            Write-Error "Failed to download or verify $phpBaseFile`: $_"
            Write-Error "Cancelling installation."
            exit 1
        }
    }

    # Download Xdebug if needed
    if ($config.InstallXdebug) {
        $phpXdebug = if ($typeToInstall -eq "NTS") { $phpData.xdebug } else { $phpData.xdebug.Replace("-nts", "") }
        $xdebugUrl = "$($baseUrl.XDEBUG)$phpXdebug"

        try {
            Check-Download $xdebugUrl $tmpDir $phpXdebug
        }
        catch {
            Write-Error "Failed to download Xdebug $phpXdebug`: $_"
            Write-Error "Cancelling installation."
            exit 1
        }
    }
}

# Process each PHP version
foreach ($version in $whatToInstall) {
    $phpData = $phpSourceVersions.$version
    $phpBaseFile = if ($typeToInstall -eq "NTS") { $phpData.name } else { $phpData.name.Replace("-nts", "") }
    $phpVersionDir = $phpData.alias
    $phpDirExtract = Join-Path $phpDir $phpVersionDir

    # Clean and create directory
    if (Test-Path $phpDirExtract) {
        Remove-Item -Recurse -Force $phpDirExtract
    }
    New-Item -ItemType Directory -Path $phpDirExtract | Out-Null

    # Extract PHP
    Write-Output "Extracting $phpBaseFile to $phpDirExtract"
    Expand-Archive -Path (Join-Path $tmpDir $phpBaseFile) -DestinationPath $phpDirExtract

    # Configure PHP
    $phpIni = Join-Path $phpDirExtract "php.ini"
    Copy-Item (Join-Path $phpDirExtract $phpBaseConfig) $phpIni
    Copy-Item (Join-Path $phpDirExtract "php.exe") (Join-Path $phpDirExtract "php${phpVersionDir}.exe")
    Copy-Item (Join-Path $phpDirExtract "php-cgi.exe") (Join-Path $phpDirExtract "php${phpVersionDir}-cgi.exe")

    # Configure extensions
    $typeConfig = $phpData.config
    $copyConfig = $phpSourceConfigExtension.$typeConfig
    foreach ($value in $copyConfig) {
        (Get-Content $phpIni) -replace ";$value", $value -replace "; $value", $value | Set-Content $phpIni
    }

    # Add base configuration
    $phpSourceConfigBase.base | ForEach-Object {
        Add-Content -Path $phpIni -Value $_
    }

    # Replace placeholders
    (Get-Content $phpIni) -replace "{PHP_INSTALL_DIR}", ($phpDir + '/') -replace "{VERSION}", $phpVersionDir | Set-Content $phpIni

    # Install Xdebug if needed
    if ($config.InstallXdebug) {
        $phpXdebug = if ($typeToInstall -eq "NTS") { $phpData.xdebug } else { $phpData.xdebug.Replace("-nts", "") }
        $xdebugPath = Join-Path $phpDirExtract "ext\php_xdebug.dll"
        Copy-Item (Join-Path $tmpDir $phpXdebug) $xdebugPath

        $phpSourceConfigXdebug.$typeConfig | ForEach-Object {
            Add-Content -Path $phpIni -Value $_
        }

        (Get-Content $phpIni) -replace "php_xdebug.dll", $xdebugPath | Set-Content $phpIni
    }

    # Install Composer if needed
    if ($config.InstallComposer) {
        $composerSource = if ([int]$phpVersionDir -ge $composerConfig.MinimumVersion) { 
            $composerConfig.MainPath 
        }
        else { 
            $composerConfig.LtsPath 
        }
        Copy-Item $composerSource (Join-Path $phpDirExtract "composer.phar")
            
        $composerBat = Join-Path $phpDirExtract "composer.bat"
        $composerVerBat = Join-Path $phpDirExtract "composer${phpVersionDir}.bat"
        Copy-Item .\source\composer.bat $composerBat
        Copy-Item .\source\composer.bat $composerVerBat
    }

    # Add to PATH if needed
    if ($config.PhpPathRegister) {
        $registerPath += $phpDirExtract
    }
}

# Apache Installation
if ($config.InstallApache) {
    Write-Output "Install Apache ${apacheDir}"
    if (Test-Path $apacheDir) {
        Remove-Item -Recurse -Force $apacheDir
    }

    $baseApacheName = $env:APACHE_BASE ?? "httpd-2.4.63-250207-win64-VS17.zip"
    $urlApache = "$($baseUrl.APACHE)/$baseApacheName"
    $urlApacheFcgi = $baseUrl.APACHE_FCGI

    $tmpDownloadApache = Join-Path $tmpDir "APACHE.zip"
    $tmpDownloadApacheFcgi = Join-Path $tmpDir "APACHE_FCGI.zip"

    if ($config.DownloadApache) {
        Write-Output "Downloading Apache"
        Download-File $urlApache $tmpDownloadApache
        Download-File $urlApacheFcgi $tmpDownloadApacheFcgi
    }
    else {
        Check-Download $urlApache $tmpDir "APACHE.zip"
        Check-Download $urlApacheFcgi $tmpDir "APACHE_FCGI.zip"
    }

    # Extract Apache
    $dirTmpApache = Join-Path $tmpDir "APACHE"
    if (Test-Path $dirTmpApache) {
        Remove-Item -Recurse -Force $dirTmpApache
    }
    New-Item -ItemType Directory -Path $dirTmpApache | Out-Null
    Expand-Archive -Path $tmpDownloadApache -DestinationPath $dirTmpApache
    
    $dirTmpApacheSub = Get-ChildItem -Path $dirTmpApache -Directory | Select-Object -First 1 -ExpandProperty Name
    Move-Item (Join-Path $dirTmpApache $dirTmpApacheSub) $apacheDir

    # Extract FCGI module
    $dirTmpApacheFcgi = Join-Path $tmpDir "APACHE_FCGI"
    if (Test-Path $dirTmpApacheFcgi) {
        Remove-Item -Recurse -Force $dirTmpApacheFcgi
    }
    New-Item -ItemType Directory -Path $dirTmpApacheFcgi | Out-Null
    Expand-Archive -Path $tmpDownloadApacheFcgi -DestinationPath $dirTmpApacheFcgi
    Move-Item (Join-Path $dirTmpApacheFcgi "mod_fcgid.so") (Join-Path $apacheDir "modules\mod_fcgid.so")

    # Configure Apache
    $httpdConf = Join-Path $apacheDir "conf\httpd.conf"
    Move-Item $httpdConf "$httpdConf.tmp" -Force
    Copy-Item .\source\apache\httpd.conf $httpdConf

    $apacheDirRevert = $apacheDir.Replace("\", "/")
    (Get-Content $httpdConf) -replace "{{ROOT}}", $apacheDirRevert | Set-Content $httpdConf

    # Configure listening ports
    $listenPorts = $whatToInstall | ForEach-Object {
        $version = $_.Trim()
        $alias = $phpSourceVersions.$version.alias
        "Listen 80$alias"
    }
    (Get-Content $httpdConf) -replace "{{LISTEN_PORT}}", ($listenPorts -join "`n") | Set-Content $httpdConf

    # Configure virtual hosts
    $httpdVhostConf = Join-Path $apacheDir "conf\extra\httpd-vhosts.conf"
    Move-Item $httpdVhostConf "$httpdVhostConf.tmp" -Force
    Copy-Item .\source\apache\httpd-vhosts.conf $httpdVhostConf

    $htdocsRevert = $htdocs.Replace("\", "/")
    (Get-Content $httpdVhostConf) -replace "{{HTDOCS}}", $htdocsRevert | Set-Content $httpdVhostConf
    (Get-Content $httpdVhostConf) -replace "{{PHP}}", $phpDir.Replace("\", "/") | Set-Content $httpdVhostConf

    # Copy additional host configurations
    $hostConfDir = Join-Path $apacheDir "conf\extra\host"
    New-Item -ItemType Directory -Path $hostConfDir -Force | Out-Null
    Copy-Item -Path .\source\apache\host\* -Destination $hostConfDir -Recurse

    # Copy utility scripts
    Copy-Item -Path .\source\apache\apacheRegister.ps1 (Join-Path $apacheDir "bin\apacheRegister.ps1")
    Copy-Item -Path .\source\apache\apacheUnistall.ps1 (Join-Path $apacheDir "bin\apacheUnistall.ps1")
    Copy-Item -Path .\source\apache\apacheTest.ps1 (Join-Path $apacheDir "bin\apacheTest.ps1")

    # Add to PATH if needed
    if ($config.ApachePathRegister) {
        $registerPath += (Join-Path $apacheDir "bin")
    }
}

# Nginx Installation
if ($config.InstallNginx) {
    Write-Output "Install Nginx ${nginxDir}"
    if (Test-Path $nginxDir) {
        Remove-Item -Recurse -Force $nginxDir
    }

    $baseNginxName = $env:NGINX_BASE ?? "nginx-1.28.0.zip"
    $urlNginx = "$($baseUrl.NGINX)/$baseNginxName"
    $tmpDownloadNginx = Join-Path $tmpDir $baseNginxName

    if ($config.DownloadNginx) {
        Write-Output "Downloading Nginx"
        Download-File $urlNginx $tmpDownloadNginx
    }
    else {
        Check-Download $urlNginx $tmpDir $baseNginxName
    }

    # Extract Nginx
    $dirTmpNginx = Join-Path $tmpDir "NGINX"
    if (Test-Path $dirTmpNginx) {
        Remove-Item -Recurse -Force $dirTmpNginx
    }
    New-Item -ItemType Directory -Path $dirTmpNginx | Out-Null
    Expand-Archive -Path $tmpDownloadNginx -DestinationPath $dirTmpNginx

    $dirTmpNginxSub = Get-ChildItem -Path $dirTmpNginx -Directory | Select-Object -First 1 -ExpandProperty Name
    Move-Item (Join-Path $dirTmpNginx $dirTmpNginxSub) $nginxDir

    # # Configure Nginx
    $conf = Join-Path $nginxDir "conf\nginx.conf"
    Move-Item $conf "$conf.tmp" -Force
    Copy-Item .\source\nginx\nginx.conf $conf

    $htdocsRevert = $htdocs.Replace("\", "/")
    (Get-Content $conf) -replace "{{HTDOCS}}", $htdocsRevert | Set-Content $conf

    # Copy additional host configurations
    $hostConfDir = Join-Path $nginxDir "conf\server"
    New-Item -ItemType Directory -Path $hostConfDir -Force | Out-Null
    Copy-Item -Path .\source\nginx\server\* -Destination $hostConfDir -Recurse

    # configure runner 
    $nginxRunner = Join-Path $nginxDir "webserver_nginx.bat"
    Copy-Item -Path .\source\nginx\webserver_nginx.bat $nginxRunner
    
    (Get-Content $nginxRunner) -replace "{{ROOT}}", $nginxDir | Set-Content $nginxRunner
    (Get-Content $nginxRunner) -replace "{{PHP_DIR}}", $phpDir | Set-Content $nginxRunner

    # Add to PATH if needed
    if ($config.NginxPathRegister) {
        $registerPath += $nginxDir
    }
}

# Cleanup
if ($config.CleanTmpDir) {
    Remove-Item -Recurse -Force $tmpDir
}

# Register paths
if ($config.PhpPathRegister -or $config.ApachePathRegister -or $config.NginxPathRegister) {
    Register-Path-Web $pathName ($registerPath -join ";")
}