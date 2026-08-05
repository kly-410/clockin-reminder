@echo off
rem 双击卸载打卡提醒工具（停进程 → 删开机自启 → 删数据）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
pause
