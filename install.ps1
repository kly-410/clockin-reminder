<#
  install.ps1  —  一键安装打卡提醒工具（Windows）
  用法：powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
  或右键「使用 PowerShell 运行」。
  作用：
    1. 拷贝 clockin-reminder.ps1、manual-clockin.ps1 到 %USERPROFILE%\.clockin-reminder\
    2. 注册开机自启（HKCU Run，无需管理员）
    3. 立即启动常驻脚本
  说明：report.ps1 不用安装，拷到任意目录命令行运行即可（数据读 %USERPROFILE%\.clockin-reminder\）
#>

$ErrorActionPreference = 'Stop'

$srcDir    = $PSScriptRoot
$dstDir    = Join-Path $env:USERPROFILE '.clockin-reminder'
$scriptPath = Join-Path $dstDir 'clockin-reminder.ps1'

# 0. 停掉旧实例（按命令行匹配，避免重复实例双弹窗；兼容 powershell.exe 和 pwsh.exe）
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*clockin-reminder.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 1. 拷贝主脚本 + 手动打卡脚本
if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
Copy-Item (Join-Path $srcDir 'clockin-reminder.ps1') $scriptPath -Force
Copy-Item (Join-Path $srcDir 'manual-clockin.ps1') (Join-Path $dstDir 'manual-clockin.ps1') -Force

# 2. 注册开机自启（HKCU Run，无需管理员）
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$cmd = 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
Set-ItemProperty -Path $runKey -Name 'ClockinReminder' -Value $cmd

# 3. 立即启动
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`""

Write-Host ''
Write-Host '[OK] 打卡提醒工具已安装并启动' -ForegroundColor Green
Write-Host "  脚本目录 : $dstDir"
Write-Host '  手动打卡 : 双击 manual-clockin.ps1（周末加班记录）'
Write-Host '  统计报告 : powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1'
Write-Host '  测试方法 : Win+L 锁屏再解锁，应弹出上班打卡提醒'
