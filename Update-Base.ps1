#Requires -Version 5.1
<#
.SYNOPSIS
    Automated package discovery and manifest updater for PHP, Xdebug, Imagick, Apache, and Nginx on Windows.

.DESCRIPTION
    Scans upstream distribution repositories (windows.php.net, apachelounge.com, xdebug.org, github.com/nginx)
    to discover the latest released binaries and updates source/php-versions.json and source/baseUrl.json.
    Supports both a full interactive console menu and modular command-line automation.

.PARAMETER Action
    Primary execution mode: 'check' (dry-run detection), 'update' (apply updates to manifests), or 'menu' (interactive UI).
    Defaults to 'check'.

.PARAMETER Update
    Shortcut switch equivalent to -Action 'update'. Updates source manifests with discovered package versions.

.PARAMETER Menu
    Shortcut switch equivalent to -Action 'menu'. Launches the interactive console menu.

.PARAMETER Component
    Filters detection to a specific package component: 'all', 'php', 'apache', 'nginx', 'xdebug', 'imagick', or 'rdkafka'.
    Defaults to 'all'.

.PARAMETER PhpVersion
    Filters detection to specific PHP major.minor versions (e.g. '8.2', '82', 'v8.2', or array '8.2','8.4').

.PARAMETER Prefer64
    Prefer 64-bit binaries (x64 / x86_64) where available. Defaults to $true.

.PARAMETER NginxBranch
    Release branch for Nginx: 'stable' (even minor versions), 'mainline' (odd minor versions), or 'any'.
    Defaults to 'stable'.

.PARAMETER JsonPath
    Path to the PHP versions JSON manifest. Defaults to .\source\php-versions.json.

.PARAMETER BaseUrlPath
    Path to the base URLs JSON manifest. Defaults to .\source\baseUrl.json.

.PARAMETER Quiet
    Suppresses verbose HTTP fetch notifications during scanning.

.PARAMETER PassThru
    Outputs detected changes as structured PSCustomObject instances to the PowerShell pipeline.

.EXAMPLE
    pwsh -NoProfile .\Update-Base.ps1
    # Performs dry-run check on all packages and displays results table.

.EXAMPLE
    pwsh -NoProfile .\Update-Base.ps1 -Update
    # Applies detected updates to source/php-versions.json and source/baseUrl.json.

.EXAMPLE
    pwsh -NoProfile .\Update-Base.ps1 -Component apache -Update
    # Checks and updates Apache HTTPD only.

.EXAMPLE
    pwsh -NoProfile .\Update-Base.ps1 -PhpVersion 8.2 -Component php
    # Checks PHP package updates specifically for PHP 8.2.

.EXAMPLE
    pwsh -NoProfile .\Update-Base.ps1 -Menu
    # Launches the interactive console menu.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'update', 'menu')]
    [string]$Action = 'check',

    [switch]$Update,
    [switch]$Menu,

    [ValidateSet('all', 'php', 'apache', 'nginx', 'xdebug', 'imagick', 'rdkafka')]
    [string]$Component = 'all',

    [string[]]$PhpVersion,

    [ValidateSet('stable', 'mainline', 'any')]
    [string]$NginxBranch = 'stable',

    [bool]$Prefer64 = $true,

    [string]$JsonPath = '.\source\php-versions.json',
    [string]$BaseUrlPath = '.\source\baseUrl.json',

    [switch]$Quiet,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Global in-memory cache for remote HTTP listings during execution
$script:ListingCache = @{}

# ==============================================================================
# 1. Path & Manifest Helpers
# ==============================================================================

function Resolve-ScriptPath {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptRoot = (Get-Location).Path
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $scriptRoot $Path))
}

function Get-UpdateConfig {
    [CmdletBinding()]
    param(
        [hashtable]$CliParams,
        [string]$CliJsonPath,
        [string]$CliBaseUrlPath,
        [string]$CliNginxBranch,
        [bool]$CliPrefer64,
        [string]$CliComponent,
        [string[]]$CliPhpVersion
    )

    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptRoot = (Get-Location).Path
    }

    $resolvedJsonPath = Resolve-ScriptPath $CliJsonPath
    if (-not (Test-Path -LiteralPath $resolvedJsonPath)) {
        throw "PHP versions JSON manifest not found: $resolvedJsonPath"
    }

    $resolvedBaseUrlPath = Resolve-ScriptPath $CliBaseUrlPath
    if (-not (Test-Path -LiteralPath $resolvedBaseUrlPath)) {
        throw "Base URLs JSON manifest not found: $resolvedBaseUrlPath"
    }

    return [PSCustomObject]@{
        ScriptRoot          = $scriptRoot
        ResolvedJsonPath    = $resolvedJsonPath
        ResolvedBaseUrlPath = $resolvedBaseUrlPath
        NginxBranch         = $CliNginxBranch
        Prefer64            = $CliPrefer64
        Component           = $CliComponent.ToLower()
        PhpVersion          = $CliPhpVersion
    }
}

function Save-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )

    $jsonText = $Data | ConvertTo-Json -Depth 6
    # Ensure UTF-8 without BOM on both Windows PowerShell 5.1 and PowerShell 7+
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $jsonText + [System.Environment]::NewLine, $utf8NoBom)
}

# ==============================================================================
# 2. Remote Directory Scraping & In-Memory Caching
# ==============================================================================

