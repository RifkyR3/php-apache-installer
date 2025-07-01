@echo off
title Nginx and PHP Manager
color 0f

:menu
cls
echo ****************************************
echo *       Nginx and PHP Manager         *
echo ****************************************
echo.
echo [1] Start all servers
echo [2] Stop all servers
echo [3] Restart all servers
echo [4] Check server status
echo [5] Exit
echo.
set /p choice=Enter your choice (1-5): 

if "%choice%"=="1" goto start_servers
if "%choice%"=="2" goto stop_servers
if "%choice%"=="3" goto restart_servers
if "%choice%"=="4" goto check_status
if "%choice%"=="5" exit

echo Invalid choice. Please try again.
pause
goto menu

:start_servers
cls
echo Starting all servers...
echo.

:: Start Nginx
tasklist /FI "IMAGENAME eq nginx.exe" | find /i "nginx.exe" > nul
if %ERRORLEVEL% equ 0 (
    echo [INFO] Nginx is already running!
) else (
    echo [STARTING] Nginx...
    start "Nginx" /D "{{ROOT}}" "{{ROOT}}\nginx.exe"
)

:: Start PHP processes
echo.
echo Starting PHP FastCGI processes...

tasklist /FI "IMAGENAME eq php-cgi.exe" | find /i "php-cgi.exe" > nul
if %ERRORLEVEL% equ 0 (
    echo [INFO] PHP processes are already running!
) else (
    if exist "C:\webserver\PHP\84\" (
        echo [STARTING] PHP 8.4 on port 9184...
        start "PHP 8.4" /D "C:\webserver\PHP\84" "C:\webserver\PHP\84\php-cgi.exe" -b 127.0.0.1:9184 -c "C:\webserver\PHP\84\php.ini"
    )

    if exist "C:\webserver\PHP\83\" (
        echo [STARTING] PHP 8.3 on port 9183...
        start "PHP 8.3" /D "C:\webserver\PHP\83" "C:\webserver\PHP\83\php-cgi.exe" -b 127.0.0.1:9183 -c "C:\webserver\PHP\83\php.ini"
    )
    
    if exist "C:\webserver\PHP\82\" (
        echo [STARTING] PHP 8.2 on port 9182...
        start "PHP 8.2" /D "C:\webserver\PHP\82" "C:\webserver\PHP\82\php-cgi.exe" -b 127.0.0.1:9182 -c "C:\webserver\PHP\82\php.ini"
    )
    
    if exist "C:\webserver\PHP\81\" (
        echo [STARTING] PHP 8.1 on port 9181...
        start "PHP 8.1" /D "C:\webserver\PHP\81" "C:\webserver\PHP\81\php-cgi.exe" -b 127.0.0.1:9181 -c "C:\webserver\PHP\81\php.ini"
    )
    
    if exist "C:\webserver\PHP\80\" (
        echo [STARTING] PHP 8.0 on port 9180...
        start "PHP 8.0" /D "C:\webserver\PHP\80" "C:\webserver\PHP\80\php-cgi.exe" -b 127.0.0.1:9180 -c "C:\webserver\PHP\80\php.ini"
    )
    
    if exist "C:\webserver\PHP\74\" (
        echo [STARTING] PHP 7.4 on port 9174...
        start "PHP 7.4" /D "C:\webserver\PHP\74" "C:\webserver\PHP\74\php-cgi.exe" -b 127.0.0.1:9174 -c "C:\webserver\PHP\74\php.ini"
    )
    
    if exist "C:\webserver\PHP\73\" (
        echo [STARTING] PHP 7.3 on port 9173...
        start "PHP 7.3" /D "C:\webserver\PHP\73" "C:\webserver\PHP\73\php-cgi.exe" -b 127.0.0.1:9173 -c "C:\webserver\PHP\73\php.ini"
    )
    
    if exist "C:\webserver\PHP\72\" (
        echo [STARTING] PHP 7.2 on port 9172...
        start "PHP 7.2" /D "C:\webserver\PHP\72" "C:\webserver\PHP\72\php-cgi.exe" -b 127.0.0.1:9172 -c "C:\webserver\PHP\72\php.ini"
    )
    
    if exist "C:\webserver\PHP\71\" (
        echo [STARTING] PHP 7.1 on port 9171...
        start "PHP 7.1" /D "C:\webserver\PHP\71" "C:\webserver\PHP\71\php-cgi.exe" -b 117.0.0.1:9171 -c "C:\webserver\PHP\71\php.ini"
    )
    
    if exist "C:\webserver\PHP\70\" (
        echo [STARTING] PHP 7.0 on port 9170...
        start "PHP 7.0" /D "C:\webserver\PHP\70" "C:\webserver\PHP\70\php-cgi.exe" -b 117.0.0.1:9170 -c "C:\webserver\PHP\70\php.ini"
    )
    
    if exist "C:\webserver\PHP\56\" (
        echo [STARTING] PHP 5.6 on port 9156...
        start "PHP 5.6" /D "C:\webserver\PHP\56" "C:\webserver\PHP\56\php-cgi.exe" -b 117.0.0.1:9156 -c "C:\webserver\PHP\56\php.ini"
    )
    
    if exist "C:\webserver\PHP\55\" (
        echo [STARTING] PHP 5.5 on port 9155...
        start "PHP 5.5" /D "C:\webserver\PHP\55" "C:\webserver\PHP\55\php-cgi.exe" -b 117.0.0.1:9155 -c "C:\webserver\PHP\55\php.ini"
    )
    
    if exist "C:\webserver\PHP\54\" (
        echo [STARTING] PHP 5.5 on port 9154...
        start "PHP 5.5" /D "C:\webserver\PHP\54" "C:\webserver\PHP\54\php-cgi.exe" -b 117.0.0.1:9154 -c "C:\webserver\PHP\54\php.ini"
    )
    
)

