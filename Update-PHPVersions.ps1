<#
.SYNOPSIS
    Reference script to check for newer PHP and Xdebug package names and update source/php-versions.json.

.DESCRIPTION
    Reads source/php-versions.json and source/baseUrl.json, compares each PHP build name against the latest available
    file names on windows.php.net and xdebug.org, and can optionally update the JSON file automatically.

.PARAMETER Update
    If set, the script updates source/php-versions.json with discovered latest package names.

.PARAMETER JsonPath
    Relative or absolute path to the PHP versions JSON file. Defaults to .\source\php-versions.json.

.EXAMPLE
    .\Update-PHPVersions.ps1

.EXAMPLE
    .\Update-PHPVersions.ps1 -Update
#>

[CmdletBinding()]
param(
    [switch]$Update,
    [string]$JsonPath = ".\source\php-versions.json",
    [bool]$Prefer64 = $true,
    [string]$EnvPath = ".\.env.sample"
)

function Write-Log {
    param([string]$Message)
    Write-Host $Message
}

function Get-RemoteDirectoryFiles {
    param(
        [Parameter(Mandatory=$true)][string]$Url
    )

    Write-Log "Fetching remote directory listing from $Url"
    try {
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers $headers -ErrorAction Stop
    }
    catch {
        throw "Failed to fetch remote listing from $Url`: $_"
    }

    $hrefRegex = 'href\s*=\s*["'']([^"'']+)["'']'
    $files = @()
    $baseUri = if ($response.BaseResponse -and $response.BaseResponse.ResponseUri) { $response.BaseResponse.ResponseUri } else { $Url }

    foreach ($match in [regex]::Matches($response.Content, $hrefRegex)) {
        $href = $match.Groups[1].Value
        try {
            $uri = if ($href -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') {
                New-Object System.Uri($href)
            }
            else {
                New-Object System.Uri((New-Object System.Uri($baseUri)), $href)
            }
            $files += [System.IO.Path]::GetFileName($uri.AbsoluteUri)
        }
        catch {
            continue
        }
    }

    return $files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
}

function Get-PHPVersionFromFileName {
    param([string]$FileName)
    if ($FileName -match '^php-(\d+\.\d+\.\d+)') {
        return [version]$Matches[1]
    }
    return $null
}

function Get-XdebugVersionFromFileName {
    param([string]$FileName)
    if ($FileName -match '^php_xdebug-(\d+\.\d+\.\d+)-') {
        return [version]$Matches[1]
    }
    return $null
}

function Get-LatestPhpPackage {
    param(
        [string[]]$Files,
        [string]$PhpMajorMinor,
        [string]$Type
    )

        $pattern = "^php-$PhpMajorMinor\.\d+.*-$Type-.*\.zip$"
        $candidates = $Files | Where-Object { $_ -match $pattern }
        if (-not $candidates) { return $null }

        # Prefer x64 builds when available (controlled by $Prefer64)
        if ($Prefer64) {
            $candidates64 = $candidates | Where-Object { $_ -match 'x64|x86_64' }
            if ($candidates64 -and $candidates64.Count -gt 0) { $candidates = $candidates64 }
        }

        return $candidates | Sort-Object {
            $v = Get-PHPVersionFromFileName $_
            if ($null -eq $v) { [version]'0.0.0' } else { $v }
        } -Descending | Select-Object -First 1
}

function Get-LatestXdebugPackage {
    param(
        [string[]]$Files,
        [string]$PhpMajorMinor
    )

        $pattern = "^php_xdebug-(\d+\.\d+\.\d+)-$PhpMajorMinor-.*\.dll$"
        $candidates = $Files | Where-Object { $_ -match $pattern }
        if (-not $candidates) { return $null }

        # Prefer 64-bit Xdebug binaries (x86_64 / x64) when requested
        if ($Prefer64) {
            $candidates64 = $candidates | Where-Object { $_ -match 'x86_64|x64' }
            if ($candidates64 -and $candidates64.Count -gt 0) { $candidates = $candidates64 }
        }

        return $candidates | Sort-Object {
            $v = Get-XdebugVersionFromFileName $_
            if ($null -eq $v) { [version]'0.0.0' } else { $v }
        } -Descending | Select-Object -First 1
}

function Get-ImagickVersionFromFileName {
    param([string]$FileName)
    if ($FileName -match '^php_imagick-(\d+\.\d+\.\d+)') {
        return [version]$Matches[1]
    }
    return $null
}

