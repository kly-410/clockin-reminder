@echo off
rem Install clockin reminder (config form -> install -> autostart -> launch)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
