#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'shell', 'open', 'htdocs', 'gui', 'menu', 'sync')]
    [string]$Action = 'menu',

    [string]$PhpVersion = '',
    [int]$Port = 0
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
        [int]$CliPort = 0
    )

    $scriptRoot = $PSScriptRoot
    $envFile = Join-Path $scriptRoot '.env'
    Import-EnvFile -EnvPath $envFile

    $installDir = Resolve-PathWithDefault -BaseDir $scriptRoot -InputPath $env:INSTALL_DIR -DefaultPath $scriptRoot
    $apache = Join-Path $installDir 'apache'
    $defaultHtdocs = Join-Path $apache 'htdocs'
    $htdocs = Resolve-PathWithDefault -BaseDir $installDir -InputPath $env:HTDOCS_DIR -DefaultPath $defaultHtdocs

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

    return [PSCustomObject]@{
        Root         = $installDir
        ScriptRoot   = $scriptRoot
        Apache       = $apache
        HttpdExe     = Join-Path $apache 'bin\httpd.exe'
        ApacheBin    = Join-Path $apache 'bin'
        Php          = Join-Path $installDir 'PHP'
        Htdocs       = $htdocs
        HttpdConf    = Join-Path $apache 'conf\httpd.conf'
        VhostsConf   = Join-Path $apache 'conf\extra\httpd-vhosts.conf'
        ErrorLog     = Join-Path $apache 'logs\error.log'
        HasEnv       = (Test-Path -LiteralPath $envFile)
        DefaultPhp   = $activePhp
        DefaultPort  = $activePort
    }
}

