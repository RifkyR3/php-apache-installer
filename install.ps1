. .\01Include.ps1
. .\02Function.ps1

[bool]$installVCRedist = [string]::IsNullOrWhiteSpace($env:INSTALL_VCREDIST) ? 1 : [int]$env:INSTALL_VCREDIST;

[bool]$installPhp = [string]::IsNullOrWhiteSpace($env:INSTALL_PHP) ? 1 : [int]$env:INSTALL_PHP;
[bool]$downloadPhp = [string]::IsNullOrWhiteSpace($env:DOWNLOAD_PHP) ? 1 : [int]$env:DOWNLOAD_PHP;
[bool]$installXdebug = [string]::IsNullOrWhiteSpace($env:INSTALL_XDEBUG) ? 1 : [int]$env:INSTALL_XDEBUG;
[bool]$phpPathRegister = [string]::IsNullOrWhiteSpace($env:REGISTER_PATH_PHP) ? 1 : [int]$env:REGISTER_PATH_PHP;

[bool]$installComposer = [string]::IsNullOrWhiteSpace($env:INSTALL_COMPOSER) ? 1 : [int]$env:INSTALL_COMPOSER;

$basePhpVersion = "v5.4, v5.5, v5.6, v7.0, v7.1, v7.2, v7.3, v7.4, v8.0, v8.1, v8.2, v8.3";
$whatToInstall = [string]::IsNullOrWhiteSpace($env:INSTALL_PHP_VERSION) ? $basePhpVersion : [string]$env:INSTALL_PHP_VERSION;
$whatToInstall = $whatToInstall.Replace('"', '').Replace("'", "").Split(",");

# TS >> Apache with mod_php
# NTS >> IIS and other FastCGI or Apache with mod_fastcgi
# $typeToInstall = "TS";
$typeToInstall = "NTS";

[bool]$installApache = [string]::IsNullOrWhiteSpace($env:INSTALL_APACHE) ? 1 : [int]$env:INSTALL_APACHE;
[bool]$downloadApache = [string]::IsNullOrWhiteSpace($env:DOWNLOAD_APACHE) ? 1 : [int]$env:DOWNLOAD_APACHE;
[bool]$apachePathRegister = [string]::IsNullOrWhiteSpace($env:REGISTER_PATH_APACHE) ? 1 : [int]$env:REGISTER_PATH_APACHE;
$baseApacheName = [string]::IsNullOrWhiteSpace($env:APACHE_BASE) ? "httpd-2.4.59-240605-win64-VS17.zip" : [string]$env:APACHE_BASE;
# install default to current dir
$installDir = Path-Cleaning ${PWD} $env:INSTALL_DIR;

[bool]$cleanTmpDir = [string]::IsNullOrWhiteSpace($env:CLEAN_TMP_DIR) ? 1 : [int]$env:CLEAN_TMP_DIR;

# Variable
$apacheDir = "${installDir}\apache\";
$nginxDir = "${installDir}\nginx\";
$phpDir = "${installDir}\PHP\";
$phpBaseConfig = "php.ini-development";

$htdocs = Path-Cleaning "${apacheDir}htdocs" $env:HTDOCS_DIR;

###################################END MANUAL CONFIG################################################
$pathName = "WEBSERV";
$registerPath = '';

$tmpDir = "${PWD}\tmp\";
if (-not(Test-Path -Path $tmpDir)) {
    Write-Output("Create TMP");
    mkdir $tmpDir
}

# Install VCRedist
if ($installVCRedist -eq 1) {
    Write-Output("Install all VCRedist");
    winget import -i .\source\winget-VCRedist.json --accept-package-agreements --accept-source-agreements --disable-interactivity;
}

$baseUrl = Get-Content .\source\baseUrl.json | Out-String | ConvertFrom-Json;

$baseUrlPhp = $baseUrl.PHP;
$baseUrlPhpRelease = $baseUrl.PHP_RELEASE;
$baseUrlXdebug = $baseUrl.XDEBUG;
$baseUrlComposer = $baseUrl.COMPOSER;
$baseUrlComposerLts = $baseUrl.COMPOSER_LTS;

$phpSourceVersions = Get-Content .\source\php-versions.json | Out-String | ConvertFrom-Json;
$phpSourceConfigExtension = Get-Content .\source\php-config-extension.json | Out-String | ConvertFrom-Json;
$phpSourceConfigBase = Get-Content .\source\php-config-base.json | Out-String | ConvertFrom-Json;
$phpSourceConfigXdebug = Get-Content .\source\php-config-xdebug.json | Out-String | ConvertFrom-Json;

$ProgressPreference = 'SilentlyContinue';

$composer = "composer.phar";
$composerLts = "composer-lts.phar";
$composerMinimumVersion = 72;

$tmpComposer = "${tmpDir}${composer}";
$tmpComposerLts = "${tmpDir}${composerLts}";

