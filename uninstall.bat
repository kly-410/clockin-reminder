@echo off
rem Uninstall clockin reminder (stop process -> remove autostart -> remove data)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
pause