function Sync-PortablePaths {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    $apacheForward = $Paths.Apache.Replace('\', '/')
    $htdocsForward = $Paths.Htdocs.Replace('\', '/')
    $phpForward    = $Paths.Php.Replace('\', '/')

    $changed = $false

    if (Test-Path -LiteralPath $Paths.HttpdConf) {
        $confContent = Get-Content -LiteralPath $Paths.HttpdConf -Raw
        $newConf = $confContent -replace '(?m)^Define\s+SRVROOT\s+.*$', "Define SRVROOT `"$apacheForward`""
        if ($newConf -ne $confContent) {
            Set-Content -LiteralPath $Paths.HttpdConf -Value $newConf -NoNewline
            $changed = $true
        }
    }

    if (Test-Path -LiteralPath $Paths.VhostsConf) {
        $vhostContent = Get-Content -LiteralPath $Paths.VhostsConf -Raw
        $newVhost = $vhostContent -replace '(?m)^Define\s+WEBROOT\s+.*$', "Define WEBROOT `"$htdocsForward`""
        $newVhost = $newVhost -replace '(?m)^Define\s+PHPROOT\s+.*$', "Define PHPROOT `"$phpForward`""
        if ($newVhost -ne $vhostContent) {
            Set-Content -LiteralPath $Paths.VhostsConf -Value $newVhost -NoNewline
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

function Get-ServerStatus {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    $procs = @(Get-ApacheProcesses -Paths $Paths)
    $phpProcs = @(Get-PhpProcesses -Paths $Paths)
    $isRunning = ($procs.Count -gt 0)
    $pids = if ($isRunning) { @($procs | ForEach-Object { $_.Id }) } else { @() }

    return [PSCustomObject]@{
        IsRunning    = $isRunning
        Processes    = $procs
        Pids         = $pids
        PhpProcesses = $phpProcs
    }
}

function Start-WebServer {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    Sync-PortablePaths -Paths $Paths

    $status = Get-ServerStatus -Paths $Paths
    if ($status.IsRunning) {
        Write-Host "[WARN] Apache is already running (PID: $($status.Pids -join ', '))" -ForegroundColor Yellow
        return
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
    if ($check.IsRunning) {
        Write-Host "[OK] Apache running successfully! (PID: $($check.Pids -join ', '))" -ForegroundColor Green
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

function Stop-WebServer {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    $status = Get-ServerStatus -Paths $Paths
    $hasApache = $status.IsRunning
    $hasPhp = ($status.PhpProcesses.Count -gt 0)

    if (-not $hasApache -and -not $hasPhp) {
        Write-Host "[INFO] Apache and PHP processes are not running." -ForegroundColor Yellow
        return
    }

    if ($hasApache) {
        Write-Host "[STOP] Stopping Apache..." -ForegroundColor Cyan
        $status.Processes | ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }

    if ($hasPhp) {
        $phpNames = ($status.PhpProcesses.Name | Select-Object -Unique) -join ', '
        Write-Host "[STOP] Stopping PHP processes ($phpNames)..." -ForegroundColor Cyan
        $status.PhpProcesses | ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Milliseconds 500
    $check = Get-ServerStatus -Paths $Paths
    if (-not $check.IsRunning -and ($check.PhpProcesses.Count -eq 0)) {
        Write-Host "[OK] Apache and PHP stopped." -ForegroundColor Green
    }
    else {
        if ($check.IsRunning) {
            Write-Host "[WARN] Apache still terminating (PID: $($check.Pids -join ', '))" -ForegroundColor Yellow
        }
        if ($check.PhpProcesses.Count -gt 0) {
            Write-Host "[WARN] PHP still terminating (PID: $($check.PhpProcesses.Id -join ', '))" -ForegroundColor Yellow
        }
    }
}

function Restart-WebServer {
    [CmdletBinding()]
    param([PSCustomObject]$Paths)

    Stop-WebServer -Paths $Paths
    Start-Sleep -Milliseconds 400
    Start-WebServer -Paths $Paths
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
`$env:PATH = '$targetPhp;$($Paths.ApacheBin);' + `$env:PATH
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
    $form.Text = "Portable Web Controller (XAMPP-Style)"
    $form.Size = New-Object System.Drawing.Size(460, 260)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)

    # Title Banner
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Portable Web Environment"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(15, 12)
    $lblTitle.Size = New-Object System.Drawing.Size(280, 24)
    $form.Controls.Add($lblTitle)

    # Status indicator
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblStatus.Location = New-Object System.Drawing.Point(15, 42)
    $lblStatus.Size = New-Object System.Drawing.Size(410, 26)
    $form.Controls.Add($lblStatus)

    # Button: Start/Stop
    $btnToggle = New-Object System.Windows.Forms.Button
    $btnToggle.Size = New-Object System.Drawing.Size(100, 32)
    $btnToggle.Location = New-Object System.Drawing.Point(15, 80)
    $btnToggle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($btnToggle)

    # Button: Restart
    $btnRestart = New-Object System.Windows.Forms.Button
    $btnRestart.Text = "Restart"
    $btnRestart.Size = New-Object System.Drawing.Size(80, 32)
    $btnRestart.Location = New-Object System.Drawing.Point(125, 80)
    $btnRestart.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($btnRestart)

    # Button: Admin / Browser
    $btnAdmin = New-Object System.Windows.Forms.Button
    $btnAdmin.Text = "Browser"
    $btnAdmin.Size = New-Object System.Drawing.Size(80, 32)
    $btnAdmin.Location = New-Object System.Drawing.Point(215, 80)
    $btnAdmin.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($btnAdmin)

    # Button: Explorer
    $btnExplorer = New-Object System.Windows.Forms.Button
    $btnExplorer.Text = "Explorer"
    $btnExplorer.Size = New-Object System.Drawing.Size(80, 32)
    $btnExplorer.Location = New-Object System.Drawing.Point(305, 80)
    $btnExplorer.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($btnExplorer)

    # Button: Shell
    $btnShell = New-Object System.Windows.Forms.Button
    $btnShell.Text = "Shell (PHP $($Paths.DefaultPhp))"
    $btnShell.Size = New-Object System.Drawing.Size(120, 32)
    $btnShell.Location = New-Object System.Drawing.Point(15, 125)
    $btnShell.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($btnShell)

    # Button: Sync
    $btnSync = New-Object System.Windows.Forms.Button
    $btnSync.Text = "Sync (.env)"
    $btnSync.Size = New-Object System.Drawing.Size(90, 32)
    $btnSync.Location = New-Object System.Drawing.Point(145, 125)
    $btnSync.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($btnSync)

    # Path info label
    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = "Root: $($Paths.Root)"
    $lblPath.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblPath.ForeColor = [System.Drawing.Color]::Gray
    $lblPath.Location = New-Object System.Drawing.Point(15, 185)
    $lblPath.Size = New-Object System.Drawing.Size(420, 20)
    $form.Controls.Add($lblPath)

    $updateStatusUI = {
        $st = Get-ServerStatus -Paths $Paths
        $hasPhp = ($st.PhpProcesses.Count -gt 0)
        if ($st.IsRunning -or $hasPhp) {
            $parts = @()
            if ($st.IsRunning) { $parts += "Apache: RUNNING (PID: $($st.Pids -join ', '))" } else { $parts += "Apache: STOPPED" }
            if ($hasPhp) { $parts += "PHP: RUNNING ($($st.PhpProcesses.Count))" }
            $lblStatus.Text = $parts -join " | "
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            $btnToggle.Text = "Stop"
            $btnRestart.Enabled = $true
        }
        else {
            $lblStatus.Text = "Apache: STOPPED | PHP: STOPPED"
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
            $btnToggle.Text = "Start"
            $btnRestart.Enabled = $false
        }
    }

    $btnToggle.Add_Click({
        $st = Get-ServerStatus -Paths $Paths
        if ($st.IsRunning -or ($st.PhpProcesses.Count -gt 0)) {
            Stop-WebServer -Paths $Paths
        }
        else {
            Start-WebServer -Paths $Paths
        }
        & $updateStatusUI
    })

    $btnRestart.Add_Click({
        Restart-WebServer -Paths $Paths
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
        $statusText = if ($st.IsRunning) { "[RUNNING] (PID: $($st.Pids -join ', '))" } else { "[STOPPED]" }
        $statusColor = if ($st.IsRunning) { 'Green' } else { 'Red' }
        $phpText = if ($st.PhpProcesses.Count -gt 0) { "[RUNNING] ($($st.PhpProcesses.Count) procs)" } else { "[STOPPED]" }
        $phpColor = if ($st.PhpProcesses.Count -gt 0) { 'Green' } else { 'DarkGray' }

        Clear-Host
        Write-Host "===================================================" -ForegroundColor Cyan
        Write-Host " Portable Web Controller (XAMPP-Style)" -ForegroundColor White
        Write-Host " Root  : $($Paths.Root)" -ForegroundColor DarkGray
        Write-Host " Htdocs: $($Paths.Htdocs)" -ForegroundColor DarkGray
        Write-Host " PHP   : PHP $($Paths.DefaultPhp) (Port $($Paths.DefaultPort))" -ForegroundColor DarkGray
        Write-Host " Apache Status: " -NoNewline
        Write-Host $statusText -ForegroundColor $statusColor
        Write-Host " PHP Status   : " -NoNewline
        Write-Host $phpText -ForegroundColor $phpColor
        Write-Host "===================================================" -ForegroundColor Cyan
        Write-Host " [1] Start Apache"
        Write-Host " [2] Stop Apache & PHP"
        Write-Host " [3] Restart Apache & PHP"
        Write-Host " [4] Refresh Status"
        Write-Host " [5] Open Browser (Dashboard localhost:$($Paths.DefaultPort))"
        Write-Host " [6] Open Htdocs in Explorer"
        Write-Host " [7] Launch Portable Shell (PHP $($Paths.DefaultPhp))"
        Write-Host " [8] Sync Paths (.env)"
        Write-Host " [9] Launch GUI Control Panel"
        Write-Host " [0] Exit"
        Write-Host "---------------------------------------------------" -ForegroundColor DarkGray

        $choice = Read-Host "Select option [0-9]"
        switch ($choice) {
            '1' { Start-WebServer -Paths $Paths; Start-Sleep -Seconds 1 }
            '2' { Stop-WebServer -Paths $Paths; Start-Sleep -Seconds 1 }
            '3' { Restart-WebServer -Paths $Paths; Start-Sleep -Seconds 1 }
            '4' { }
            '5' { Open-WebBrowser -TargetPort $Paths.DefaultPort }
            '6' { Open-HtdocsFolder -Paths $Paths }
            '7' { Start-PortableShell -Paths $Paths -Version $Paths.DefaultPhp }
            '8' { $Paths = Get-AppPaths; Sync-PortablePaths -Paths $Paths; Start-Sleep -Seconds 2 }
            '9' { Show-Gui -Paths $Paths }
            '0' { return }
            default { Write-Host "Invalid choice" -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}

# Entrypoint Execution
$paths = Get-AppPaths -CliPhpVersion $PhpVersion -CliPort $Port

switch ($Action.ToLower()) {
    'start'   { Start-WebServer -Paths $paths }
    'stop'    { Stop-WebServer -Paths $paths }
    'restart' { Restart-WebServer -Paths $paths }
    'status'  {
        $st = Get-ServerStatus -Paths $paths
        if ($st.IsRunning) {
            Write-Host "[STATUS] Apache RUNNING (PID: $($st.Pids -join ', '))" -ForegroundColor Green
        }
        else {
            Write-Host "[STATUS] Apache STOPPED" -ForegroundColor Red
        }

        if ($st.PhpProcesses.Count -gt 0) {
            $names = ($st.PhpProcesses.Name | Select-Object -Unique) -join ', '
            Write-Host "[STATUS] PHP RUNNING: $names (PID: $($st.PhpProcesses.Id -join ', '))" -ForegroundColor Green
        }
        else {
            Write-Host "[STATUS] PHP STOPPED" -ForegroundColor DarkGray
        }
    }
    'shell'   { Start-PortableShell -Paths $paths -Version $paths.DefaultPhp }
    'open'    { Open-WebBrowser -TargetPort $paths.DefaultPort }
    'htdocs'  { Open-HtdocsFolder -Paths $paths }
    'sync'    { Sync-PortablePaths -Paths $paths }
    'gui'     { Show-Gui -Paths $paths }
    'menu'    { Show-InteractiveMenu -Paths $paths }
}