if ($installComposer -eq 1) {
    Check-Download $baseUrlComposer $tmpDir $composer;

    Check-Download $baseUrlComposerLts $tmpDir $composerLts;
}

# Install php
if ($installPhp -eq 1) {
    foreach ($version in $whatToInstall) {
        $version = $version.Trim();

        $type = $typeToInstall;
        $phpInstallDir = $phpDir;

        $phpData = $phpSourceVersions.$version;
        
        # Download PHP
        $phpBaseFile = $phpData.name;
        if ($type -ne "NTS") {
            $phpBaseFile = $phpBaseFile.replace("-nts", "");
        }
        if ($phpData.download -eq "release") {
            $url = "${baseUrlPhpRelease}${phpBaseFile}";
        }
        else {
            $url = "${baseUrlPhp}${phpBaseFile}";
        }
        $tmpDownload = "${tmpDir}${phpBaseFile}";

        if ($downloadPhp -eq 1) {
            Write-Output("Download ${phpBaseFile} to ${tmpDir}");
            Download-File $url $tmpDownload
        }
        else{
            Check-Download $url $tmpDir $phpBaseFile;
        }

        # Extract PHP
        $phpVersionDir = $phpData.alias;
        $phpDirExtract = "${phpInstallDir}${phpVersionDir}\";
        
        if (-not(Test-Path -Path $phpDirExtract)) {
            mkdir $phpDirExtract;
        }
        else {
            Remove-Item -Recurse $phpDirExtract;
            mkdir $phpDirExtract;
        }

        Write-Output("Extract ${phpBaseFile} to ${phpDirExtract}");
        Expand-Archive -Path $tmpDownload -DestinationPath $phpDirExtract;

        # Copy Config
        Write-Output("Create Config php.ini");
        $phpIni = "${phpDirExtract}\php.ini";
        Copy-Item "${phpDirExtract}\${phpBaseConfig}" $phpIni;
        Copy-Item "${phpDirExtract}\php.exe" "${phpDirExtract}\php${phpVersionDir}.exe";
        Copy-Item "${phpDirExtract}\php-cgi.exe" "${phpDirExtract}\php${phpVersionDir}-cgi.exe";

        # Config Extension
        $typeConfig = $phpData.config;
        $copyConfig = $phpSourceConfigExtension.$typeConfig;
        foreach ($value in $copyConfig) {
            $search = ";${value}";
            $replace = $value;
                (Get-Content -Path $phpIni) -replace $search, $replace | Set-Content $phpIni;

            $search = "; ${value}";
            $replace = $value;
                (Get-Content -Path $phpIni) -replace $search, $replace | Set-Content $phpIni;
        }

        # Config Add
        $copyConfig = $phpSourceConfigBase.base;
        foreach ($value in $copyConfig) {
            $string = $value;
            Add-Content -Path $phpIni -Value $string;
        }

        $search = "{PHP_INSTALL_DIR}";
        $replace = "${phpInstallDir}";
            (Get-Content -Path $phpIni) -replace $search, $replace | Set-Content $phpIni;

        $search = "{VERSION}";
        $replace = "${phpVersionDir}";
            (Get-Content -Path $phpIni) -replace $search, $replace | Set-Content $phpIni;

        if ($installXdebug -eq 1) {
            $copyConfigXdebug = $phpSourceConfigXdebug.$typeConfig;
            foreach ($value in $copyConfigXdebug) {
                $string = $value;
                Add-Content -Path $phpIni -Value $string;
            }

            # Install Xdebug
            $phpXdebug = $phpData.xdebug;
            if ($type -ne "NTS") {
                $phpXdebug = $phpXdebug.replace("-nts", "");
            }
            $url = "${baseUrlXdebug}${phpXdebug}";
            $tmpDownloadXdebug = "${tmpDir}${phpXdebug}";

            Write-Output("Install ${phpXdebug}");
            Check-Download $url $tmpDir $phpXdebug;
            Copy-Item "${tmpDownloadXdebug}" "${phpDirExtract}\ext\php_xdebug.dll";

            $search = "php_xdebug.dll";
            $replace = "${phpDirExtract}ext\php_xdebug.dll";
                (Get-Content -Path $phpIni) -replace $search, $replace | Set-Content $phpIni;
        }

        if ($installComposer -eq 1) {
            $composerTmpInstalled = [int]$phpVersionDir -ge $composerMinimumVersion ? $tmpComposer : $tmpComposerLts;
            Copy-Item $composerTmpInstalled "${phpDirExtract}\composer.phar";
            
            $composerInstallVer = "${phpDirExtract}\composer${phpVersionDir}.bat";
            Copy-Item .\source\composer.bat $composerInstallVer;

            $composerInstall = "${phpDirExtract}\composer.bat";
            Copy-Item .\source\composer.bat $composerInstall;
        }

        $tmpPath = $registerPath;
        $registerPath = $phpDirExtract + ";" + $tmpPath;
    }
}

