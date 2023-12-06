[bool]$installVCRedist = 1;

[bool]$installPhp = 1;
[bool]$downloadPhp = 1;
[bool]$installXdebug = 1;

$whatToInstall = @(
    "v5.4",
    "v5.5",
    "v5.6",
    "v7.0",
    "v7.1",
    "v7.2",
    "v7.3",
    "v7.4",
    "v8.0",
    "v8.1",
    "v8.2",
    "v8.3"
);

# TS >> Apache with mod_php
# NTS >> IIS and other FastCGI or Apache with mod_fastcgi
$typeToInstall = @(
    # "TS", 
    "NTS"
);

[bool]$installApache = 1;
[bool]$downloadApache = 1;

# install default to current dir
$installDir = ${PWD};
# $installDir = 'D:\Program\web';

[bool]$cleanTmpDir = 0;

# Variable
$apacheDir = "${installDir}\apache\";
$nginxDir = "${installDir}\nginx\";
$phpTSDir = "${installDir}\PHP_TS\";
$phpDir = "${installDir}\PHP\";
$phpBaseConfig = "php.ini-development";

$htdocs = "${installDir}\apache\htdocs";
# $htdocs = "${installDir}\www";

###################################END MANUAL CONFIG################################################
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

$phpSourceVersions = Get-Content .\source\php-versions.json | Out-String | ConvertFrom-Json;
$phpSourceConfigExtension = Get-Content .\source\php-config-extension.json | Out-String | ConvertFrom-Json;
$phpSourceConfigBase = Get-Content .\source\php-config-base.json | Out-String | ConvertFrom-Json;
$phpSourceConfigXdebug = Get-Content .\source\php-config-xdebug.json | Out-String | ConvertFrom-Json;

$ProgressPreference = 'SilentlyContinue';

# Install php
if ($installPhp -eq 1) {
    for ($i = 0; $i -lt $whatToInstall.Count; $i++) {
        $version = $whatToInstall[$i];

        for ($j = 0; $j -lt $typeToInstall.Count; $j++) {
            $type = $typeToInstall[$j];

            $phpInstallDir = $phpDir;
            if ([string]$type -eq 'TS') {
                $phpInstallDir = $phpTSDir
            }

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
            $phpDirExtract = "${phpInstallDir}${phpVersionDir}/";
        
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

            # Config Replace 
            $typeConfig = $phpData.config;
            $findReplace = $phpSourceConfigExtension.$typeConfig;
            foreach ($value in $findReplace) {
                $search = $value[0];
                $replace = $value[1];
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
            
        }
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
    for ($i = 0; $i -lt $whatToInstall.Count; $i++) {
        $version = $whatToInstall[$i];
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

}

if ($cleanTmpDir -eq 1) {
    Remove-Item -Recurse $tmpDir; 
}