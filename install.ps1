if (-not(Test-Path -Path .env)) {
    Copy-Item .env.sample .env
}

Get-Content .env | ForEach-Object {
    $name, $value = $_.split('=')
    if ([string]::IsNullOrWhiteSpace($name) || $name.Contains('#')) {
        # do nothing
    }
    else {
        Set-Content env:\$name $value
    }
}

[bool]$installVCRedist = [string]::IsNullOrWhiteSpace($env:INSTALL_VCREDIST) ? 1 : [int]$env:INSTALL_VCREDIST;

[bool]$installPhp = [string]::IsNullOrWhiteSpace($env:INSTALL_PHP) ? 1 : [int]$env:INSTALL_PHP;
[bool]$downloadPhp = [string]::IsNullOrWhiteSpace($env:DOWNLOAD_PHP) ? 1 : [int]$env:DOWNLOAD_PHP;
[bool]$installXdebug = [string]::IsNullOrWhiteSpace($env:INSTALL_XDEBUG) ? 1 : [int]$env:INSTALL_XDEBUG;
[bool]$phpPathGenerate = [string]::IsNullOrWhiteSpace($env:GENERATE_PATH_PHP) ? 1 : [int]$env:GENERATE_PATH_PHP;

[bool]$installComposer = [string]::IsNullOrWhiteSpace($env:INSTALL_COMPOSER) ? 1 : [int]$env:INSTALL_COMPOSER;

$whatToInstall = [string]::IsNullOrWhiteSpace($env:INSTALL_PHP_VERSION) ? "v5.4, v5.5, v5.6, v7.0, v7.1, v7.2, v7.3, v7.4, v8.0, v8.1, v8.2, v8.3" : [string]$env:INSTALL_PHP_VERSION;
$whatToInstall = $whatToInstall.Replace('"', '').Replace("'", "").Split(",");

# TS >> Apache with mod_php
# NTS >> IIS and other FastCGI or Apache with mod_fastcgi
# $typeToInstall = "TS";
$typeToInstall = "NTS";

[bool]$installApache = [string]::IsNullOrWhiteSpace($env:INSTALL_APACHE) ? 1 : [int]$env:INSTALL_APACHE;
[bool]$downloadApache = [string]::IsNullOrWhiteSpace($env:DOWNLOAD_APACHE) ? 1 : [int]$env:DOWNLOAD_APACHE;

