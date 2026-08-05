@echo off
rem 打开手动打卡/补录工具（双击即可：选日期、选上班/下班卡、填时间）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0manual-clockin.ps1"
