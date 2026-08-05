@echo off
rem Open config GUI to edit clockin defaults (config.json)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0config-gui.ps1"
