@echo off
rem 双击查看打卡统计报告（GUI 窗口）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0report.ps1" -Gui
