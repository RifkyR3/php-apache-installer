function Download-File {
    param(
        [string]$URL,
        [string]$pathName
    )

    $MaxRetries = 3
    $RetryCount = 0

    while ($RetryCount -lt $MaxRetries) {
        if (Test-Path $pathName) {
            Remove-Item $pathName -Force
            Write-Output "Deleted incomplete file: $pathName"
        }

        try {
            Write-Output "Attempt $($RetryCount + 1): curl -L -o $pathName $URL"
            $curlArgs = "-L", "--fail", "-o", $pathName, $URL
            & curl @curlArgs
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                Write-Output "Download succeeded: $pathName"
                return
            }
            else {
                throw "curl exited with code $exitCode"
            }
        }
        catch {
            $RetryCount++
            if ($RetryCount -ge $MaxRetries) {
                throw "Download failed after $MaxRetries attempts: $URL. Error: $_"
            }
            else {
                Write-Warning "Download failed, retrying... ($RetryCount/$MaxRetries): $_"
                Start-Sleep -Seconds (2 * $RetryCount)
            }
        }
    }
}

function Check-Download {
    param(
        [string]$URL,
        [string]$path,
        [string]$name
    )

    $pathName = Join-Path $path $name
    if (-not (Test-Path $pathName)) {
        Write-Output "Not found. Downloading $name to $pathName"
        # Reuse Download-File which already throws on failure
        Download-File $URL $pathName
    }
    else {
        Write-Output "Already exists: $pathName"
    }
}

function Test-FileChecksum {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [string]$Algorithm = "SHA256"
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) {
        return $true
    }

    try {
        $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
        return $actualHash.Equals($ExpectedHash.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        Write-Warning "Failed to compute file hash for ${Path}: $_"
        return $false
    }
}

function Path-Cleaning($default, $path) {
    $string = [string]::IsNullOrWhiteSpace($path) ? [string]$default : [string]$path;
    $string = $string.Replace("/", "\").Split("\");
    $string[0] = $string[0] -eq "." ? ${PWD} : $string[0];
    $string = $string -join "\";

    return $string;
}

function Broadcast-EnvironmentChange {
    [CmdletBinding()]
    param()

    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x001a

    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
            uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
"@ -ErrorAction SilentlyContinue

    $outResult = [UIntPtr]::Zero
    [void][Win32.NativeMethods]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$outResult)
}

