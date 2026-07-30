# php-apache-installer

## Install

Basic installation steps and examples for Windows using the bundled installer script:

- Script: `install.ps1` (top-level)
- Config: the installer reads `source/php-versions.json`, `source/baseUrl.json`, and config helpers in the repo.

Requirements:

- **OS**: Windows 10 or later (recommended). Some helper tools such as the Windows Package Manager (`winget`) and the bundled `curl.exe` are available on recent Windows builds.
- **PowerShell**: Recommended: PowerShell 7+ (`pwsh`). Windows PowerShell 5.1 (`powershell`) usually works for most operations but examples use `pwsh`.
- **Internet access**: Required to download PHP, Xdebug, Imagick, Apache/Nginx, Composer and other packages.
- **Download tool**: `curl` is used by the scripts for robust downloads (Windows 10+ includes `curl.exe`). If `curl` is not available, install it or ensure an equivalent download tool is present in PATH.
- **Archive extraction**: The scripts use PowerShell's `Expand-Archive` to extract ZIP files; 7-Zip is not required.
- **Windows Package Manager (winget)**: Optional — used only when importing the Visual C++ Redistributables via [source/winget-VCRedist.json](source/winget-VCRedist.json). If you don't have `winget`, install the appropriate Visual C++ Redistributables manually.
- **Administrator privileges**: Required for system-level actions such as registering PATH entries and for `winget import`.
- **Disk space & temp**: The installer downloads files into a `tmp` folder under the working directory; ensure sufficient free disk space.

Notes:
- PHP binaries distributed here depend on the matching Visual C++ runtime for the MSVC toolset used to build that PHP release (e.g. "VS17" builds). Use the `winget` import above or manually install the correct Visual C++ Redistributable for your target PHP builds.
- The update helper is at [Update-PHPVersions.ps1](Update-PHPVersions.ps1) and reads [source/baseUrl.json](source/baseUrl.json) to locate downloads on `windows.php.net` (PHP and Imagick PECL releases) and `xdebug.org`.

Quick checks:

```powershell
# Check PowerShell (pwsh) first, fallback to Windows PowerShell if needed
pwsh -NoProfile -Command "$PSVersionTable.PSVersion"  # PowerShell 7+
powershell -NoProfile -Command "$PSVersionTable.PSVersion"  # Windows PowerShell 5.1

# Check winget (optional, used for VCRedist import)
winget --version

# Check curl availability
curl --version
```

Quick examples:

```powershell
# Default run (use current directory as install root)
pwsh -NoProfile .\install.ps1

# Download PHP only (set environment flags before running)
$env:DOWNLOAD_PHP = '1'
pwsh -NoProfile .\install.ps1

# Install Composer and register PHP path
$env:INSTALL_COMPOSER = '1'
$env:REGISTER_PATH_PHP = '1'
pwsh -NoProfile .\install.ps1

# Set a custom install directory
$env:INSTALL_DIR = 'C:\web\php-apache'
pwsh -NoProfile .\install.ps1
```

Notes:

- Use environment variables (1/true/on) to enable features. See `install.ps1` for full list of flags.
- `source/php-versions.json` controls which PHP versions and filenames the installer will download. Use `Update-PHPVersions.ps1` to refresh those filenames.
- The installer creates a `tmp` directory in the working directory for downloads; enable `$env:CLEAN_TMP_DIR` to remove it after the run.

### PowerShell notes & links

- Recommended: use PowerShell 7+ (`pwsh`) for best compatibility with the examples in this repo.
- Windows built-in PowerShell 5.1 (`powershell`) usually works for basic operations — replace `pwsh` with `powershell` in examples if you don't have PowerShell 7 installed.
- Check installed versions:

```powershell
# Windows PowerShell (5.1)
powershell -NoProfile -Command "$PSVersionTable.PSVersion"

# PowerShell 7+ (pwsh)
pwsh -NoProfile -Command "$PSVersionTable.PSVersion"
```

- Install PowerShell 7 (example):

```powershell
# Install via winget
winget install --id Microsoft.PowerShell -e

# Or download from GitHub releases
# https://github.com/PowerShell/PowerShell/releases
```

Useful links:

- PowerShell docs: https://learn.microsoft.com/powershell/
- PowerShell releases: https://github.com/PowerShell/PowerShell/releases
- winget (Windows Package Manager): https://learn.microsoft.com/windows/package-manager/

## Update script

A small reference PowerShell script is included to check and update the PHP/Xdebug package names listed in `source/php-versions.json`.

- Script path: `Update-PHPVersions.ps1`
- Purpose: discover latest package filenames on windows.php.net and xdebug.org and optionally write them back to the JSON file.

Usage examples:

```powershell
# Check for updates (no write)
pwsh -NoProfile .\Update-PHPVersions.ps1

# Apply detected updates to JSON and environment sample (default prefers 64-bit packages)
pwsh -NoProfile .\Update-PHPVersions.ps1 -Update

# Apply updates but do NOT prefer x64 (choose any matching architecture)
pwsh -NoProfile .\Update-PHPVersions.ps1 -Update -Prefer64:$false

# Apply updates and target a different env sample file (relative to script)
pwsh -NoProfile .\Update-PHPVersions.ps1 -Update -EnvPath ".\.env.sample"
```

Notes:
- The script reads `source/baseUrl.json` to locate PHP and Xdebug directories and now also checks https://www.apachelounge.com/download/ to detect newer `APACHE_BASE` filenames.
- When run with `-Update` the script will update `APACHE_BASE` inside the specified env sample file (default: `.\.env.sample`) and will also update `../.env` if that file exists.
- By default the script prefers x64 (x86_64) binaries when available. Use `-Prefer64:$false` to disable.
- This script is a convenience/reference tool; review changes before committing.