# install Apache
if ($installApache -eq 1) {
    if ((Test-Path -Path $apacheDir)) {
        Remove-Item -Recurse $apacheDir;
    }

    $urlApache = $baseUrl.APACHE;
    $urlApache = "${urlApache}/${baseApacheName}";
    $urlApacheFcgi = $baseUrl.APACHE_FCGI;

    $tmpDownload = "${tmpDir}";
    $tmpDownloadApache = "${tmpDownload}/APACHE.zip";
    $tmpDownloadApacheFcgi = "${tmpDownload}/APACHE_FCGI.zip";

    if ($downloadApache -eq 1) {
        Write-Output("Download APACHE");

        Download-File $urlApache $tmpDownloadApache;

        Download-File $urlApacheFcgi $tmpDownloadApacheFcgi
    }
    else {
        Check-Download $urlApache $tmpDownload "APACHE.zip";
        
        Check-Download $urlApacheFcgi $tmpDownload "APACHE_FCGI.zip";
    }

    $dirTmpApache = "${tmpDownload}/APACHE";
    if (-not(Test-Path -Path $dirTmpApache)) {
        mkdir $dirTmpApache;
    }
    else {
        Remove-Item -Recurse $dirTmpApache;
        mkdir $dirTmpApache;
    }
    Expand-Archive -Path $tmpDownloadApache -DestinationPath $dirTmpApache;
    
    $dirTmpApacheSub = Get-ChildItem -Path $dirTmpApache -Directory -Name;
    Move-Item "${dirTmpApache}/${dirTmpApacheSub}" $apacheDir;

    $dirTmpApacheFcgi = "${tmpDownload}/APACHE_FCGI";
    if (-not(Test-Path -Path $dirTmpApacheFcgi)) {
        mkdir $dirTmpApacheFcgi;
    }
    else {
        Remove-Item -Recurse $dirTmpApacheFcgi;
        mkdir $dirTmpApacheFcgi;
    }
    Expand-Archive -Path $tmpDownloadApacheFcgi -DestinationPath $dirTmpApacheFcgi;

    Move-Item "${dirTmpApacheFcgi}/mod_fcgid.so" "${apacheDir}/modules/mod_fcgid.so";

    # Config APACHE
    $httpdConf = "${apacheDir}conf/httpd.conf";
    Move-Item $httpdConf "${httpdConf}.tmp";
    Copy-Item .\source\apache\httpd.conf $httpdConf

    $apacheDirRevert = $apacheDir -replace "\\", '/';
    $search = "{{ROOT}}";
    $replace = $apacheDirRevert;
    (Get-Content -Path $httpdConf) -replace $search, $replace | Set-Content $httpdConf;

    $search = "{{LISTEN_PORT}}";
    $replace = "";
    $modifyFile = $httpdConf;
    foreach ($version in $whatToInstall) {
        $version = $version.Trim();
        $phpData = $phpSourceVersions.$version;
        $alias = $phpData.alias
        $replace = "${replace}`nListen 80${alias}";
    }
    (Get-Content -Path $modifyFile) -replace $search, $replace | Set-Content $modifyFile;

    $httpdVhostConf = "${apacheDir}conf/extra/httpd-vhosts.conf";
    Move-Item $httpdVhostConf "${apacheDir}conf/extra/httpd-vhosts.conf.tmp";
    Copy-Item .\source\apache\httpd-vhosts.conf $httpdVhostConf;

    $search = "{{HTDOCS}}";
    $replace = $htdocs -replace "\\", '/';
    $modifyFile = $httpdVhostConf;
    (Get-Content -Path $modifyFile) -replace $search, $replace | Set-Content $modifyFile;

    $search = "{{PHP}}";
    $replace = $phpDir -replace "\\", '/';
    $modifyFile = $httpdVhostConf;
    (Get-Content -Path $modifyFile) -replace $search, $replace | Set-Content $modifyFile;

    mkdir "${apacheDir}conf/extra/host/";
    Copy-Item -Path .\source\apache\host\* -Destination "${apacheDir}conf/extra/host/" -Recurse;

    Copy-Item -Path .\source\apache\registerApache.ps1 "${apacheDir}\bin\registerApache.ps1";
    Copy-Item -Path .\source\apache\unistallAPache.ps1 "${apacheDir}\bin\unistallAPache.ps1";

    if ($apachePathRegister) {
        $tmpPath = $registerPath;
        $registerPath = $apacheDir + "bin;" + $tmpPath;
    }
}

if ($cleanTmpDir -eq 1) {
    Remove-Item -Recurse $tmpDir; 
} 

if ($phpPathRegister -or $apachePathRegister) {
    Register-Path-Web $pathName $registerPath;
}