function Register-Path-Web {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$PathsToRegister,
        [Parameter(Position = 1)][string]$RegisterPath = '',
        [string]$PhpDir = ''
    )

    # Support legacy 2-parameter signature: Register-Path-Web "WEBSERV" "path1;path2"
    $rawInput = if (-not [string]::IsNullOrWhiteSpace($RegisterPath)) {
        $RegisterPath.Split(';')
    }
    else {
        $PathsToRegister
    }

    $validNewPaths = @($rawInput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($validNewPaths.Count -eq 0) { return }

    # Resolve PHP installation directory dynamically from parameter, environment, or .env file
    if ([string]::IsNullOrWhiteSpace($PhpDir)) {
        $envPhpDir = [System.Environment]::GetEnvironmentVariable("PHP_DIR")
        $envInstallDir = [System.Environment]::GetEnvironmentVariable("INSTALL_DIR")

        # If environment variables are not set in the current process, read directly from .env file
        if ([string]::IsNullOrWhiteSpace($envPhpDir) -and [string]::IsNullOrWhiteSpace($envInstallDir)) {
            $envFiles = @(
                (Join-Path (Get-Location) ".env"),
                (Join-Path $PSScriptRoot ".env")
            ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

            foreach ($envFile in $envFiles) {
                Get-Content -LiteralPath $envFile -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_ -match '^\s*PHP_DIR\s*=\s*(.+)$') {
                        $envPhpDir = ($matches[1] -replace '["'']', '').Trim()
                    }
                    elseif ($_ -match '^\s*INSTALL_DIR\s*=\s*(.+)$') {
                        $envInstallDir = ($matches[1] -replace '["'']', '').Trim()
                    }
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($envPhpDir)) {
            $PhpDir = Path-Cleaning (Get-Location) $envPhpDir
        }
        else {
            $baseInstall = if (-not [string]::IsNullOrWhiteSpace($envInstallDir)) { $envInstallDir } else { '.' }
            $cleanedInstall = Path-Cleaning (Get-Location) $baseInstall
            $PhpDir = Join-Path $cleanedInstall "PHP"
        }
    }
    else {
        $PhpDir = Path-Cleaning (Get-Location) $PhpDir
    }

    $phpDirTrimmed = $PhpDir.TrimEnd('\/')
    $escapedPhpDir = [regex]::Escape($phpDirTrimmed)
    $binDirTrimmed = (Join-Path $PhpDir "bin").TrimEnd('\/')

    $stalePattern = "(?i)^" + $escapedPhpDir + "\\(?!bin($|\\))"
    $isStalePhpPath = {
        param([string]$pathItem)
        if ([string]::IsNullOrWhiteSpace($pathItem)) { return $false }
        $norm = $pathItem.TrimEnd('\/')
        if ($norm -ieq $binDirTrimmed) { return $false }
        if ($norm -match $stalePattern) { return $true }
        if ($norm -match '(?i)[\\/]PHP[\\/](?:5\d|7\d|8\d|\d+)(?:[\\/]|$)') { return $true }
        return $false
    }

    # Retrieve current raw user Path without expanding environment variable strings
    $rawUserPath = (Get-Item -LiteralPath "HKCU:\Environment").GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $existingItems = @($rawUserPath.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $legacyVarName = if (-not [string]::IsNullOrWhiteSpace($env:PATH_NAME)) { $env:PATH_NAME } else { 'WEBSERV' }

    # Clean legacy %WEBSERV% references and stale individual PHP version paths based on .env
    $cleanedItems = @($existingItems | Where-Object {
        $_ -ne '%WEBSERV%' -and
        $_ -ne "%$legacyVarName%" -and
        (-not (& $isStalePhpPath $_))
    })

    # Separate absolute paths from variable references (%...%)
    # Windows 10/11 requires the first item in Path to be an absolute path (not starting with %)
    # to open the modern multi-line GUI list editor ("Edit environment variable") instead of single-line.
    $absoluteEntries = @($cleanedItems | Where-Object { -not $_.StartsWith('%') })
    $envVarEntries   = @($cleanedItems | Where-Object { $_.StartsWith('%') })

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $finalEntries = [System.Collections.Generic.List[string]]::new()

    # 1. Add newly registered paths first (absolute paths)
    foreach ($p in $validNewPaths) {
        if ($seen.Add($p)) { $finalEntries.Add($p) }
    }

    # 2. Add existing absolute paths
    foreach ($p in $absoluteEntries) {
        if ($seen.Add($p)) { $finalEntries.Add($p) }
    }

    # 3. Add existing environment variable paths (e.g. %PNPM_HOME%\bin)
    foreach ($p in $envVarEntries) {
        if ($seen.Add($p)) { $finalEntries.Add($p) }
    }

    $combinedPath = $finalEntries -join ";"

    # Write directly to HKCU\Environment as REG_EXPAND_SZ
    $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    $regKey.SetValue("Path", $combinedPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)

    # Remove legacy WEBSERV variable from HKCU if it exists
    if ($regKey.GetValue("WEBSERV") -ne $null) {
        $regKey.DeleteValue("WEBSERV")
    }
    if ($legacyVarName -ne "WEBSERV" -and $regKey.GetValue($legacyVarName) -ne $null) {
        $regKey.DeleteValue($legacyVarName)
    }
    $regKey.Close()

    # Broadcast environment change to system
    Broadcast-EnvironmentChange
}

function Deploy-PhpBinLinks {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$PhpDir,
        [string]$PhpBinDir = '',
        [PSCustomObject]$Manifests = $null
    )

    if (-not (Test-Path -LiteralPath $PhpDir)) {
        Write-Warning "PHP installation directory not found at: $PhpDir"
        return
    }

    if ([string]::IsNullOrWhiteSpace($PhpBinDir)) {
        $PhpBinDir = Join-Path $PhpDir "bin"
    }

    if (-not (Test-Path -LiteralPath $PhpBinDir)) {
        if ($PSCmdlet.ShouldProcess($PhpBinDir, "Create PHP bin directory")) {
            New-Item -ItemType Directory -Path $PhpBinDir -Force | Out-Null
            Write-Output "Created PHP bin directory: $PhpBinDir"
        }
    }

    # Discover installed PHP version directories matching numeric alias format (e.g. 54, 82, 85) containing php.exe
    $versionFolders = @(Get-ChildItem -LiteralPath $PhpDir -Directory | Where-Object {
        $_.Name -match '^\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName "php.exe"))
    })

    if ($versionFolders.Count -eq 0) {
        Write-Warning "No installed PHP versions found in $PhpDir"
        return
    }

    # Auto-load manifests from source/php-versions.json if not provided
    if ($null -eq $Manifests) {
        $candidateManifest = Join-Path $PSScriptRoot "source\php-versions.json"
        if (-not (Test-Path -LiteralPath $candidateManifest)) {
            $candidateManifest = Join-Path (Get-Location) "source\php-versions.json"
        }
        if (Test-Path -LiteralPath $candidateManifest) {
            $Manifests = [PSCustomObject]@{
                PhpVersions = (Get-Content -LiteralPath $candidateManifest -Raw | ConvertFrom-Json)
            }
        }
    }

    # Map aliases to semantic versions from manifest
    $aliasToVersion = @{}
    if ($Manifests -and $Manifests.PhpVersions) {
        foreach ($prop in $Manifests.PhpVersions.PSObject.Properties) {
            $alias = [string]$prop.Value.alias
            $verName = [string]$prop.Name -replace '^[vV]', ''
            try {
                $aliasToVersion[$alias] = [version]$verName
            }
            catch {
                $aliasToVersion[$alias] = [version]"0.0"
            }
        }
    }

    $discoveredVersions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($folder in $versionFolders) {
        $alias = $folder.Name
        $exePath = Join-Path $folder.FullName "php.exe"
        $cgiPath = Join-Path $folder.FullName "php-cgi.exe"
        $hasCgi = Test-Path -LiteralPath $cgiPath
        $pharPath = Join-Path $folder.FullName "composer.phar"
        $hasComposer = Test-Path -LiteralPath $pharPath
        $piePath = Join-Path $folder.FullName "pie.phar"
        $hasPie = Test-Path -LiteralPath $piePath

        $parsedVer = if ($aliasToVersion.ContainsKey($alias)) {
            $aliasToVersion[$alias]
        }
        else {
            if ($alias.Length -ge 2) {
                try {
                    [version]"$($alias[0]).$($alias.Substring(1))"
                } catch {
                    [version]"0.0"
                }
            } else {
                [version]"0.0"
            }
        }

        $discoveredVersions.Add([PSCustomObject]@{
            Alias       = $alias
            ExePath     = $exePath
            CgiPath     = $cgiPath
            HasCgi      = $hasCgi
            PharPath    = $pharPath
            HasComposer = $hasComposer
            PiePath     = $piePath
            HasPie      = $hasPie
            Version     = $parsedVer
        })
    }

    $sortedVersions = @($discoveredVersions | Sort-Object -Property Version)
    $latestVersion = $sortedVersions[-1]

    function Set-ShimFile {
        param(
            [string]$ShimName,
            [string]$TargetExe,
            [string]$TargetPhar = ''
        )

        $cmdPath = Join-Path $PhpBinDir "$ShimName.cmd"
        $batPath = Join-Path $PhpBinDir "$ShimName.bat"
        $shPath  = Join-Path $PhpBinDir "$ShimName"

        $targetForward = $TargetExe.Replace('\', '/')
        if (-not [string]::IsNullOrWhiteSpace($TargetPhar)) {
            $pharForward = $TargetPhar.Replace('\', '/')
            $cmdContent = "@echo off`r`nsetlocal DISABLEDELAYEDEXPANSION`r`n@`"$TargetExe`" `"$TargetPhar`" %*`r`n"
            $shContent  = "#!/bin/sh`nexec `"$targetForward`" `"$pharForward`" `"`$@`"`n"
        }
        else {
            $cmdContent = "@echo off`r`n@`"$TargetExe`" %*`r`n"
            $shContent  = "#!/bin/sh`nexec `"$targetForward`" `"`$@`"`n"
        }

        Set-Content -LiteralPath $cmdPath -Value $cmdContent -Encoding ASCII
        Set-Content -LiteralPath $batPath -Value $cmdContent -Encoding ASCII
        Set-Content -LiteralPath $shPath  -Value $shContent  -Encoding UTF8 -NoNewline
    }

    if ($PSCmdlet.ShouldProcess($PhpBinDir, "Generate CLI links for PHP, PHP-CGI, Composer and PIE")) {
        # Track active shim names to clean obsolete ones
        $activeNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($v in $sortedVersions) {
            [void]$activeNames.Add("php$($v.Alias)")
            if ($v.HasCgi) {
                [void]$activeNames.Add("php-cgi$($v.Alias)")
                [void]$activeNames.Add("php$($v.Alias)-cgi")
            }
            if ($v.HasComposer) { [void]$activeNames.Add("composer$($v.Alias)") }
            if ($v.HasPie) { [void]$activeNames.Add("pie$($v.Alias)") }
        }
        [void]$activeNames.Add("php")
        if ($latestVersion.HasCgi) {
            [void]$activeNames.Add("php-cgi")
        }
        if ($latestVersion.HasComposer) { [void]$activeNames.Add("composer") }
        if ($latestVersion.HasPie) { [void]$activeNames.Add("pie") }

        Get-ChildItem -LiteralPath $PhpBinDir -File -ErrorAction SilentlyContinue | Where-Object {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            $isShim = ($_.Extension -in ".cmd", ".bat") -or ($_.Extension -eq "")
            $isTargetShim = $baseName.StartsWith("php", [System.StringComparison]::OrdinalIgnoreCase) -or
                            $baseName.StartsWith("composer", [System.StringComparison]::OrdinalIgnoreCase) -or
                            $baseName.StartsWith("pie", [System.StringComparison]::OrdinalIgnoreCase)
            $isTargetShim -and (-not $activeNames.Contains($baseName) -and -not $activeNames.Contains($_.Name))
        } | Remove-Item -Force -ErrorAction SilentlyContinue

        # Create php{alias}, php-cgi{alias}, and composer{alias} links for each installed version
        foreach ($verInfo in $sortedVersions) {
            Set-ShimFile -ShimName "php$($verInfo.Alias)" -TargetExe $verInfo.ExePath
            Write-Output "Created CLI link: php$($verInfo.Alias) -> $($verInfo.ExePath)"

            if ($verInfo.HasCgi) {
                Set-ShimFile -ShimName "php-cgi$($verInfo.Alias)" -TargetExe $verInfo.CgiPath
                Set-ShimFile -ShimName "php$($verInfo.Alias)-cgi" -TargetExe $verInfo.CgiPath
                Write-Output "Created CLI link: php-cgi$($verInfo.Alias) / php$($verInfo.Alias)-cgi -> $($verInfo.CgiPath)"
            }

            if ($verInfo.HasComposer) {
                Set-ShimFile -ShimName "composer$($verInfo.Alias)" -TargetExe $verInfo.ExePath -TargetPhar $verInfo.PharPath
                Write-Output "Created CLI link: composer$($verInfo.Alias) -> $($verInfo.ExePath) ($($verInfo.PharPath))"
            }

            if ($verInfo.HasPie) {
                Set-ShimFile -ShimName "pie$($verInfo.Alias)" -TargetExe $verInfo.ExePath -TargetPhar $verInfo.PiePath
                Write-Output "Created CLI link: pie$($verInfo.Alias) -> $($verInfo.ExePath) ($($verInfo.PiePath))"
            }
        }

        # Create 'php', 'php-cgi', and 'composer' links pointing ONLY to the latest installed PHP version
        Set-ShimFile -ShimName "php" -TargetExe $latestVersion.ExePath
        Write-Output "Created latest CLI link: php -> $($latestVersion.ExePath) (PHP $($latestVersion.Version))"

        if ($latestVersion.HasCgi) {
            Set-ShimFile -ShimName "php-cgi" -TargetExe $latestVersion.CgiPath
            Write-Output "Created latest CLI link: php-cgi -> $($latestVersion.CgiPath) (PHP $($latestVersion.Version))"
        }

        if ($latestVersion.HasComposer) {
            Set-ShimFile -ShimName "composer" -TargetExe $latestVersion.ExePath -TargetPhar $latestVersion.PharPath
            Write-Output "Created latest CLI link: composer -> $($latestVersion.ExePath) (PHP $($latestVersion.Version))"
        }

        if ($latestVersion.HasPie) {
            Set-ShimFile -ShimName "pie" -TargetExe $latestVersion.ExePath -TargetPhar $latestVersion.PiePath
            Write-Output "Created latest CLI link: pie -> $($latestVersion.ExePath) (PHP $($latestVersion.Version))"
        }

        Write-Host "  [OK] Generated PHP, PHP-CGI, Composer & PIE CLI links in $PhpBinDir" -ForegroundColor Green
        Write-Host "       - PHP version links      : $($sortedVersions.ForEach({ "php$($_.Alias)" }) -join ', ')" -ForegroundColor DarkGray
        $cgiVersions = @($sortedVersions | Where-Object { $_.HasCgi })
        if ($cgiVersions.Count -gt 0) {
            Write-Host "       - PHP-CGI version links  : $($cgiVersions.ForEach({ "php-cgi$($_.Alias)" }) -join ', ')" -ForegroundColor DarkGray
        }
        $compVersions = @($sortedVersions | Where-Object { $_.HasComposer })
        if ($compVersions.Count -gt 0) {
            Write-Host "       - Composer version links : $($compVersions.ForEach({ "composer$($_.Alias)" }) -join ', ')" -ForegroundColor DarkGray
        }
        $pieVersions = @($sortedVersions | Where-Object { $_.HasPie })
        if ($pieVersions.Count -gt 0) {
            Write-Host "       - PIE version links      : $($pieVersions.ForEach({ "pie$($_.Alias)" }) -join ', ')" -ForegroundColor DarkGray
        }
        Write-Host "       - Latest PHP link        : php -> $($latestVersion.ExePath)" -ForegroundColor Green
        if ($latestVersion.HasCgi) {
            Write-Host "       - Latest PHP-CGI link    : php-cgi -> $($latestVersion.CgiPath)" -ForegroundColor Green
        }
        if ($latestVersion.HasComposer) {
            Write-Host "       - Latest Composer link   : composer -> $($latestVersion.PharPath)" -ForegroundColor Green
        }
        if ($latestVersion.HasPie) {
            Write-Host "       - Latest PIE link        : pie -> $($latestVersion.PiePath)" -ForegroundColor Green
        }
    }
}

function Get-BoolFromEnv {
    param([string]$envVar, [bool]$default = $true)
    if ([string]::IsNullOrWhiteSpace($envVar)) { return $default }
    return $envVar -in "1", "true", "yes", "on"
}