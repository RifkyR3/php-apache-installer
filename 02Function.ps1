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

function Path-Cleaning($default, $path) {
    $string = [string]::IsNullOrWhiteSpace($path) ? [string]$default : [string]$path;
    $string = $string.Replace("/", "\").Split("\");
    $string[0] = $string[0] -eq "." ? ${PWD} : $string[0];
    $string = $string -join "\";

    return $string;
}

function Register-Path-Web ($pathName, $registerPath) {
    $tmpPath = (get-item hkcu:\Environment).GetValue('Path', $null, 'DoNotExpandEnvironmentNames');
    $tmpPath = $tmpPath.Split(";");

    $tmpRegisterPath = '';
    $registered = 0;
    for ($i = 0; $i -lt $tmpPath.Count; $i++) {
        if ($i -eq 0) {
            $tmpRegisterPath = $tmpPath[$i];
        }
        else {
            $tmpRegisterPath = $tmpRegisterPath + ";" + $tmpPath[$i];
        }

        if ($tmpPath[$i] -eq "%${pathName}%") {
            $registered = 1;
        }
    }

    if ($registered -eq 0) {
        [Environment]::SetEnvironmentVariable('Path', "${tmpRegisterPath};%${pathName}%;", 'user')
    }

    [Environment]::SetEnvironmentVariable($pathName, $registerPath, 'user');
}

function Get-BoolFromEnv {
    param([string]$envVar, [bool]$default = $true)
    if ([string]::IsNullOrWhiteSpace($envVar)) { return $default }
    return $envVar -in "1", "true", "yes", "on"
}