function Get-LatestImagickPackage {
    param(
        [string[]]$Files,
        [string]$PhpMajorMinor,
        [string]$Type
    )

    $pattern = "^php_imagick-(\d+\.\d+\.\d+.*?)-$PhpMajorMinor-.*-$Type-.*\.zip$"
    $candidates = $Files | Where-Object { $_ -match $pattern }
    if (-not $candidates) { return $null }

    if ($Prefer64) {
        $candidates64 = $candidates | Where-Object { $_ -match 'x86_64|x64' }
        if ($candidates64 -and $candidates64.Count -gt 0) { $candidates = $candidates64 }
    }

    return $candidates | Sort-Object {
        $v = Get-ImagickVersionFromFileName $_
        if ($null -eq $v) { [version]'0.0.0' } else { $v }
    } -Descending | Select-Object -First 1
}

function Resolve-RelativePath {
    param(
        [string]$Path
    )

    $scriptRoot = Split-Path -Parent $PSCommandPath
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $scriptRoot $Path))
}

$resolvedJsonPath = Resolve-RelativePath $JsonPath
if (-not (Test-Path $resolvedJsonPath)) {
    throw "PHP versions JSON file not found: $resolvedJsonPath"
}

$baseUrlPath = Resolve-RelativePath '.\source\baseUrl.json'
if (-not (Test-Path $baseUrlPath)) {
    throw "Base URL JSON file not found: $baseUrlPath"
}

$baseUrl = Get-Content $baseUrlPath -Raw | ConvertFrom-Json
$phpVersions = Get-Content $resolvedJsonPath -Raw | ConvertFrom-Json

$phpArchiveFiles = Get-RemoteDirectoryFiles $baseUrl.PHP
$phpReleaseFiles = Get-RemoteDirectoryFiles $baseUrl.PHP_RELEASE
$xdebugFiles = Get-RemoteDirectoryFiles 'https://xdebug.org/download'

# PECL Imagick download listing
$imagickBaseUrl = if ($baseUrl.IMAGICK) { $baseUrl.IMAGICK } else { 'https://windows.php.net/downloads/pecl/releases/imagick/' }
$imagickDirs = Get-RemoteDirectoryFiles $imagickBaseUrl | Where-Object { $_ -match '^\d+\.\d+' }
$imagickFiles = @()
foreach ($vDir in $imagickDirs) {
    try {
        $subFiles = Get-RemoteDirectoryFiles "$imagickBaseUrl$vDir" | Where-Object { $_ -match '\.zip$' }
        $imagickFiles += $subFiles
    }
    catch {}
}

# Apache Lounge download listing (for APACHE_BASE)
$apacheFiles = Get-RemoteDirectoryFiles 'https://www.apachelounge.com/download/'

$changes = @()

foreach ($versionKey in $phpVersions.PSObject.Properties.Name) {
    $entry = $phpVersions.$versionKey
    $currentPhpName = $entry.name
    if (-not $currentPhpName) { continue }

    if ($currentPhpName -match '^php-(\d+\.\d+)\.\d+') {
        $phpMajorMinor = $Matches[1]
    }
    else {
        Write-Log "Skipping invalid PHP file name for ${versionKey}: $currentPhpName"
        continue
    }

    $type = if ($currentPhpName -match '-(nts|ts)-') { $Matches[1] } else { 'nts' }
    $searchFiles = if ($entry.download -eq 'release') { $phpReleaseFiles } else { $phpArchiveFiles }
    $latestPhpName = Get-LatestPhpPackage -Files $searchFiles -PhpMajorMinor $phpMajorMinor -Type $type

    $latestXdebugName = Get-LatestXdebugPackage -Files $xdebugFiles -PhpMajorMinor $phpMajorMinor
    $latestImagickName = Get-LatestImagickPackage -Files $imagickFiles -PhpMajorMinor $phpMajorMinor -Type $type

    if ($latestPhpName -and $latestPhpName -ne $currentPhpName) {
        $changes += [pscustomobject]@{
            Key = $versionKey
            Field = 'name'
            Current = $currentPhpName
            Latest = $latestPhpName
        }
        if ($Update) {
            $phpVersions.$versionKey.name = $latestPhpName
        }
    }

    if ($latestXdebugName -and $entry.xdebug -ne $latestXdebugName) {
        $changes += [pscustomobject]@{
            Key = $versionKey
            Field = 'xdebug'
            Current = $entry.xdebug
            Latest = $latestXdebugName
        }
        if ($Update) {
            $phpVersions.$versionKey.xdebug = $latestXdebugName
        }
    }

    if ($latestImagickName -and $entry.imagick -ne $latestImagickName) {
        $changes += [pscustomobject]@{
            Key = $versionKey
            Field = 'imagick'
            Current = $entry.imagick
            Latest = $latestImagickName
        }
        if ($Update) {
            $phpVersions.$versionKey.imagick = $latestImagickName
        }
    }
}

