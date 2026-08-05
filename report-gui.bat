@echo off
rem 双击查看打卡统计报告（GUI 窗口 + 自动保存统计到 log\report-日期.csv）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0report.ps1" -Gui -Save
