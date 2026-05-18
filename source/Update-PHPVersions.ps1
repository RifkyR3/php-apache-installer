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
    .\source\Update-PHPVersions.ps1

.EXAMPLE
    .\source\Update-PHPVersions.ps1 -Update
#>

[CmdletBinding()]
param(
    [switch]$Update,
    [string]$JsonPath = ".\php-versions.json",
    [bool]$Prefer64 = $true
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

$baseUrlPath = Resolve-RelativePath '.\baseUrl.json'
if (-not (Test-Path $baseUrlPath)) {
    throw "Base URL JSON file not found: $baseUrlPath"
}

$baseUrl = Get-Content $baseUrlPath -Raw | ConvertFrom-Json
$phpVersions = Get-Content $resolvedJsonPath -Raw | ConvertFrom-Json

$phpArchiveFiles = Get-RemoteDirectoryFiles $baseUrl.PHP
$phpReleaseFiles = Get-RemoteDirectoryFiles $baseUrl.PHP_RELEASE
$xdebugFiles = Get-RemoteDirectoryFiles 'https://xdebug.org/download'

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
}

if (-not $changes) {
    Write-Host 'No updates detected. source/php-versions.json is current.'
    return
}

Write-Host "Detected updates for $($changes.Count) field(s):"
$changes | ForEach-Object {
    Write-Host "  $($_.Key) - $($_.Field): $($_.Current) -> $($_.Latest)"
}

if ($Update) {
    $jsonText = $phpVersions | ConvertTo-Json -Depth 6
    Set-Content -Path $resolvedJsonPath -Value $jsonText -Encoding UTF8
    Write-Host "Updated $resolvedJsonPath"
}
else {
    Write-Host "Run with -Update to apply the detected package name changes to the JSON file."
}