echo.
echo [SUCCESS] All servers started!
echo Nginx running on:
echo - Port 8084 with PHP 8.4
echo - Port 8083 with PHP 8.3
echo - Port 8082 with PHP 8.2
echo - Port 8081 with PHP 8.1
echo - Port 8080 with PHP 8.0
echo - Port 8074 with PHP 7.4
echo - Port 8073 with PHP 7.3
echo - Port 8072 with PHP 7.2
echo - Port 8071 with PHP 7.1
echo - Port 8070 with PHP 7.0
echo - Port 8056 with PHP 5.6
echo - Port 8055 with PHP 5.5
echo - Port 8054 with PHP 5.4
pause
goto menu

:stop_servers
cls
echo Stopping all servers...
echo.

:: Stop Nginx
taskkill /IM "nginx.exe" /F > nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [STOPPED] Nginx
) else (
    echo [INFO] Nginx was not running
)

:: Stop PHP processes
echo.
echo Stopping PHP processes...
taskkill /IM "php-cgi.exe" /F > nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [STOPPED] All PHP processes
) else (
    echo [INFO] No PHP processes were running
)

echo.
echo [SUCCESS] All servers stopped
pause
goto menu

:restart_servers
cls
call :stop_servers
timeout /t 2 > nul
call :start_servers
goto menu

:check_status
cls
echo Server Status:
echo.

:: Check Nginx
tasklist /FI "IMAGENAME eq nginx.exe" | find /i "nginx.exe" > nul
if %ERRORLEVEL% equ 0 (
    echo [RUNNING] Nginx
) else (
    echo [STOPPED] Nginx
)

:: Check PHP processes
echo.
echo PHP Processes:
tasklist /FI "IMAGENAME eq php-cgi.exe" | find /i "php-cgi.exe" > nul
if %ERRORLEVEL% equ 0 (
    tasklist /FI "IMAGENAME eq php-cgi.exe"
    echo [RUNNING] PHP processes running
) else (
    echo [STOPPED] No PHP processes running
)

echo.
pause
goto menu