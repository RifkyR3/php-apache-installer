#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'shell', 'open', 'htdocs', 'gui', 'menu', 'sync')]
    [string]$Action = 'menu',

    [Parameter(Position = 1)]
    [ValidateSet('apache', 'nginx', 'all', '')]
    [string]$Server = '',

    [string]$PhpVersion = '',
    [int]$Port = 0,
    [switch]$AllPhp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-EnvFile {
    [CmdletBinding()]
    param([string]$EnvPath)

    if (-not (Test-Path -LiteralPath $EnvPath)) { return }

    Get-Content -LiteralPath $EnvPath | ForEach-Object {
        $line = $_.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { return }
        
        $parts = $line.Split('=', 2)
        if ($parts.Count -eq 2) {
            $key = $parts[0].Trim()
            $val = $parts[1].Trim().Trim('"').Trim("'")
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                Set-Content -LiteralPath "env:\$key" -Value $val
            }
        }
    }
}

function Resolve-PathWithDefault {
    param(
        [string]$BaseDir,
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

function Get-AppPaths {
    [CmdletBinding()]
    param(
        [string]$CliPhpVersion = '',
        [int]$CliPort = 0,
        [string]$CliServer = ''
    )

    $scriptRoot = $PSScriptRoot
    $envFile = Join-Path $scriptRoot '.env'
    Import-EnvFile -EnvPath $envFile

    $installDir = Resolve-PathWithDefault -BaseDir $scriptRoot -InputPath $env:INSTALL_DIR -DefaultPath $scriptRoot
    
    # Apache paths
    $apache = Join-Path $installDir 'apache'
    $defaultHtdocs = Join-Path $apache 'htdocs'
    $htdocs = Resolve-PathWithDefault -BaseDir $installDir -InputPath $env:HTDOCS_DIR -DefaultPath $defaultHtdocs

    # Nginx paths
    $nginx = Join-Path $installDir 'nginx'
    $nginxExe = Join-Path $nginx 'nginx.exe'
    $nginxConf = Join-Path $nginx 'conf\nginx.conf'
    $nginxServerConf = Join-Path $nginx 'conf\server'
    $nginxLogs = Join-Path $nginx 'logs'
    $nginxErrorLog = Join-Path $nginx 'logs\error.log'

    # PHP Version resolution
    $rawPhp = if (-not [string]::IsNullOrWhiteSpace($env:DEFAULT_PHP_VERSION)) {
        $env:DEFAULT_PHP_VERSION
    } elseif (-not [string]::IsNullOrWhiteSpace($env:DEFAULT_PHP)) {
        $env:DEFAULT_PHP
    } else {
        '82'
    }
    $envPhp = $rawPhp.ToLower().Replace('v', '').Replace('.', '').Trim()
    $cleanCliPhp = $CliPhpVersion.ToLower().Replace('v', '').Replace('.', '').Trim()
    $activePhp = if (-not [string]::IsNullOrWhiteSpace($cleanCliPhp)) { $cleanCliPhp } else { $envPhp }
    $activePort = if ($CliPort -gt 0) { $CliPort } else { [int]"80$activePhp" }

    # Webserver resolution (apache or nginx)
    $envServer = if (-not [string]::IsNullOrWhiteSpace($env:DEFAULT_WEBSERVER)) {
        $env:DEFAULT_WEBSERVER.ToLower().Trim()
    } else {
        'apache'
    }
    $activeServer = if (-not [string]::IsNullOrWhiteSpace($CliServer)) {
        $CliServer.ToLower().Trim()
    } else {
        $envServer
    }

    return [PSCustomObject]@{
        Root            = $installDir
        ScriptRoot      = $scriptRoot
        Apache          = $apache
        HttpdExe        = Join-Path $apache 'bin\httpd.exe'
        ApacheBin       = Join-Path $apache 'bin'
        Php             = Join-Path $installDir 'PHP'
        Htdocs          = $htdocs
        HttpdConf       = Join-Path $apache 'conf\httpd.conf'
        VhostsConf      = Join-Path $apache 'conf\extra\httpd-vhosts.conf'
        ErrorLog        = Join-Path $apache 'logs\error.log'
        Nginx           = $nginx
        NginxExe        = $nginxExe
        NginxConf       = $nginxConf
        NginxServerConf = $nginxServerConf
        NginxLogs       = $nginxLogs
        NginxErrorLog   = $nginxErrorLog
        HasEnv          = (Test-Path -LiteralPath $envFile)
        HasApache       = (Test-Path -LiteralPath (Join-Path $apache 'bin\httpd.exe'))
        HasNginx        = (Test-Path -LiteralPath $nginxExe)
        DefaultPhp      = $activePhp
        DefaultPort     = $activePort
        DefaultServer   = $activeServer
    }
}

function Sync-PortablePaths {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    $apacheForward = $Paths.Apache.Replace('\', '/')
    $htdocsForward = $Paths.Htdocs.Replace('\', '/')
    $phpForward    = $Paths.Php.Replace('\', '/')

    $changed = $false

    # Sync Apache httpd.conf
    if (Test-Path -LiteralPath $Paths.HttpdConf) {
        $confContent = Get-Content -LiteralPath $Paths.HttpdConf -Raw
        $newConf = $confContent -replace '(?m)^Define\s+SRVROOT\s+.*$', "Define SRVROOT `"$apacheForward`""
        if ($newConf -ne $confContent) {
            Set-Content -LiteralPath $Paths.HttpdConf -Value $newConf -NoNewline
            $changed = $true
        }
    }

    # Sync Apache httpd-vhosts.conf
    if (Test-Path -LiteralPath $Paths.VhostsConf) {
        $vhostContent = Get-Content -LiteralPath $Paths.VhostsConf -Raw
        $newVhost = $vhostContent -replace '(?m)^Define\s+WEBROOT\s+.*$', "Define WEBROOT `"$htdocsForward`""
        $newVhost = $newVhost -replace '(?m)^Define\s+PHPROOT\s+.*$', "Define PHPROOT `"$phpForward`""
        if ($newVhost -ne $vhostContent) {
            Set-Content -LiteralPath $Paths.VhostsConf -Value $newVhost -NoNewline
            $changed = $true
        }
    }

    # Sync Nginx nginx.conf
    if (Test-Path -LiteralPath $Paths.NginxConf) {
        if (-not (Test-Path -LiteralPath $Paths.NginxLogs)) {
            New-Item -ItemType Directory -Path $Paths.NginxLogs -Force | Out-Null
        }
        $nginxContent = Get-Content -LiteralPath $Paths.NginxConf -Raw
        $newNginx = $nginxContent.Replace('{{HTDOCS}}', $htdocsForward)
        $newNginx = $newNginx -replace '(?m)^\s*root\s+.*?;', "    root         $htdocsForward;"
        if ($newNginx -ne $nginxContent) {
            Set-Content -LiteralPath $Paths.NginxConf -Value $newNginx -NoNewline
            $changed = $true
        }
    }

    $sourceDesc = if ($Paths.HasEnv) { "loaded from .env" } else { "using defaults" }
    if ($changed) {
        Write-Host "[SYNC] Configuration paths updated ($sourceDesc):" -ForegroundColor Cyan
    }
    else {
        Write-Host "[SYNC] Configuration paths up-to-date ($sourceDesc):" -ForegroundColor Cyan
    }
    Write-Host "       SRVROOT: $apacheForward" -ForegroundColor DarkGray
    Write-Host "       WEBROOT: $htdocsForward" -ForegroundColor DarkGray
    Write-Host "       PHPROOT: $phpForward" -ForegroundColor DarkGray
    if ($Paths.HasNginx) {
        Write-Host "       NGINX  : $($Paths.Nginx.Replace('\', '/'))" -ForegroundColor DarkGray
    }
}

function Get-ApacheProcesses {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    $procs = @(Get-Process -Name httpd -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @() }

    return @($procs | Where-Object {
        try {
            $_.Path -and ($_.Path -like "*$($Paths.Apache)*")
        }
        catch {
            $true
        }
    })
}

function Get-NginxProcesses {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    $procs = @(Get-Process -Name nginx -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @() }

    return @($procs | Where-Object {
        try {
            -not $_.Path -or ($_.Path -like "*$($Paths.Nginx)*")
        }
        catch {
            $true
        }
    })
}

function Get-PhpProcesses {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    $all = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^php' })
    if ($all.Count -eq 0) { return @() }

    return @($all | Where-Object {
        try {
            -not $_.Path -or ($_.Path -like "*$($Paths.Php)*") -or ($_.ProcessName -in 'php-cgi', 'php-fpm')
        }
        catch {
            $true
        }
    })
}

function Get-PhpCgiDetails {
    [CmdletBinding()]
    param()

    $cgiProcs = @(Get-Process -Name 'php-cgi' -ErrorAction SilentlyContinue)
    if ($cgiProcs.Count -eq 0) {
        return @()
    }

    $results = @()
    try {
        $wmiProcs = @(Get-CimInstance Win32_Process -Filter "Name like 'php-cgi%'" -ErrorAction SilentlyContinue)
        foreach ($p in $wmiProcs) {
            $cmd = [string]$p.CommandLine
            $port = ''
            $ver = ''
            if ($cmd -match '127\.0\.0\.1:(\d+)') {
                $port = $Matches[1]
            }
            if ($cmd -match '[\\/]PHP[\\/](\d+)[\\/]') {
                $ver = $Matches[1]
            }
            $results += [PSCustomObject]@{
                Id          = $p.ProcessId
                ProcessName = $p.Name
                Port        = $port
                Version     = $ver
                CommandLine = $cmd
            }
        }
    }
    catch {
        # Fallback when CIM is not accessible
    }
    return $results
}

function Get-ServerStatus {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    $apacheProcs = @(Get-ApacheProcesses -Paths $Paths)
    $nginxProcs  = @(Get-NginxProcesses -Paths $Paths)
    $phpProcs    = @(Get-PhpProcesses -Paths $Paths)
    $cgiDetails  = @(Get-PhpCgiDetails)

    $apacheRunning = ($apacheProcs.Count -gt 0)
    $nginxRunning  = ($nginxProcs.Count -gt 0)
    $phpRunning    = ($phpProcs.Count -gt 0)

    $apachePids = if ($apacheRunning) { @($apacheProcs | ForEach-Object { $_.Id }) } else { @() }
    $nginxPids  = if ($nginxRunning)  { @($nginxProcs  | ForEach-Object { $_.Id }) } else { @() }
    $phpPids    = if ($phpRunning)    { @($phpProcs    | ForEach-Object { $_.Id }) } else { @() }

    $activeServerDesc = if ($apacheRunning -and $nginxRunning) {
        'Both (Port conflict risk!)'
    } elseif ($apacheRunning) {
        'Apache'
    } elseif ($nginxRunning) {
        'Nginx'
    } else {
        'None'
    }

    return [PSCustomObject]@{
        ApacheRunning = $apacheRunning
        ApacheProcs   = $apacheProcs
        ApachePids    = $apachePids
        NginxRunning  = $nginxRunning
        NginxProcs    = $nginxProcs
        NginxPids     = $nginxPids
        PhpRunning    = $phpRunning
        PhpProcs      = $phpProcs
        PhpPids       = $phpPids
        PhpCgiDetails = $cgiDetails
        ActiveServer  = $activeServerDesc
        IsRunning     = ($apacheRunning -or $nginxRunning)
    }
}

function Start-PhpCgiProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PhpDir,
        [Parameter(Mandatory = $true)][string]$VersionAlias,
        [int]$FastCgiPort = 0
    )

    if ($FastCgiPort -le 0) {
        $FastCgiPort = [int]"91$VersionAlias"
    }

    $cgiExe = Join-Path $PhpDir 'php-cgi.exe'
    $iniFile = Join-Path $PhpDir 'php.ini'

    if (-not (Test-Path -LiteralPath $cgiExe)) {
        Write-Host "  [WARN] php-cgi.exe not found for PHP $VersionAlias at $cgiExe" -ForegroundColor Yellow
        return $false
    }

    # Check if a process is already bound to this FastCGI port
    $existing = Get-PhpCgiDetails | Where-Object { $_.Port -eq "$FastCgiPort" }
    if ($existing) {
        Write-Host "  [INFO] PHP $VersionAlias FastCGI already running on 127.0.0.1:$FastCgiPort (PID: $($existing.Id -join ', '))" -ForegroundColor DarkGray
        return $true
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cgiExe
    $psi.Arguments = "-b 127.0.0.1:$FastCgiPort -c `"$iniFile`""
    $psi.WorkingDirectory = $PhpDir
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    # Prevent Windows FastCGI termination after 500 requests
    $psi.EnvironmentVariables['PHP_FCGI_MAX_REQUESTS'] = '10000'

    try {
        [void][System.Diagnostics.Process]::Start($psi)
        Write-Host "  [OK] Spawned PHP $VersionAlias FastCGI on 127.0.0.1:$FastCgiPort" -ForegroundColor DarkCyan
        return $true
    }
    catch {
        Write-Host "  [FAIL] Failed to start PHP $VersionAlias FastCGI: $_" -ForegroundColor Red
        return $false
    }
}

function Start-ApacheServer {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    Sync-PortablePaths -Paths $Paths

    $status = Get-ServerStatus -Paths $Paths
    if ($status.ApacheRunning) {
        Write-Host "[WARN] Apache is already running (PID: $($status.ApachePids -join ', '))" -ForegroundColor Yellow
        return
    }

    # Mutual exclusivity guard: Stop Nginx if running to avoid port conflicts
    if ($status.NginxRunning) {
        Write-Host "[WARN] Nginx is currently running. Stopping Nginx to prevent port collisions..." -ForegroundColor Yellow
        Stop-NginxServer -Paths $Paths
        Start-Sleep -Milliseconds 500
    }

    if (-not (Test-Path -LiteralPath $Paths.HttpdExe)) {
        Write-Error "httpd.exe not found at $($Paths.HttpdExe)"
        return
    }

    # Verify config syntax first
    $testResult = & $Paths.HttpdExe -t 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] Apache config test failed: $testResult" -ForegroundColor Red
        return
    }

    Write-Host "[START] Starting Apache Web Server..." -ForegroundColor Cyan
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Paths.HttpdExe
    $psi.WorkingDirectory = $Paths.ApacheBin
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($psi)

    Start-Sleep -Milliseconds 800
    $check = Get-ServerStatus -Paths $Paths
    if ($check.ApacheRunning) {
        Write-Host "[OK] Apache running successfully! (PID: $($check.ApachePids -join ', '))" -ForegroundColor Green
        Write-Host "     Dashboard: http://localhost:$($Paths.DefaultPort)" -ForegroundColor DarkCyan
    }
    else {
        Write-Host "[FAIL] Apache failed to start." -ForegroundColor Red
        if (Test-Path -LiteralPath $Paths.ErrorLog) {
            Write-Host "--- Last 5 error lines ---" -ForegroundColor DarkGray
            Get-Content -LiteralPath $Paths.ErrorLog -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
    }
}

function Stop-ApacheServer {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    $status = Get-ServerStatus -Paths $Paths
    if (-not $status.ApacheRunning) {
        Write-Host "[INFO] Apache is not running." -ForegroundColor Yellow
        return
    }

    Write-Host "[STOP] Stopping Apache..." -ForegroundColor Cyan
    $status.ApacheProcs | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 400
    $check = Get-ServerStatus -Paths $Paths
    if (-not $check.ApacheRunning) {
        Write-Host "[OK] Apache stopped." -ForegroundColor Green
    }
    else {
        Write-Host "[WARN] Apache still terminating (PID: $($check.ApachePids -join ', '))" -ForegroundColor Yellow
    }
}

function Start-NginxServer {
    [CmdletBinding()]
    param(
        [PSCustomObject]$Paths,
        [string]$TargetPhp = '',
        [switch]$StartAllPhp
    )

    Sync-PortablePaths -Paths $Paths

    $status = Get-ServerStatus -Paths $Paths
    if ($status.NginxRunning) {
        Write-Host "[WARN] Nginx is already running (PID: $($status.NginxPids -join ', '))" -ForegroundColor Yellow
        return
    }

    # Mutual exclusivity guard: Stop Apache if running to avoid port collisions
    if ($status.ApacheRunning) {
        Write-Host "[WARN] Apache is currently running. Stopping Apache to prevent port collisions..." -ForegroundColor Yellow
        Stop-ApacheServer -Paths $Paths
        Start-Sleep -Milliseconds 500
    }

    if (-not (Test-Path -LiteralPath $Paths.NginxExe)) {
        Write-Error "nginx.exe not found at $($Paths.NginxExe). Please install Nginx via install.ps1 first."
        return
    }

    # Ensure logs directory exists
    if (-not (Test-Path -LiteralPath $Paths.NginxLogs)) {
        New-Item -ItemType Directory -Path $Paths.NginxLogs -Force | Out-Null
    }

    # Verify Nginx configuration syntax
    Push-Location $Paths.Nginx
    try {
        $testResult = & $Paths.NginxExe -t 2>&1
    }
    finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] Nginx config test failed: $testResult" -ForegroundColor Red
        return
    }

    # Start PHP-CGI FastCGI processes
    Write-Host "[START] Launching PHP-CGI FastCGI daemon(s)..." -ForegroundColor Cyan
    $activeVer = if (-not [string]::IsNullOrWhiteSpace($TargetPhp)) {
        $TargetPhp.ToLower().Replace('v', '').Replace('.', '').Trim()
    } else {
        $Paths.DefaultPhp
    }

    if ($StartAllPhp) {
        $phpFolders = @(Get-ChildItem -LiteralPath $Paths.Php -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' })
        if ($phpFolders.Count -eq 0) {
            Write-Host "[WARN] No PHP versions found in $($Paths.Php)" -ForegroundColor Yellow
        }
        foreach ($dir in $phpFolders) {
            $verAlias = $dir.Name
            $phpPath = $dir.FullName
            [void](Start-PhpCgiProcess -PhpDir $phpPath -VersionAlias $verAlias)
        }
    }
    else {
        $phpPath = Join-Path $Paths.Php $activeVer
        if (Test-Path -LiteralPath $phpPath) {
            [void](Start-PhpCgiProcess -PhpDir $phpPath -VersionAlias $activeVer)
        }
        else {
            Write-Host "[WARN] PHP $activeVer folder not found at $phpPath" -ForegroundColor Yellow
        }
    }

    # Start Nginx daemon
    Write-Host "[START] Starting Nginx Web Server..." -ForegroundColor Cyan
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Paths.NginxExe
    $psi.WorkingDirectory = $Paths.Nginx
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($psi)

    Start-Sleep -Milliseconds 1000
    $check = Get-ServerStatus -Paths $Paths
    if ($check.NginxRunning) {
        Write-Host "[OK] Nginx running successfully! (PID: $($check.NginxPids -join ', '))" -ForegroundColor Green
        Write-Host "     Dashboard: http://localhost:$($Paths.DefaultPort)" -ForegroundColor DarkCyan
    }
    else {
        Write-Host "[FAIL] Nginx failed to start." -ForegroundColor Red
        if (Test-Path -LiteralPath $Paths.NginxErrorLog) {
            Write-Host "--- Last 5 error lines ---" -ForegroundColor DarkGray
            Get-Content -LiteralPath $Paths.NginxErrorLog -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
    }
}

function Stop-NginxServer {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    $status = Get-ServerStatus -Paths $Paths
    $hasNginx = $status.NginxRunning
    $hasPhp = $status.PhpRunning

    if (-not $hasNginx -and -not $hasPhp) {
        Write-Host "[INFO] Nginx and PHP processes are not running." -ForegroundColor Yellow
        return
    }

    if ($hasNginx) {
        Write-Host "[STOP] Stopping Nginx..." -ForegroundColor Cyan
        # Attempt graceful stop via nginx -s stop
        if (Test-Path -LiteralPath $Paths.NginxExe) {
            Push-Location $Paths.Nginx
            try {
                & $Paths.NginxExe -s stop 2>$null
            }
            finally {
                Pop-Location
            }
            Start-Sleep -Milliseconds 400
        }
        # Terminate any remaining nginx processes
        $status.NginxProcs | ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }

    if ($hasPhp) {
        $phpNames = ($status.PhpProcs.Name | Select-Object -Unique) -join ', '
        Write-Host "[STOP] Stopping PHP FastCGI processes ($phpNames)..." -ForegroundColor Cyan
        $status.PhpProcs | ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Milliseconds 500
    $check = Get-ServerStatus -Paths $Paths
    if (-not $check.NginxRunning -and -not $check.PhpRunning) {
        Write-Host "[OK] Nginx and PHP processes stopped." -ForegroundColor Green
    }
    else {
        if ($check.NginxRunning) {
            Write-Host "[WARN] Nginx still terminating (PID: $($check.NginxPids -join ', '))" -ForegroundColor Yellow
        }
        if ($check.PhpRunning) {
            Write-Host "[WARN] PHP still terminating (PID: $($check.PhpPids -join ', '))" -ForegroundColor Yellow
        }
    }
}

function Start-WebServer {
    [CmdletBinding()]
    param(
        [PSCustomObject]$Paths,
        [string]$TargetServer = '',
        [switch]$StartAllPhp
    )

    $srv = if (-not [string]::IsNullOrWhiteSpace($TargetServer)) { $TargetServer.ToLower() } else { $Paths.DefaultServer }

    if ($srv -eq 'nginx') {
        Start-NginxServer -Paths $Paths -TargetPhp $Paths.DefaultPhp -StartAllPhp:$StartAllPhp
    }
    else {
        Start-ApacheServer -Paths $Paths
    }
}

function Stop-WebServer {
    [CmdletBinding()]
    param(
        [PSCustomObject]$Paths,
        [string]$TargetServer = 'all'
    )

    $srv = if (-not [string]::IsNullOrWhiteSpace($TargetServer)) { $TargetServer.ToLower() } else { 'all' }

    if ($srv -eq 'apache') {
        Stop-ApacheServer -Paths $Paths
    }
    elseif ($srv -eq 'nginx') {
        Stop-NginxServer -Paths $Paths
    }
    else {
        Stop-ApacheServer -Paths $Paths
        Stop-NginxServer -Paths $Paths
    }
}

function Restart-WebServer {
    [CmdletBinding()]
    param(
        [PSCustomObject]$Paths,
        [string]$TargetServer = '',
        [switch]$StartAllPhp
    )

    $status = Get-ServerStatus -Paths $Paths
    $srv = if (-not [string]::IsNullOrWhiteSpace($TargetServer)) {
        $TargetServer.ToLower()
    } elseif ($status.NginxRunning) {
        'nginx'
    } else {
        $Paths.DefaultServer
    }

    Stop-WebServer -Paths $Paths -TargetServer $srv
    Start-Sleep -Milliseconds 400
    Start-WebServer -Paths $Paths -TargetServer $srv -StartAllPhp:$StartAllPhp
}

function Start-PortableShell {
    [CmdletBinding()]
    param(
        [PSCustomObject]$Paths,
        [string]$Version = ''
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = $Paths.DefaultPhp
    }
    else {
        $Version = $Version.ToLower().Replace('v', '').Replace('.', '').Trim()
    }

    $targetPhp = Join-Path $Paths.Php $Version
    if (-not (Test-Path -LiteralPath $targetPhp)) {
        $available = Get-ChildItem -LiteralPath $Paths.Php -Directory | Select-Object -ExpandProperty Name
        Write-Host "[WARN] PHP $Version not found. Available: $($available -join ', ')" -ForegroundColor Yellow
        $Version = $Paths.DefaultPhp
        $targetPhp = Join-Path $Paths.Php $Version
    }

    Write-Host "[SHELL] Launching portable shell with PHP $Version..." -ForegroundColor Cyan

    $shellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    $initScript = @"
`$env:PATH = '$targetPhp;$($Paths.ApacheBin);$($Paths.Nginx);' + `$env:PATH
`$env:PHPRC = '$targetPhp'
`$host.UI.RawUI.WindowTitle = 'Portable Web Shell [PHP $Version]'
Clear-Host
Write-Host '===================================================' -ForegroundColor Cyan
Write-Host ' Portable Web Shell (Session isolated)' -ForegroundColor White
Write-Host ' PHP Version : ' -NoNewline; php -v | Select-Object -First 1
Write-Host ' Composer    : ' -NoNewline; if (Test-Path '$targetPhp\composer.bat') { & '$targetPhp\composer.bat' --version } else { Write-Host 'None' }
Write-Host ' DocumentRoot: $($Paths.Htdocs)' -ForegroundColor DarkGray
Write-Host '===================================================' -ForegroundColor Cyan
"@

    Start-Process -FilePath $shellCmd -ArgumentList "-NoExit", "-NoProfile", "-Command", $initScript
}

function Open-WebBrowser {
    [CmdletBinding()]
    param([int]$TargetPort = 8082)

    $url = "http://localhost:$TargetPort"
    Write-Host "[OPEN] Launching browser: $url" -ForegroundColor Cyan
    Start-Process $url
}

function Open-HtdocsFolder {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    Write-Host "[OPEN] Opening htdocs in File Explorer..." -ForegroundColor Cyan
    Start-Process explorer.exe $Paths.Htdocs
}

function Show-Gui {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Portable Web Controller (Apache & Nginx)"
    $form.Size = New-Object System.Drawing.Size(520, 360)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)

    # Title Banner
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Portable Web Environment"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(15, 12)
    $lblTitle.Size = New-Object System.Drawing.Size(320, 24)
    $form.Controls.Add($lblTitle)

    # Status indicators
    $lblStatusApache = New-Object System.Windows.Forms.Label
    $lblStatusApache.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblStatusApache.Location = New-Object System.Drawing.Point(15, 42)
    $lblStatusApache.Size = New-Object System.Drawing.Size(470, 20)
    $form.Controls.Add($lblStatusApache)

    $lblStatusNginx = New-Object System.Windows.Forms.Label
    $lblStatusNginx.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblStatusNginx.Location = New-Object System.Drawing.Point(15, 64)
    $lblStatusNginx.Size = New-Object System.Drawing.Size(470, 20)
    $form.Controls.Add($lblStatusNginx)

    $lblStatusPhp = New-Object System.Windows.Forms.Label
    $lblStatusPhp.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $lblStatusPhp.Location = New-Object System.Drawing.Point(15, 86)
    $lblStatusPhp.Size = New-Object System.Drawing.Size(470, 20)
    $form.Controls.Add($lblStatusPhp)

    # --- Apache Controls ---
    $grpApache = New-Object System.Windows.Forms.GroupBox
    $grpApache.Text = "Apache HTTPD"
    $grpApache.Location = New-Object System.Drawing.Point(15, 112)
    $grpApache.Size = New-Object System.Drawing.Size(475, 62)
    $grpApache.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($grpApache)

    $btnApacheToggle = New-Object System.Windows.Forms.Button
    $btnApacheToggle.Location = New-Object System.Drawing.Point(15, 20)
    $btnApacheToggle.Size = New-Object System.Drawing.Size(130, 30)
    $btnApacheToggle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $grpApache.Controls.Add($btnApacheToggle)

    $btnApacheRestart = New-Object System.Windows.Forms.Button
    $btnApacheRestart.Text = "Restart Apache"
    $btnApacheRestart.Location = New-Object System.Drawing.Point(155, 20)
    $btnApacheRestart.Size = New-Object System.Drawing.Size(120, 30)
    $btnApacheRestart.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $grpApache.Controls.Add($btnApacheRestart)

    # --- Nginx Controls ---
    $grpNginx = New-Object System.Windows.Forms.GroupBox
    $grpNginx.Text = "Nginx & PHP FastCGI"
    $grpNginx.Location = New-Object System.Drawing.Point(15, 180)
    $grpNginx.Size = New-Object System.Drawing.Size(475, 62)
    $grpNginx.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($grpNginx)

    $btnNginxToggle = New-Object System.Windows.Forms.Button
    $btnNginxToggle.Location = New-Object System.Drawing.Point(15, 20)
    $btnNginxToggle.Size = New-Object System.Drawing.Size(130, 30)
    $btnNginxToggle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $grpNginx.Controls.Add($btnNginxToggle)

    $btnNginxAllPhp = New-Object System.Windows.Forms.Button
    $btnNginxAllPhp.Text = "Start All PHP"
    $btnNginxAllPhp.Location = New-Object System.Drawing.Point(155, 20)
    $btnNginxAllPhp.Size = New-Object System.Drawing.Size(110, 30)
    $btnNginxAllPhp.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $grpNginx.Controls.Add($btnNginxAllPhp)

    $btnNginxRestart = New-Object System.Windows.Forms.Button
    $btnNginxRestart.Text = "Restart Nginx"
    $btnNginxRestart.Location = New-Object System.Drawing.Point(275, 20)
    $btnNginxRestart.Size = New-Object System.Drawing.Size(110, 30)
    $btnNginxRestart.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $grpNginx.Controls.Add($btnNginxRestart)

    # --- Utilities ---
    $btnAdmin = New-Object System.Windows.Forms.Button
    $btnAdmin.Text = "Browser"
    $btnAdmin.Size = New-Object System.Drawing.Size(85, 30)
    $btnAdmin.Location = New-Object System.Drawing.Point(15, 252)
    $btnAdmin.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($btnAdmin)

    $btnExplorer = New-Object System.Windows.Forms.Button
    $btnExplorer.Text = "Explorer"
    $btnExplorer.Size = New-Object System.Drawing.Size(85, 30)
    $btnExplorer.Location = New-Object System.Drawing.Point(108, 252)
    $btnExplorer.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($btnExplorer)

    $btnShell = New-Object System.Windows.Forms.Button
    $btnShell.Text = "Shell (PHP $($Paths.DefaultPhp))"
    $btnShell.Size = New-Object System.Drawing.Size(125, 30)
    $btnShell.Location = New-Object System.Drawing.Point(201, 252)
    $btnShell.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($btnShell)

    $btnSync = New-Object System.Windows.Forms.Button
    $btnSync.Text = "Sync Paths"
    $btnSync.Size = New-Object System.Drawing.Size(90, 30)
    $btnSync.Location = New-Object System.Drawing.Point(334, 252)
    $btnSync.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($btnSync)

    # Path info label
    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = "Root: $($Paths.Root) | Active PHP: $($Paths.DefaultPhp) | Web: $($Paths.DefaultServer)"
    $lblPath.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblPath.ForeColor = [System.Drawing.Color]::Gray
    $lblPath.Location = New-Object System.Drawing.Point(15, 292)
    $lblPath.Size = New-Object System.Drawing.Size(475, 20)
    $form.Controls.Add($lblPath)

    $updateStatusUI = {
        $st = Get-ServerStatus -Paths $Paths
        
        # Apache status update
        if ($st.ApacheRunning) {
            $lblStatusApache.Text = "Apache: RUNNING (PID: $($st.ApachePids -join ', '))"
            $lblStatusApache.ForeColor = [System.Drawing.Color]::DarkGreen
            $btnApacheToggle.Text = "Stop Apache"
            $btnApacheRestart.Enabled = $true
        }
        else {
            $lblStatusApache.Text = "Apache: STOPPED"
            $lblStatusApache.ForeColor = [System.Drawing.Color]::Firebrick
            $btnApacheToggle.Text = "Start Apache"
            $btnApacheRestart.Enabled = $false
        }

        # Nginx status update
        if ($st.NginxRunning) {
            $lblStatusNginx.Text = "Nginx: RUNNING (PID: $($st.NginxPids -join ', '))"
            $lblStatusNginx.ForeColor = [System.Drawing.Color]::DarkGreen
            $btnNginxToggle.Text = "Stop Nginx"
            $btnNginxRestart.Enabled = $true
            $btnNginxAllPhp.Enabled = $false
        }
        else {
            $lblStatusNginx.Text = "Nginx: STOPPED"
            $lblStatusNginx.ForeColor = [System.Drawing.Color]::Firebrick
            $btnNginxToggle.Text = "Start Nginx"
            $btnNginxRestart.Enabled = $false
            $btnNginxAllPhp.Enabled = $true
        }

        # PHP status update
        if ($st.PhpRunning) {
            $ports = @($st.PhpCgiDetails | Where-Object { $_.Port } | ForEach-Object { "$($_.Version):$($_.Port)" })
            $portInfo = if ($ports.Count -gt 0) { " [Ports: $($ports -join ', ')]" } else { "" }
            $lblStatusPhp.Text = "PHP FastCGI: RUNNING ($($st.PhpProcs.Count) procs)$portInfo"
            $lblStatusPhp.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        else {
            $lblStatusPhp.Text = "PHP FastCGI: STOPPED"
            $lblStatusPhp.ForeColor = [System.Drawing.Color]::Gray
        }
    }

    $btnApacheToggle.Add_Click({
        $st = Get-ServerStatus -Paths $Paths
        if ($st.ApacheRunning) {
            Stop-ApacheServer -Paths $Paths
        }
        else {
            Start-ApacheServer -Paths $Paths
        }
        & $updateStatusUI
    })

    $btnApacheRestart.Add_Click({
        Stop-ApacheServer -Paths $Paths
        Start-Sleep -Milliseconds 400
        Start-ApacheServer -Paths $Paths
        & $updateStatusUI
    })

    $btnNginxToggle.Add_Click({
        $st = Get-ServerStatus -Paths $Paths
        if ($st.NginxRunning -or $st.PhpRunning) {
            Stop-NginxServer -Paths $Paths
        }
        else {
            Start-NginxServer -Paths $Paths
        }
        & $updateStatusUI
    })

    $btnNginxAllPhp.Add_Click({
        Start-NginxServer -Paths $Paths -StartAllPhp
        & $updateStatusUI
    })

    $btnNginxRestart.Add_Click({
        Stop-NginxServer -Paths $Paths
        Start-Sleep -Milliseconds 400
        Start-NginxServer -Paths $Paths
        & $updateStatusUI
    })

    $btnAdmin.Add_Click({
        Open-WebBrowser -TargetPort $Paths.DefaultPort
    })

    $btnExplorer.Add_Click({
        Open-HtdocsFolder -Paths $Paths
    })

    $btnShell.Add_Click({
        Start-PortableShell -Paths $Paths -Version $Paths.DefaultPhp
    })

    $btnSync.Add_Click({
        $script:paths = Get-AppPaths
        Sync-PortablePaths -Paths $script:paths
        & $updateStatusUI
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2000
    $timer.Add_Tick({ & $updateStatusUI })
    $timer.Start()

    $form.Add_Shown({ & $updateStatusUI })
    $form.Add_FormClosed({ $timer.Stop() })

    [void]$form.ShowDialog()
}

function Show-InteractiveMenu {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    Sync-PortablePaths -Paths $Paths

    while ($true) {
        $st = Get-ServerStatus -Paths $Paths
        
        $apacheText  = if ($st.ApacheRunning) { "[RUNNING] (PID: $($st.ApachePids -join ', '))" } else { "[STOPPED]" }
        $apacheColor = if ($st.ApacheRunning) { 'Green' } else { 'Red' }
        
        $nginxText   = if ($st.NginxRunning) { "[RUNNING] (PID: $($st.NginxPids -join ', '))" } else { "[STOPPED]" }
        $nginxColor  = if ($st.NginxRunning) { 'Green' } else { 'Red' }

        $cgiDetails  = $st.PhpCgiDetails
        $portList    = @($cgiDetails | Where-Object { $_.Port } | ForEach-Object { "$($_.Version):$($_.Port)" })
        $portDesc    = if ($portList.Count -gt 0) { " [Ports: $($portList -join ', ')]" } else { "" }
        $phpText     = if ($st.PhpRunning) { "[RUNNING] ($($st.PhpProcs.Count) procs)$portDesc" } else { "[STOPPED]" }
        $phpColor    = if ($st.PhpRunning) { 'Green' } else { 'DarkGray' }

        Clear-Host
        Write-Host "===================================================" -ForegroundColor Cyan
        Write-Host " Portable Web Controller (Apache & Nginx)" -ForegroundColor White
        Write-Host " Root  : $($Paths.Root)" -ForegroundColor DarkGray
        Write-Host " Htdocs: $($Paths.Htdocs)" -ForegroundColor DarkGray
        Write-Host " PHP   : PHP $($Paths.DefaultPhp) (Port $($Paths.DefaultPort) / FastCGI 91$($Paths.DefaultPhp))" -ForegroundColor DarkGray
        Write-Host " Apache Status : " -NoNewline
        Write-Host $apacheText -ForegroundColor $apacheColor
        Write-Host " Nginx Status  : " -NoNewline
        Write-Host $nginxText -ForegroundColor $nginxColor
        Write-Host " PHP FastCGI   : " -NoNewline
        Write-Host $phpText -ForegroundColor $phpColor
        Write-Host "===================================================" -ForegroundColor Cyan
        Write-Host " Web Server Controls:" -ForegroundColor Yellow
        Write-Host " [1] Start Apache"
        Write-Host " [2] Stop Apache"
        Write-Host " [3] Start Nginx + PHP-CGI (Active PHP $($Paths.DefaultPhp))"
        Write-Host " [4] Start Nginx + All PHP Versions"
        Write-Host " [5] Stop Nginx & PHP FastCGI"
        Write-Host " [6] Stop All (Apache, Nginx, PHP)"
        Write-Host " [7] Restart Running Web Server"
        Write-Host ""
        Write-Host " Utilities & Tools:" -ForegroundColor Yellow
        Write-Host " [8] Refresh Status"
        Write-Host " [9] Open Browser (Dashboard localhost:$($Paths.DefaultPort))"
        Write-Host " [10] Open Htdocs in Explorer"
        Write-Host " [11] Launch Portable Shell (PHP $($Paths.DefaultPhp))"
        Write-Host " [12] Sync Paths (.env)"
        Write-Host " [13] Launch GUI Control Panel"
        Write-Host " [0] Exit"
        Write-Host "---------------------------------------------------" -ForegroundColor DarkGray

        $choice = Read-Host "Select option [0-13]"
        switch ($choice) {
            '1'  { Start-ApacheServer -Paths $Paths; Start-Sleep -Seconds 1 }
            '2'  { Stop-ApacheServer -Paths $Paths; Start-Sleep -Seconds 1 }
            '3'  { Start-NginxServer -Paths $Paths -TargetPhp $Paths.DefaultPhp; Start-Sleep -Seconds 1 }
            '4'  { Start-NginxServer -Paths $Paths -StartAllPhp; Start-Sleep -Seconds 1 }
            '5'  { Stop-NginxServer -Paths $Paths; Start-Sleep -Seconds 1 }
            '6'  { Stop-WebServer -Paths $Paths -TargetServer 'all'; Start-Sleep -Seconds 1 }
            '7'  { Restart-WebServer -Paths $Paths; Start-Sleep -Seconds 1 }
            '8'  { }
            '9'  { Open-WebBrowser -TargetPort $Paths.DefaultPort }
            '10' { Open-HtdocsFolder -Paths $Paths }
            '11' { Start-PortableShell -Paths $Paths -Version $Paths.DefaultPhp }
            '12' { $Paths = Get-AppPaths; Sync-PortablePaths -Paths $Paths; Start-Sleep -Seconds 2 }
            '13' { Show-Gui -Paths $Paths }
            '0'  { return }
            default { Write-Host "Invalid choice" -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}

# Entrypoint Execution
$paths = Get-AppPaths -CliPhpVersion $PhpVersion -CliPort $Port -CliServer $Server

switch ($Action.ToLower()) {
    'start'   {
        Start-WebServer -Paths $paths -TargetServer $Server -StartAllPhp:$AllPhp
    }
    'stop'    {
        Stop-WebServer -Paths $paths -TargetServer $Server
    }
    'restart' {
        Restart-WebServer -Paths $paths -TargetServer $Server -StartAllPhp:$AllPhp
    }
    'status'  {
        $st = Get-ServerStatus -Paths $paths
        
        if ($st.ApacheRunning) {
            Write-Host "[STATUS] Apache RUNNING (PID: $($st.ApachePids -join ', '))" -ForegroundColor Green
        }
        else {
            Write-Host "[STATUS] Apache STOPPED" -ForegroundColor Red
        }

        if ($st.NginxRunning) {
            Write-Host "[STATUS] Nginx RUNNING (PID: $($st.NginxPids -join ', '))" -ForegroundColor Green
        }
        else {
            Write-Host "[STATUS] Nginx STOPPED" -ForegroundColor Red
        }

        if ($st.PhpRunning) {
            $ports = @($st.PhpCgiDetails | Where-Object { $_.Port } | ForEach-Object { "$($_.Version):$($_.Port)" })
            $portInfo = if ($ports.Count -gt 0) { " [Ports: $($ports -join ', ')]" } else { "" }
            $names = ($st.PhpProcs.Name | Select-Object -Unique) -join ', '
            Write-Host "[STATUS] PHP FastCGI RUNNING: $names (PID: $($st.PhpPids -join ', '))$portInfo" -ForegroundColor Green
        }
        else {
            Write-Host "[STATUS] PHP FastCGI STOPPED" -ForegroundColor DarkGray
        }
    }
    'shell'   { Start-PortableShell -Paths $paths -Version $paths.DefaultPhp }
    'open'    { Open-WebBrowser -TargetPort $paths.DefaultPort }
    'htdocs'  { Open-HtdocsFolder -Paths $paths }
    'sync'    { Sync-PortablePaths -Paths $paths }
    'gui'     { Show-Gui -Paths $paths }
    'menu'    { Show-InteractiveMenu -Paths $paths }
}
