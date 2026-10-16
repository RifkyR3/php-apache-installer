@echo off
setlocal
where pwsh >nul 2>&1
if %errorlevel% equ 0 (
    if "%~1"=="" (
        pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Base.ps1" -Menu
    ) else (
        pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Base.ps1" %*
    )
) else (
    if "%~1"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Base.ps1" -Menu
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Base.ps1" %*
    )
)
