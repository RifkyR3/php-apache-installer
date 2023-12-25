@echo OFF
:: in case DelayedExpansion is on and a path contains ! 
setlocal DISABLEDELAYEDEXPANSION
%~dp0php.exe "%~dp0composer.phar" %*