# Check for APACHE_BASE updates in environment sample and env files
$resolvedEnvPath = Resolve-RelativePath $EnvPath
$envPaths = @()
if (Test-Path $resolvedEnvPath) { $envPaths += $resolvedEnvPath }
$resolvedDotEnvPath = Resolve-RelativePath '..\.env'
if ((Test-Path $resolvedDotEnvPath) -and ($resolvedDotEnvPath -ne $resolvedEnvPath)) {
    $envPaths += $resolvedDotEnvPath
}

# Determine latest apache package from apacheFiles
function Get-ApacheVersionFromFileName {
    param([string]$FileName)
    if ($FileName -match '^httpd-(\d+\.\d+\.\d+)') {
        return [version]$Matches[1]
    }
    return $null
}

function Get-LatestApachePackage {
    param([string[]]$Files)
    $candidatePattern = '^httpd-\d+\.\d+\.\d+.*\.zip$'
    $candidates = $Files | Where-Object { $_ -match $candidatePattern }
    if (-not $candidates) { return $null }

    $win64Candidates = $candidates | Where-Object { $_ -match 'Win64' }
    if ($win64Candidates) { $candidates = $win64Candidates }

    return $candidates | Sort-Object {
        $v = Get-ApacheVersionFromFileName $_
        if ($null -eq $v) { [version]'0.0.0' } else { $v }
    } -Descending | Select-Object -First 1
}

$latestApacheName = Get-LatestApachePackage -Files $apacheFiles

foreach ($targetEnvPath in $envPaths) {
    $envText = Get-Content $targetEnvPath -Raw
    if ($envText -match 'APACHE_BASE\s*=\s*(\S+)') {
        $currentApacheBase = $Matches[1]
    }
    else {
        $currentApacheBase = $null
    }

    if ($latestApacheName -and $latestApacheName -ne $currentApacheBase) {
        $apacheChange = [pscustomobject]@{
            Key = 'APACHE_BASE'
            Field = 'APACHE_BASE'
            File = $targetEnvPath
            Current = $currentApacheBase
            Latest = $latestApacheName
        }
        $changes += $apacheChange
        if ($Update) {
            if ($currentApacheBase) {
                # replace existing APACHE_BASE line using multiline mode so later lines are updated correctly
                $envText = $envText -replace '(?m)^(APACHE_BASE\s*=\s*).+', "`$1$latestApacheName"
            }
            else {
                # append variable if it does not exist yet, preserving existing file termination without duplicate blank lines
                $envText = $envText.TrimEnd("`r", "`n")
                $envText = $envText + "`r`nAPACHE_BASE=$latestApacheName"
            }
            Set-Content -Path $targetEnvPath -Value $envText -Encoding UTF8
        }
    }
}

if (-not $changes) {
    Write-Host 'No updates detected. source/php-versions.json and env files are current.'
    return
}

Write-Host "Detected updates for $($changes.Count) field(s):"
$changes | ForEach-Object {
    if ($_.Key -eq 'APACHE_BASE') {
        Write-Host "  $($_.File): APACHE_BASE: $($_.Current) -> $($_.Latest)"
    }
    else {
        Write-Host "  $($_.Key) - $($_.Field): $($_.Current) -> $($_.Latest)"
    }
}

if ($Update) {
    $jsonText = $phpVersions | ConvertTo-Json -Depth 6
    Set-Content -Path $resolvedJsonPath -Value $jsonText -Encoding UTF8
    Write-Host "Updated $resolvedJsonPath"
    foreach ($change in $changes | Where-Object { $_.Key -eq 'APACHE_BASE' }) {
        Write-Host "Updated $($change.File)"
    }
}
else {
    Write-Host "Run with -Update to apply the detected package name changes to the JSON file and env files."
}
