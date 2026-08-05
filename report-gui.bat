@echo off
rem Open clockin stats report (GUI + auto save CSV to log\report-<date>.csv)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0report.ps1" -Gui -Save
