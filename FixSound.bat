@echo off
title BloodTrail Desktop - Fix sound
echo Start Blood Trail first. This unmutes the game in the Windows Volume Mixer.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\fix_sound.ps1"
echo.
pause