function Invoke-RemoteListing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [switch]$Quiet
    )

    if ($script:ListingCache.ContainsKey($Url)) {
        return $script:ListingCache[$Url]
    }

    if (-not $Quiet) {
        Write-Host "Fetching remote directory listing: $Url" -ForegroundColor DarkGray
    }

    try {
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers $headers -TimeoutSec 15 -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to fetch remote directory listing from $Url`: $_"
        return @()
    }

    $hrefRegex = 'href\s*=\s*["'']([^"'']+)["'']'
    $files = [System.Collections.Generic.List[string]]::new()
    $baseUri = $Url
    if ($null -ne $response.BaseResponse) {
        $prop = $response.BaseResponse.PSObject.Properties['ResponseUri']
        if ($null -ne $prop -and $null -ne $prop.Value) {
            $baseUri = $prop.Value
        }
    }

    foreach ($match in [regex]::Matches($response.Content, $hrefRegex)) {
        $href = $match.Groups[1].Value
        try {
            $uri = if ($href -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') {
                New-Object System.Uri($href)
            } else {
                New-Object System.Uri((New-Object System.Uri($baseUri)), $href)
            }
            $fileName = [System.IO.Path]::GetFileName($uri.AbsoluteUri.TrimEnd('/'))
            if (-not [string]::IsNullOrWhiteSpace($fileName)) {
                $files.Add($fileName)
            }
        }
        catch {
            continue
        }
    }

    $uniqueFiles = @($files | Sort-Object -Unique)
    $script:ListingCache[$Url] = $uniqueFiles
    return $uniqueFiles
}

function Get-RemotePhpChecksumMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$BaseUrlRelease = 'https://windows.php.net/downloads/releases/',
        [switch]$Quiet
    )

    $cacheKey = "PHP_CHECKSUMS_MAP"
    if ($script:ListingCache.ContainsKey($cacheKey)) {
        return $script:ListingCache[$cacheKey]
    }

    $map = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1. Attempt to fetch metadata from official releases.json
    $jsonUrl = "$($BaseUrlRelease.TrimEnd('/'))/releases.json"
    try {
        if (-not $Quiet) {
            Write-Host "Fetching PHP release checksum metadata: $jsonUrl" -ForegroundColor DarkGray
        }
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
        $resp = Invoke-RestMethod -Uri $jsonUrl -Headers $headers -TimeoutSec 10 -ErrorAction Stop
        if ($null -ne $resp) {
            foreach ($prop in $resp.PSObject.Properties) {
                $branchData = $prop.Value
                if ($branchData -is [PSCustomObject]) {
                    foreach ($variantProp in $branchData.PSObject.Properties) {
                        $variant = $variantProp.Value
                        if ($variant -is [PSCustomObject] -and $variant.PSObject.Properties['zip']) {
                            $zipObj = $variant.zip
                            if ($zipObj.PSObject.Properties['path'] -and $zipObj.PSObject.Properties['sha256']) {
                                $filePath = [string]$zipObj.path
                                $fileSha = [string]$zipObj.sha256
                                if (-not [string]::IsNullOrWhiteSpace($filePath) -and -not [string]::IsNullOrWhiteSpace($fileSha)) {
                                    $map[$filePath.Trim()] = $fileSha.Trim().ToLowerInvariant()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    catch {
        if (-not $Quiet) {
            Write-Host "releases.json fetch skipped or unavailable: $_" -ForegroundColor DarkGray
        }
    }

    # 2. Supplementary fallback: sha256sum.txt (for older or archived releases)
    $shaUrl = "$($BaseUrlRelease.TrimEnd('/'))/sha256sum.txt"
    try {
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
        $shaText = (Invoke-WebRequest -Uri $shaUrl -Headers $headers -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop).Content
        if (-not [string]::IsNullOrWhiteSpace($shaText)) {
            foreach ($line in ($shaText -split "\r?\n")) {
                if ($line -match '^([a-fA-F0-9]{64})\s+[*]?(\S+)') {
                    $hash = $Matches[1].ToLowerInvariant()
                    $fname = [System.IO.Path]::GetFileName($Matches[2])
                    if (-not $map.ContainsKey($fname)) {
                        $map[$fname] = $hash
                    }
                }
            }
        }
    }
    catch {
        # sha256sum.txt fallback optional
    }

    $script:ListingCache[$cacheKey] = $map
    return $map
}

function Get-RemoteNginxReleases {
    [CmdletBinding()]
    param(
        [string]$NginxUrl,
        [switch]$Quiet
    )

    $cacheKey = "NGINX_RELEASES_$NginxUrl"
    if ($script:ListingCache.ContainsKey($cacheKey)) {
        return $script:ListingCache[$cacheKey]
    }

    $nginxFiles = [System.Collections.Generic.List[string]]::new()
    $isGitHub = ($NginxUrl -match 'github\.com')

    if ($isGitHub) {
        if (-not $Quiet) {
            Write-Host "Querying Nginx releases from GitHub API..." -ForegroundColor DarkGray
        }
        try {
            $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
            $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/nginx/nginx/releases?per_page=30' -Headers $headers -TimeoutSec 15 -ErrorAction Stop
            foreach ($r in $releases) {
                $zipAsset = $r.assets | Where-Object { $_.name -match '^nginx-.*\.zip$' }
                if ($zipAsset) { $nginxFiles.Add($zipAsset.name) }
            }
        }
        catch {
            if (-not $Quiet) {
                Write-Host "GitHub releases API failed: $_. Falling back to tags..." -ForegroundColor DarkGray
            }
            try {
                $tagsResponse = Invoke-RestMethod -Uri 'https://api.github.com/repos/nginx/nginx/tags?per_page=50' -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } -TimeoutSec 15 -ErrorAction Stop
                foreach ($t in $tagsResponse) {
                    if ($t.name -match '^release-(\d+\.\d+\.\d+)$') {
                        $nginxFiles.Add("nginx-$($Matches[1]).zip")
                    }
                }
            }
            catch {
                Write-Warning "Failed to query GitHub repository tags: $_"
            }
        }
    }
    else {
        try {
            $remoteFiles = Invoke-RemoteListing -Url $NginxUrl -Quiet:$Quiet
            foreach ($f in $remoteFiles) { $nginxFiles.Add($f) }
        }
        catch {
            Write-Warning "Primary Nginx listing from $NginxUrl unreachable: $_"
        }
    }

    $unique = @($nginxFiles | Sort-Object -Unique)
    $script:ListingCache[$cacheKey] = $unique
    return $unique
}

function Get-RemoteImagickFiles {
    [CmdletBinding()]
    param(
        [string]$ImagickBaseUrl,
        [switch]$Quiet
    )

    $cacheKey = "IMAGICK_FILES_$ImagickBaseUrl"
    if ($script:ListingCache.ContainsKey($cacheKey)) {
        return $script:ListingCache[$cacheKey]
    }

    $dirs = Invoke-RemoteListing -Url $ImagickBaseUrl -Quiet:$Quiet | Where-Object { $_ -match '^\d+\.\d+' }
    $sortedDirs = @($dirs | Sort-Object {
        if ($_ -match '^(\d+\.\d+(\.\d+)?)') {
            try { [version]$Matches[1] } catch { [version]'0.0.0' }
        } else {
            [version]'0.0.0'
        }
    } -Descending)

    # Scan directories (top 15 versions cover all supported PHP branches)
    $targetDirs = $sortedDirs | Select-Object -First 15
    $imagickFiles = [System.Collections.Generic.List[string]]::new()

    foreach ($vDir in $targetDirs) {
        $subUrl = "$ImagickBaseUrl$vDir"
        if (-not $subUrl.EndsWith('/')) { $subUrl += '/' }
        try {
            $subFiles = Invoke-RemoteListing -Url $subUrl -Quiet:$Quiet | Where-Object { $_ -match '\.zip$' }
            foreach ($sf in $subFiles) { $imagickFiles.Add($sf) }
        }
        catch {
            continue
        }
    }

    $unique = @($imagickFiles | Sort-Object -Unique)
    $script:ListingCache[$cacheKey] = $unique
    return $unique
}

# ==============================================================================
function Get-RemoteRdkafkaFiles {
    [CmdletBinding()]
    param(
        [string]$RdkafkaBaseUrl,
        [switch]$Quiet
    )

    $cacheKey = "RDKAFKA_FILES_$RdkafkaBaseUrl"
    if ($script:ListingCache.ContainsKey($cacheKey)) {
        return $script:ListingCache[$cacheKey]
    }

    $dirs = Invoke-RemoteListing -Url $RdkafkaBaseUrl -Quiet:$Quiet | Where-Object { $_ -match '^\d+\.\d+' }
    $sortedDirs = @($dirs | Sort-Object {
        if ($_ -match '^(\d+\.\d+(\.\d+)?)') {
            try { [version]$Matches[1] } catch { [version]'0.0.0' }
        } else {
            [version]'0.0.0'
        }
    } -Descending)

    # Scan directories (top 15 versions cover all supported PHP branches)
    $targetDirs = $sortedDirs | Select-Object -First 15
    $rdkafkaFiles = [System.Collections.Generic.List[string]]::new()

    foreach ($vDir in $targetDirs) {
        $subUrl = "$RdkafkaBaseUrl$vDir"
        if (-not $subUrl.EndsWith('/')) { $subUrl += '/' }
        try {
            $subFiles = Invoke-RemoteListing -Url $subUrl -Quiet:$Quiet | Where-Object { $_ -match '\.zip$' }
            foreach ($sf in $subFiles) { $rdkafkaFiles.Add($sf) }
        }
        catch {
            continue
        }
    }

    $unique = @($rdkafkaFiles | Sort-Object -Unique)
    $script:ListingCache[$cacheKey] = $unique
    return $unique
}

# 3. Version Parsing & Matchers
# ==============================================================================

function Get-VersionFromString {
    [CmdletBinding()]
    param(
        [string]$FileName,
        [string]$PrefixPattern
    )

    if ($FileName -match $PrefixPattern) {
        try {
            return [version]$Matches[1]
        }
        catch {
            return $null
        }
    }
    return $null
}

function Test-PhpVersionMatch {
    [CmdletBinding()]
    param(
        [string]$VersionKey,
        [string[]]$FilterList
    )

    if ($null -eq $FilterList -or $FilterList.Count -eq 0) {
        return $true
    }

    $cleanKey = $VersionKey.ToLower().Replace('v', '').Replace('.', '').Trim()
    $rawKey = $VersionKey.ToLower().Replace('v', '').Trim()

    foreach ($f in $FilterList) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        $cleanF = $f.ToLower().Replace('v', '').Replace('.', '').Trim()
        $rawF = $f.ToLower().Replace('v', '').Trim()
        if ($cleanF -eq $cleanKey -or $rawF -eq $rawKey) {
            return $true
        }
    }

    return $false
}

function Find-LatestPhpPackage {
    [CmdletBinding()]
    param(
        [string[]]$Files,
        [string]$PhpMajorMinor,
        [string]$Type,
        [bool]$Prefer64 = $true
    )

    $pattern = "^php-$PhpMajorMinor\.\d+.*-$Type-.*\.zip$"
    $candidates = @($Files | Where-Object { $_ -match $pattern })
    if ($candidates.Count -eq 0) { return $null }

    if ($Prefer64) {
        $candidates64 = @($candidates | Where-Object { $_ -match 'x64|x86_64' })
        if ($candidates64.Count -gt 0) { $candidates = $candidates64 }
    }

    $candidates = @($candidates | Where-Object { $_ -notmatch '(?i)(alpha|beta|rc)' })

    return $candidates | Sort-Object {
        $v = Get-VersionFromString -FileName $_ -PrefixPattern '^php-(\d+\.\d+\.\d+)'
        if ($null -eq $v) { [version]'0.0.0' } else { $v }
    } -Descending | Select-Object -First 1
}

function Get-PhpPackageSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [hashtable]$RemoteChecksumMap = $null,
        [string]$TmpDir = ''
    )

    if ($null -ne $RemoteChecksumMap -and $RemoteChecksumMap.ContainsKey($FileName)) {
        return [string]$RemoteChecksumMap[$FileName]
    }

    if (-not [string]::IsNullOrWhiteSpace($TmpDir)) {
        $localPath = Join-Path $TmpDir $FileName
        if (Test-Path -LiteralPath $localPath) {
            try {
                return (Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            catch { }
        }
    }

    return $null
}

function Find-LatestXdebugPackage {
    [CmdletBinding()]
    param(
        [string[]]$Files,
        [string]$PhpMajorMinor,
        [string]$Type = 'nts',
        [bool]$Prefer64 = $true
    )

    $pattern = if (-not [string]::IsNullOrWhiteSpace($Type)) {
        "^php_xdebug-(\d+\.\d+\.\d+)-$PhpMajorMinor-.*-$Type-.*\.dll$"
    } else {
        "^php_xdebug-(\d+\.\d+\.\d+)-$PhpMajorMinor-.*\.dll$"
    }

    $candidates = @($Files | Where-Object { $_ -match $pattern })
    if ($candidates.Count -eq 0) { return $null }

    if ($Prefer64) {
        $candidates64 = @($candidates | Where-Object { $_ -match 'x86_64|x64' })
        if ($candidates64.Count -gt 0) { $candidates = $candidates64 }
    }

    $candidates = @($candidates | Where-Object { $_ -notmatch '(?i)(alpha|beta|rc)' })

    return $candidates | Sort-Object {
        $v = Get-VersionFromString -FileName $_ -PrefixPattern '^php_xdebug-(\d+\.\d+\.\d+)-'
        if ($null -eq $v) { [version]'0.0.0' } else { $v }
    } -Descending | Select-Object -First 1
}

function Find-LatestImagickPackage {
    [CmdletBinding()]
    param(
        [string[]]$Files,
        [string]$PhpMajorMinor,
        [string]$Type,
        [bool]$Prefer64 = $true
    )

    $escapedVer = [regex]::Escape($PhpMajorMinor)
    $pattern = "^php_imagick-(\d+\.\d+\.\d+.*?)-$escapedVer(?:-.*)?-$Type-.*\.zip$"
    $candidates = @($Files | Where-Object { $_ -match $pattern })
    if ($candidates.Count -eq 0) { return $null }

    if ($Prefer64) {
        $candidates64 = @($candidates | Where-Object { $_ -match 'x86_64|x64' })
        if ($candidates64.Count -gt 0) { $candidates = $candidates64 }
    }

    $candidates = @($candidates | Where-Object { $_ -notmatch '(?i)(alpha|beta|rc)' })

    return $candidates | Sort-Object {
        $v = Get-VersionFromString -FileName $_ -PrefixPattern '^php_imagick-(\d+\.\d+\.\d+)'
        if ($null -eq $v) { [version]'0.0.0' } else { $v }
    } -Descending | Select-Object -First 1
}

function Find-LatestRdkafkaPackage {
    [CmdletBinding()]
    param(
        [string[]]$Files,
        [string]$PhpMajorMinor,
        [string]$Type,
        [bool]$Prefer64 = $true
    )

    $escapedVer = [regex]::Escape($PhpMajorMinor)
    $pattern = "^php_rdkafka-(\d+\.\d+\.\d+.*?)-$escapedVer(?:-.*)?-$Type-.*\.zip$"
    $candidates = @($Files | Where-Object { $_ -match $pattern })
    if ($candidates.Count -eq 0) { return $null }

    if ($Prefer64) {
        $candidates64 = @($candidates | Where-Object { $_ -match 'x86_64|x64' })
        if ($candidates64.Count -gt 0) { $candidates = $candidates64 }
    }

    $candidates = @($candidates | Where-Object { $_ -notmatch '(?i)(alpha|beta|rc)' })

    return $candidates | Sort-Object {
        $v = Get-VersionFromString -FileName $_ -PrefixPattern '^php_rdkafka-(\d+\.\d+\.\d+)'
        if ($null -eq $v) { [version]'0.0.0' } else { $v }
    } -Descending | Select-Object -First 1
}

function Find-LatestApachePackage {
    [CmdletBinding()]
    param(
        [string[]]$Files,
        [bool]$Prefer64 = $true
    )

    $candidatePattern = '^httpd-\d+\.\d+\.\d+.*\.zip$'
    $candidates = @($Files | Where-Object { $_ -match $candidatePattern })
    if ($candidates.Count -eq 0) { return $null }

    if ($Prefer64) {
        $win64Candidates = @($candidates | Where-Object { $_ -match 'Win64' })
        if ($win64Candidates.Count -gt 0) { $candidates = $win64Candidates }
    }

    $candidates = @($candidates | Where-Object { $_ -notmatch '(?i)(alpha|beta|rc)' })

    return $candidates | Sort-Object {
        $v = Get-VersionFromString -FileName $_ -PrefixPattern '^httpd-(\d+\.\d+\.\d+)'
        if ($null -eq $v) { [version]'0.0.0' } else { $v }
    }, {
        # Secondary sort by build date/stamp if present (e.g. 261002)
        if ($_ -match '^httpd-\d+\.\d+\.\d+-(\d+)') { [int64]$Matches[1] } else { 0 }
    } -Descending | Select-Object -First 1
}

function Find-LatestNginxPackage {
    [CmdletBinding()]
    param(
        [string[]]$Files,
        [string]$Branch = 'stable'
    )

    $candidatePattern = '^nginx-\d+\.\d+\.\d+\.zip$'
    $candidates = @($Files | Where-Object { $_ -match $candidatePattern })
    if ($candidates.Count -eq 0) { return $null }

    if ($Branch -eq 'stable') {
        $stable = @($candidates | Where-Object {
            $v = Get-VersionFromString -FileName $_ -PrefixPattern '^nginx-(\d+\.\d+\.\d+)\.zip$'
            if ($null -eq $v) { return $false }
            ($v.Minor % 2 -eq 0)
        })
        if ($stable.Count -gt 0) { $candidates = $stable }
    }
    elseif ($Branch -eq 'mainline') {
        $mainline = @($candidates | Where-Object {
            $v = Get-VersionFromString -FileName $_ -PrefixPattern '^nginx-(\d+\.\d+\.\d+)\.zip$'
            if ($null -eq $v) { return $false }
            ($v.Minor % 2 -ne 0)
        })
        if ($mainline.Count -gt 0) { $candidates = $mainline }
    }

    $candidates = @($candidates | Where-Object { $_ -notmatch '(?i)(alpha|beta|rc)' })

    return $candidates | Sort-Object {
        $v = Get-VersionFromString -FileName $_ -PrefixPattern '^nginx-(\d+\.\d+\.\d+)\.zip$'
        if ($null -eq $v) { [version]'0.0.0' } else { $v }
    } -Descending | Select-Object -First 1
}

# ==============================================================================
# 4. Report & Presentation Formatter
# ==============================================================================

function Show-UpdateReport {
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$Changes,
        [bool]$IsApplied
    )

    if ($null -eq $Changes -or $Changes.Count -eq 0) {
        Write-Host ""
        Write-Host "[OK] All checked source manifests are current. No updates detected." -ForegroundColor Green
        return
    }

    Write-Host ""
    Write-Host "=================================================================================" -ForegroundColor Cyan
    if ($IsApplied) {
        Write-Host " APPLIED UPDATES ($($Changes.Count) field(s) updated in manifests)" -ForegroundColor Green
    } else {
        Write-Host " DETECTED UPDATES ($($Changes.Count) newer package(s) available)" -ForegroundColor Yellow
    }
    Write-Host "=================================================================================" -ForegroundColor Cyan

    $formatString = "{0,-10} | {1,-12} | {2,-12} | {3,-36} -> {4}"
    Write-Host ([string]::Format($formatString, "Component", "Target", "Field", "Current Package", "Latest Discovered")) -ForegroundColor DarkGray
    Write-Host ("-" * 105) -ForegroundColor DarkGray

    foreach ($c in $Changes) {
        $comp = $c.Component
        $target = $c.Key
        $field = $c.Field
        $curr = if ($c.Current) { $c.Current } else { "(empty)" }
        $latest = $c.Latest

        $currDisp = if ($field -eq 'sha256' -and $curr.Length -gt 16) { $curr.Substring(0, 12) + "..." } else { $curr }
        $latestDisp = if ($field -eq 'sha256' -and $latest.Length -gt 16) { $latest.Substring(0, 12) + "..." } else { $latest }

        $color = if ($IsApplied) { 'Green' } else { 'Yellow' }
        Write-Host ([string]::Format($formatString, $comp, $target, $field, $currDisp, $latestDisp)) -ForegroundColor $color
    }

    Write-Host ("-" * 105) -ForegroundColor DarkGray

    if (-not $IsApplied) {
        Write-Host ""
        Write-Host "Tip: Run with -Update to apply changes, or execute Update-Base.bat for interactive mode." -ForegroundColor Cyan
    }
}

# ==============================================================================
# 5. Core Orchestration Engine
# ==============================================================================

function Invoke-BaseUpdater {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$Config,
        [ValidateSet('check', 'update')][string]$Action = 'check',
        [ValidateSet('all', 'php', 'apache', 'nginx', 'xdebug', 'imagick', 'rdkafka')][string]$Component = 'all',
        [string[]]$PhpVersion = $null,
        [switch]$Quiet,
        [switch]$PassThru
    )

    $baseUrl = Get-Content -LiteralPath $Config.ResolvedBaseUrlPath -Raw | ConvertFrom-Json
    $phpVersions = Get-Content -LiteralPath $Config.ResolvedJsonPath -Raw | ConvertFrom-Json

    $effectiveComponent = if ($Component) { $Component.ToLower() } else { $Config.Component }
    $effectivePhpVersion = if ($PhpVersion) { $PhpVersion } else { $Config.PhpVersion }

    $changes = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Step 1: Scan PHP Versions (PHP, Xdebug, Imagick, Rdkafka) ---
    $needsPhp = ($effectiveComponent -in 'all', 'php')
    $needsXdebug = ($effectiveComponent -in 'all', 'xdebug')
    $needsImagick = ($effectiveComponent -in 'all', 'imagick')
    $needsRdkafka = ($effectiveComponent -in 'all', 'rdkafka')

    if ($needsPhp -or $needsXdebug -or $needsImagick -or $needsRdkafka) {
        $phpArchiveFiles = if ($needsPhp) { Invoke-RemoteListing -Url $baseUrl.PHP -Quiet:$Quiet } else { @() }
        $phpReleaseFiles = if ($needsPhp) { Invoke-RemoteListing -Url $baseUrl.PHP_RELEASE -Quiet:$Quiet } else { @() }
        $phpChecksumMap  = if ($needsPhp) { Get-RemotePhpChecksumMap -BaseUrlRelease $baseUrl.PHP_RELEASE -Quiet:$Quiet } else { @{} }
        $xdebugFiles     = if ($needsXdebug) { Invoke-RemoteListing -Url 'https://xdebug.org/download' -Quiet:$Quiet } else { @() }

        $imagickBaseUrl = if ($baseUrl.PSObject.Properties['IMAGICK']) { $baseUrl.IMAGICK } else { 'https://windows.php.net/downloads/pecl/releases/imagick/' }
        $imagickFiles   = if ($needsImagick) { Get-RemoteImagickFiles -ImagickBaseUrl $imagickBaseUrl -Quiet:$Quiet } else { @() }

        $rdkafkaBaseUrl = if ($baseUrl.PSObject.Properties['RDKAFKA']) { $baseUrl.RDKAFKA } else { 'https://windows.php.net/downloads/pecl/releases/rdkafka/' }
        $rdkafkaFiles   = if ($needsRdkafka) { Get-RemoteRdkafkaFiles -RdkafkaBaseUrl $rdkafkaBaseUrl -Quiet:$Quiet } else { @() }

        foreach ($versionKey in $phpVersions.PSObject.Properties.Name) {
            if (-not (Test-PhpVersionMatch -VersionKey $versionKey -FilterList $effectivePhpVersion)) {
                continue
            }

            $entry = $phpVersions.$versionKey
            $currentPhpName = if ($entry.PSObject.Properties['name']) { $entry.name } else { $null }
            if (-not $currentPhpName) { continue }

            if ($currentPhpName -match '^php-(\d+\.\d+)\.\d+') {
                $phpMajorMinor = $Matches[1]
            } else {
                continue
            }

            $type = if ($currentPhpName -match '-(nts|ts)-') { $Matches[1] } else { 'nts' }

            # Check PHP package
            if ($needsPhp) {
                $downloadType = if ($entry.PSObject.Properties['download']) { $entry.download } else { 'archive' }
                $searchFiles = if ($downloadType -eq 'release') { $phpReleaseFiles } else { $phpArchiveFiles }
                $latestPhpName = Find-LatestPhpPackage -Files $searchFiles -PhpMajorMinor $phpMajorMinor -Type $type -Prefer64 $Config.Prefer64

                if ($latestPhpName) {
                    $tmpFolder = Join-Path $Config.ScriptRoot "tmp"
                    $latestSha = Get-PhpPackageSha256 -FileName $latestPhpName -RemoteChecksumMap $phpChecksumMap -TmpDir $tmpFolder
                    $currentSha = if ($entry.PSObject.Properties['sha256']) { $entry.sha256 } else { $null }

                    # 1. Update package filename if newer version discovered
                    if ($latestPhpName -ne $currentPhpName) {
                        $changes.Add([PSCustomObject]@{
                            Component = 'PHP'
                            Key       = $versionKey
                            Field     = 'name'
                            File      = $Config.ResolvedJsonPath
                            Current   = $currentPhpName
                            Latest    = $latestPhpName
                        })
                        if ($Action -eq 'update') {
                            $phpVersions.$versionKey.name = $latestPhpName
                        }
                    }

                    # 2. Update SHA-256 hash if available and different from current manifest
                    if (-not [string]::IsNullOrWhiteSpace($latestSha) -and ($latestSha -ne $currentSha)) {
                        $changes.Add([PSCustomObject]@{
                            Component = 'PHP'
                            Key       = $versionKey
                            Field     = 'sha256'
                            File      = $Config.ResolvedJsonPath
                            Current   = $currentSha
                            Latest    = $latestSha
                        })
                        if ($Action -eq 'update') {
                            $phpVersions.$versionKey.sha256 = $latestSha
                        }
                    }
                }
            }

            # Check Xdebug package
            if ($needsXdebug) {
                $currentXdebug = if ($entry.PSObject.Properties['xdebug']) { $entry.xdebug } else { $null }
                $latestXdebugName = Find-LatestXdebugPackage -Files $xdebugFiles -PhpMajorMinor $phpMajorMinor -Type $type -Prefer64 $Config.Prefer64
                if ($latestXdebugName -and $currentXdebug -ne $latestXdebugName) {
                    $changes.Add([PSCustomObject]@{
                        Component = 'Xdebug'
                        Key       = $versionKey
                        Field     = 'xdebug'
                        File      = $Config.ResolvedJsonPath
                        Current   = $currentXdebug
                        Latest    = $latestXdebugName
                    })
                    if ($Action -eq 'update') {
                        $phpVersions.$versionKey.xdebug = $latestXdebugName
                    }
                }
            }

            # Check Imagick package
            if ($needsImagick) {
                $currentImagick = if ($entry.PSObject.Properties['imagick']) { $entry.imagick } else { $null }
                $latestImagickName = Find-LatestImagickPackage -Files $imagickFiles -PhpMajorMinor $phpMajorMinor -Type $type -Prefer64 $Config.Prefer64
                if ($latestImagickName -and $currentImagick -ne $latestImagickName) {
                    $changes.Add([PSCustomObject]@{
                        Component = 'Imagick'
                        Key       = $versionKey
                        Field     = 'imagick'
                        File      = $Config.ResolvedJsonPath
                        Current   = $currentImagick
                        Latest    = $latestImagickName
                    })
                    if ($Action -eq 'update') {
                        $phpVersions.$versionKey.imagick = $latestImagickName
                    }
                }
            }

            # Check Rdkafka package
            if ($needsRdkafka) {
                $currentRdkafka = if ($entry.PSObject.Properties['rdkafka']) { $entry.rdkafka } else { $null }
                $latestRdkafkaName = Find-LatestRdkafkaPackage -Files $rdkafkaFiles -PhpMajorMinor $phpMajorMinor -Type $type -Prefer64 $Config.Prefer64
                if ($latestRdkafkaName -and $currentRdkafka -ne $latestRdkafkaName) {
                    $changes.Add([PSCustomObject]@{
                        Component = 'Rdkafka'
                        Key       = $versionKey
                        Field     = 'rdkafka'
                        File      = $Config.ResolvedJsonPath
                        Current   = $currentRdkafka
                        Latest    = $latestRdkafkaName
                    })
                    if ($Action -eq 'update') {
                        $phpVersions.$versionKey.rdkafka = $latestRdkafkaName
                    }
                }
            }
        }
    }

    # --- Step 2: Scan Apache HTTPD ---
    if ($effectiveComponent -in 'all', 'apache') {
        $apacheFiles = Invoke-RemoteListing -Url 'https://www.apachelounge.com/download/' -Quiet:$Quiet
        $latestApacheName = Find-LatestApachePackage -Files $apacheFiles -Prefer64 $Config.Prefer64

        $currentApacheBase = if ($baseUrl.PSObject.Properties['APACHE_BASE']) { $baseUrl.APACHE_BASE } else { $null }
        if ($latestApacheName -and $latestApacheName -ne $currentApacheBase) {
            $changes.Add([PSCustomObject]@{
                Component = 'Apache'
                Key       = 'APACHE'
                Field     = 'APACHE_BASE'
                File      = $Config.ResolvedBaseUrlPath
                Current   = $currentApacheBase
                Latest    = $latestApacheName
            })
            if ($Action -eq 'update') {
                $baseUrl.APACHE_BASE = $latestApacheName
            }
        }
    }

    # --- Step 3: Scan Nginx ---
    if ($effectiveComponent -in 'all', 'nginx') {
        $nginxUrl = if ($baseUrl.PSObject.Properties['NGINX']) { $baseUrl.NGINX } else { 'https://github.com/nginx/nginx/releases/download/' }
        $nginxFiles = Get-RemoteNginxReleases -NginxUrl $nginxUrl -Quiet:$Quiet
        $latestNginxName = Find-LatestNginxPackage -Files $nginxFiles -Branch $Config.NginxBranch

        $currentNginxBase = if ($baseUrl.PSObject.Properties['NGINX_BASE']) { $baseUrl.NGINX_BASE } else { $null }
        if ($latestNginxName -and $latestNginxName -ne $currentNginxBase) {
            $changes.Add([PSCustomObject]@{
                Component = 'Nginx'
                Key       = 'NGINX'
                Field     = 'NGINX_BASE'
                File      = $Config.ResolvedBaseUrlPath
                Current   = $currentNginxBase
                Latest    = $latestNginxName
            })
            if ($Action -eq 'update') {
                $baseUrl.NGINX_BASE = $latestNginxName
            }
        }
    }

    $changesArray = @($changes)

    # --- Step 4: Apply Writes if requested ---
    $isApplied = ($Action -eq 'update')
    if ($isApplied -and $changesArray.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess("source manifests", "Apply $($changesArray.Count) package updates")) {
            # Update php-versions.json if any PHP/Xdebug/Imagick field changed
            $phpChanges = @($changesArray | Where-Object { $_.File -eq $Config.ResolvedJsonPath })
            if ($phpChanges.Count -gt 0) {
                Save-JsonFile -Path $Config.ResolvedJsonPath -Data $phpVersions
                Write-Host "Saved updated manifest: $($Config.ResolvedJsonPath)" -ForegroundColor Green
            }

            # Update baseUrl.json if APACHE_BASE or NGINX_BASE changed
            $baseUrlChanges = @($changesArray | Where-Object { $_.File -eq $Config.ResolvedBaseUrlPath })
            if ($baseUrlChanges.Count -gt 0) {
                Save-JsonFile -Path $Config.ResolvedBaseUrlPath -Data $baseUrl
                Write-Host "Saved updated base URLs: $($Config.ResolvedBaseUrlPath)" -ForegroundColor Green
            }
        }
    }

    # Display report table
    Show-UpdateReport -Changes $changesArray -IsApplied $isApplied

    if ($PassThru) {
        return $changesArray
    }
}

# ==============================================================================
# 6. Interactive UI Menu System
# ==============================================================================

function Pause-Console {
    Write-Host ""
    Write-Host "Press Enter to return to menu..." -ForegroundColor DarkGray
    [void][System.Console]::ReadLine()
}

function Show-InteractiveMenu {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    while ($true) {
        Clear-Host
        Write-Host "===================================================" -ForegroundColor Cyan
        Write-Host " Upstream Package Update Manager" -ForegroundColor White
        Write-Host " Manifest  : $($Config.ResolvedJsonPath)" -ForegroundColor DarkGray
        Write-Host " Base URLs : $($Config.ResolvedBaseUrlPath)" -ForegroundColor DarkGray
        Write-Host " Settings  : Arch: $(if ($Config.Prefer64) { 'x64' } else { 'x86' }) | Nginx Branch: $($Config.NginxBranch)" -ForegroundColor DarkGray
        Write-Host "===================================================" -ForegroundColor Cyan
        Write-Host " Global Operations:" -ForegroundColor Yellow
        Write-Host " [1] Check All Upstream Releases (Dry-Run)"
        Write-Host " [2] Apply All Available Updates (-Update)"
        Write-Host ""
        Write-Host " Component-Specific Scan:" -ForegroundColor Yellow
        Write-Host " [3] Check / Update PHP Packages"
        Write-Host " [4] Check / Update Apache HTTPD"
        Write-Host " [5] Check / Update Nginx"
        Write-Host " [6] Check / Update Xdebug Only"
        Write-Host " [7] Check / Update Imagick PECL Only"
        Write-Host " [8] Check / Update Rdkafka PECL Only"
        Write-Host " [9] Check / Update Specific PHP Version (e.g. 8.2, 8.4)"
        Write-Host ""
        Write-Host " Configuration Settings:" -ForegroundColor Yellow
        Write-Host " [10] Toggle Nginx Branch (Current: $($Config.NginxBranch))"
        Write-Host " [11] Toggle Architecture Preference (Current: $(if ($Config.Prefer64) { 'x64' } else { 'x86' }))"
        Write-Host " [0] Exit"
        Write-Host "---------------------------------------------------" -ForegroundColor DarkGray

        $choice = Read-Host "Select option [0-11]"
        switch ($choice) {
            '1' {
                Invoke-BaseUpdater -Config $Config -Action 'check' -Component 'all'
                Pause-Console
            }
            '2' {
                $confirm = Read-Host "Are you sure you want to apply all detected updates to source manifests? (y/N)"
                if ($confirm -match '^(y|yes)$') {
                    Invoke-BaseUpdater -Config $Config -Action 'update' -Component 'all'
                } else {
                    Write-Host "Update cancelled." -ForegroundColor Yellow
                }
                Pause-Console
            }
            '3' {
                $subChoice = Read-Host "PHP Packages: [1] Dry-Run Check, [2] Apply Updates. Select [1/2]"
                $act = if ($subChoice -eq '2') { 'update' } else { 'check' }
                Invoke-BaseUpdater -Config $Config -Action $act -Component 'php'
                Pause-Console
            }
            '4' {
                $subChoice = Read-Host "Apache HTTPD: [1] Dry-Run Check, [2] Apply Updates. Select [1/2]"
                $act = if ($subChoice -eq '2') { 'update' } else { 'check' }
                Invoke-BaseUpdater -Config $Config -Action $act -Component 'apache'
                Pause-Console
            }
            '5' {
                $subChoice = Read-Host "Nginx Server: [1] Dry-Run Check, [2] Apply Updates. Select [1/2]"
                $act = if ($subChoice -eq '2') { 'update' } else { 'check' }
                Invoke-BaseUpdater -Config $Config -Action $act -Component 'nginx'
                Pause-Console
            }
            '6' {
                $subChoice = Read-Host "Xdebug: [1] Dry-Run Check, [2] Apply Updates. Select [1/2]"
                $act = if ($subChoice -eq '2') { 'update' } else { 'check' }
                Invoke-BaseUpdater -Config $Config -Action $act -Component 'xdebug'
                Pause-Console
            }
            '7' {
                $subChoice = Read-Host "Imagick PECL: [1] Dry-Run Check, [2] Apply Updates. Select [1/2]"
                $act = if ($subChoice -eq '2') { 'update' } else { 'check' }
                Invoke-BaseUpdater -Config $Config -Action $act -Component 'imagick'
                Pause-Console
            }
            '8' {
                $subChoice = Read-Host "Rdkafka PECL: [1] Dry-Run Check, [2] Apply Updates. Select [1/2]"
                $act = if ($subChoice -eq '2') { 'update' } else { 'check' }
                Invoke-BaseUpdater -Config $Config -Action $act -Component 'rdkafka'
                Pause-Console
            }
            '9' {
                $targetVer = Read-Host "Enter PHP Version (e.g. 8.2 or 82)"
                if (-not [string]::IsNullOrWhiteSpace($targetVer)) {
                    $apply = Read-Host "Apply updates if found? (y/N)"
                    $act = if ($apply -match '^(y|yes)$') { 'update' } else { 'check' }
                    Invoke-BaseUpdater -Config $Config -Action $act -Component 'all' -PhpVersion @($targetVer)
                    Pause-Console
                }
            }
            '10' {
                $Config.NginxBranch = if ($Config.NginxBranch -eq 'stable') { 'mainline' } else { 'stable' }
                Write-Host "Nginx release branch set to: $($Config.NginxBranch)" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            '11' {
                $Config.Prefer64 = -not $Config.Prefer64
                Write-Host "Architecture preference set to: $(if ($Config.Prefer64) { 'x64' } else { 'x86' })" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            '0' {
                return
            }
            default {
                Write-Host "Invalid choice, please select between 0 and 11." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ==============================================================================
# 7. Entrypoint Execution
# ==============================================================================

$config = Get-UpdateConfig `
    -CliParams $PSBoundParameters `
    -CliJsonPath $JsonPath `
    -CliBaseUrlPath $BaseUrlPath `
    -CliNginxBranch $NginxBranch `
    -CliPrefer64 $Prefer64 `
    -CliComponent $Component `
    -CliPhpVersion $PhpVersion

# Determine final action
$finalAction = $Action
if ($Update) { $finalAction = 'update' }
if ($Menu)   { $finalAction = 'menu' }

if ($finalAction -eq 'menu') {
    Show-InteractiveMenu -Config $config
} else {
    Invoke-BaseUpdater `
        -Config $config `
        -Action $finalAction `
        -Component $config.Component `
        -PhpVersion $config.PhpVersion `
        -Quiet:$Quiet `
        -PassThru:$PassThru
}
