@echo off
rem 双击查看打卡程序运行状态（GUI 窗口）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0status.ps1" -Gui