# install default to current dir
$installDir = [string]::IsNullOrWhiteSpace($env:INSTALL_DIR) ? ${PWD} : [string]$env:INSTALL_DIR;
$installDir = $installDir.Replace("/", "\").Split("\");
$installDir[0] = $installDir[0] -eq "." ? ${PWD} : $installDir[0];
$installDir = $installDir -join "\";

[bool]$cleanTmpDir = [string]::IsNullOrWhiteSpace($env:CLEAN_TMP_DIR) ? 1 : [int]$env:CLEAN_TMP_DIR;

# Variable
$apacheDir = "${installDir}\apache\";
$nginxDir = "${installDir}\nginx\";
$phpDir = "${installDir}\PHP\";
$phpBaseConfig = "php.ini-development";

$htdocs = [string]::IsNullOrWhiteSpace($env:HTDOCS_DIR) ? "${installDir}\apache\htdocs" : [string]$env:HTDOCS_DIR;
$htdocs = $htdocs.Replace("/", "\").Split("\");
$htdocs[0] = $htdocs[0] -eq "." ? ${PWD} : $htdocs[0];
$htdocs = $htdocs -join "\";

###################################END MANUAL CONFIG################################################
$phpPath = '';

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
    Invoke-WebRequest -Uri $baseUrlComposer -OutFile $tmpComposer;
    Invoke-WebRequest -Uri $baseUrlComposerLts -OutFile $tmpComposerLts;
}

# Install php
if ($installPhp -eq 1) {
    foreach ($version in $whatToInstall) {
        $version = $version.Trim();

        $type = $typeToInstall;
        $phpInstallDir = $phpDir;

        $phpData = $phpSourceVersions.$type.$version;
        
        # Download PHP
        $phpBaseFile = $phpData.name;
        if ($phpData.download -eq "release") {
            $url = "${baseUrlPhpRelease}${phpBaseFile}";
        }
        else {
            $url = "${baseUrlPhp}${phpBaseFile}";
        }
        $tmpDownload = "${tmpDir}${phpBaseFile}";

        if ($downloadPhp -eq 1) {
            Write-Output("Download ${phpBaseFile} to ${tmpDir}");
            Invoke-WebRequest -Uri $url -OutFile $tmpDownload;
        }
        elseif (-not(Test-Path -Path $tmpDownload)) {
            Write-Output("Not Found. Download ${phpBaseFile} to ${tmpDir}");
            Invoke-WebRequest -Uri $url -OutFile $tmpDownload;
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
        Copy-Item "${phpDirExtract}\php.exe" "${phpDirExtract}\php${phpVersionDir}.exe"

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
            $url = "${baseUrlXdebug}${phpXdebug}";
            $tmpDownloadXdebug = "${tmpDir}${phpXdebug}";

            Write-Output("Install ${phpXdebug}");
            if (-not(Test-Path -Path $tmpDownloadXdebug)) {
                Invoke-WebRequest -Uri $url -OutFile $tmpDownloadXdebug;
            }
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

        $tmpPath = $phpPath;
        $phpPath = $phpDirExtract + ";" + $tmpPath;
    }
}

# install Apache
if ($installApache -eq 1) {
    if ((Test-Path -Path $apacheDir)) {
        Remove-Item -Recurse $apacheDir;
    }

    $urlApache = $baseUrl.APACHE;
    $urlApacheFcgi = $baseUrl.APACHE_FCGI;

    $tmpDownload = "${tmpDir}";
    $tmpDownloadApache = "${tmpDownload}/APACHE.zip";
    $tmpDownloadApacheFcgi = "${tmpDownload}/APACHE_FCGI.zip";

    if ($downloadApache -eq 1) {
        Write-Output("Download APACHE");
        # Invoke-WebRequest -Uri $urlApache -OutFile "${tmpDownload}/APACHE.zip";
        # Invoke-WebRequest -Uri $urlApache -OutFile "${tmpDownload}/APACHE_FCGI.zip";

        $WebClient = New-Object System.Net.WebClient;
        $WebClient.DownloadFile($urlApache, $tmpDownloadApache);

        $WebClient = New-Object System.Net.WebClient;
        $WebClient.DownloadFile($urlApacheFcgi, $tmpDownloadApacheFcgi);
    }
    else {
        if (-not(Test-Path -Path $tmpDownloadApache)) {
            Write-Output("Not Found. Download APACHE to ${tmpDownloadApache}");
            $WebClient = New-Object System.Net.WebClient;
            $WebClient.DownloadFile($urlApache, $tmpDownloadApache);
        }
        
        if (-not(Test-Path -Path $tmpDownloadApacheFcgi)) {
            Write-Output("Not Found. Download APACHE FCGI to ${tmpDownloadApacheFcgi}");
            $WebClient = New-Object System.Net.WebClient;
            $WebClient.DownloadFile($urlApacheFcgi, $tmpDownloadApacheFcgi);
        }
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
    Copy-Item .\source\httpd.conf $httpdConf

    $apacheDirRevert = $apacheDir -replace "\\", '/';
    $search = "{{ROOT}}";
    $replace = $apacheDirRevert;
    (Get-Content -Path $httpdConf) -replace $search, $replace | Set-Content $httpdConf;

    $search = "Listen 80";
    $replace = "Listen 80";
    $modifyFile = $httpdConf;
    foreach ($version in $whatToInstall) {
        $version = $version.Trim();
        $phpData = $phpSourceVersions.NTS.$version;
        $alias = $phpData.alias
        $replace = "${replace}`nListen 80${alias}";
    }
    (Get-Content -Path $modifyFile) -replace $search, $replace | Set-Content $modifyFile;

    $httpdVhostConf = "${apacheDir}conf/extra/httpd-vhosts.conf";
    Move-Item $httpdVhostConf "${apacheDir}conf/extra/httpd-vhosts.conf.tmp";
    Copy-Item .\source\httpd-vhosts.conf $httpdVhostConf;

    $search = "{{HTDOCS}}";
    $replace = $htdocs -replace "\\", '/';
    $modifyFile = $httpdVhostConf;
    (Get-Content -Path $modifyFile) -replace $search, $replace | Set-Content $modifyFile;

    $search = "{{PHP}}";
    $replace = $phpDir -replace "\\", '/';
    $modifyFile = $httpdVhostConf;
    (Get-Content -Path $modifyFile) -replace $search, $replace | Set-Content $modifyFile;

    mkdir "${apacheDir}conf/extra/host/";
    Copy-Item -Path .\source\host\* -Destination "${apacheDir}conf/extra/host/" -Recurse;

    Copy-Item -Path .\source\registerApache.ps1 "${apacheDir}\bin\registerApache.ps1";
    Copy-Item -Path .\source\unistallAPache.ps1 "${apacheDir}\bin\unistallAPache.ps1";
}

if ($cleanTmpDir -eq 1) {
    Remove-Item -Recurse $tmpDir; 
}

if ($phpPathGenerate) {
    Write-Output("######################################################################################################");
    Write-Output("Generated PHP Path");
    Write-Output($phpPath);
}