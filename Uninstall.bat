@echo off
title BloodTrail Desktop - Uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\install.ps1" -Uninstall %*
echo.
pause
