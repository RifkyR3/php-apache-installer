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
- The update helper is at [Update-Base.ps1](Update-Base.ps1) and reads [source/baseUrl.json](source/baseUrl.json) to locate downloads on `windows.php.net` (PHP and Imagick PECL releases), `xdebug.org`, and `apachelounge.com`.

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

### Installation Methods:

#### 1. Interactive Menu (Recommended for Beginners & Quick Setups)
Double-click `install.bat` in Windows Explorer or run:
```powershell
pwsh -NoProfile .\install.ps1 -Menu
```
Includes easy presets:
- **Standard Installation**: Executes full configuration defined in `.env`.
- **Modern PHP Stack**: Fast setup for PHP 8.2, 8.3, and 8.4 with Apache and Composer.
- **Single PHP Version**: Interactively pick and install one specific PHP version.
- **Web Server Only**: Install or reconfigure Apache HTTPD or Nginx server.
- **Custom Wizard**: Step-by-step interactive configuration prompt.
- **Pre-Flight Check**: Verify downloaded package cache and archive integrity in `tmp/`.

#### 2. CLI Automation Examples:
```powershell
# Standard automated run based on .env
pwsh -NoProfile .\install.ps1

# Pre-flight package verification (check cached archives without installing)
pwsh -NoProfile .\install.ps1 -Check

# Install modern PHP versions only
pwsh -NoProfile .\install.ps1 -PhpVersions "v8.2, v8.3, v8.4" -InstallApache:$true

# Single PHP version install
pwsh -NoProfile .\install.ps1 -PhpVersions "v8.2" -InstallApache:$false

# Safe simulation / dry-run with WhatIf
pwsh -NoProfile .\install.ps1 -WhatIf
```

Notes:

- Use environment variables (1/true/on) to enable features. See `install.ps1` for full list of flags.
- `source/php-versions.json` controls which PHP versions and filenames the installer will download. Use `Update-Base.ps1` to refresh those filenames.
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

## Upstream Package Update Helper

A modular PowerShell script and batch launcher to check and update package versions defined in `source/php-versions.json` and `source/baseUrl.json`.

- **Script**: [Update-Base.ps1](file:///d:/Program/web/php-apache-installer/Update-Base.ps1)
- **Batch Launcher**: [Update-Base.bat](file:///d:/Program/web/php-apache-installer/Update-Base.bat)
- **Supported Sources**: `windows.php.net` (PHP releases & PECL Imagick), `xdebug.org`, `apachelounge.com` (Apache HTTPD), and `github.com/nginx` (Nginx releases).

### Quick Interactive Menu:
Double-click `Update-Base.bat` or run:
```powershell
pwsh -NoProfile .\Update-Base.ps1 -Menu
```

### CLI Automation Examples:
```powershell
# Check for updates across all packages (dry-run detection table)
pwsh -NoProfile .\Update-Base.ps1

# Apply detected updates to source manifests
pwsh -NoProfile .\Update-Base.ps1 -Update

# Check/update specific components only (apache, nginx, php, xdebug, imagick)
pwsh -NoProfile .\Update-Base.ps1 -Component apache -Update
pwsh -NoProfile .\Update-Base.ps1 -Component nginx -NginxBranch mainline -Update

# Target specific PHP version(s)
pwsh -NoProfile .\Update-Base.ps1 -PhpVersion 8.2 -Component php
pwsh -NoProfile .\Update-Base.ps1 -PhpVersion 82,84 -Update

# Safe execution with WhatIf
pwsh -NoProfile .\Update-Base.ps1 -Update -WhatIf
```

## Portable Control Panel (XAMPP-Style)

Manage Apache and PHP portably without administrative privileges or Windows services:

- **Quick Launch**: Double-click `control.bat` or run:
  ```powershell
  pwsh -NoProfile .\control.ps1
  ```
- **CLI Commands**:
  - `.\control.ps1 start` : Start Apache web server in user-space.
  - `.\control.ps1 stop` : Stop Apache web server.
  - `.\control.ps1 restart` : Restart Apache web server.
  - `.\control.ps1 status` : Check running status and active PIDs.
  - `.\control.ps1 open` : Open browser to default dashboard (`http://localhost:8082`).
  - `.\control.ps1 htdocs` : Open `apache/htdocs` folder in Windows Explorer.
  - `.\control.ps1 shell [version]` : Launch isolated shell with PHP (default 8.2) and Composer in PATH.
  - `.\control.ps1 sync` : Synchronize paths from `.env` (or defaults) to Apache config.
  - `.\control.ps1 gui` : Open native Windows Forms GUI control panel.

