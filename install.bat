@echo off
rem 双击安装打卡提醒工具（弹配置表单 → 安装 → 开机自启 → 启动）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
