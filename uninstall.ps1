<#
  uninstall.ps1  —  一键卸载打卡提醒工具（Windows）
  用法：powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
  或双击运行。
  作用：
    1. 停掉常驻进程（clockin-reminder.ps1）
    2. 删除开机自启项（HKCU Run）
    3. 删除数据文件（log 文件夹 / log.txt / history.csv / state.json / config.json，R31 数据与脚本同目录）
#>

$ErrorActionPreference = 'Continue'   # 卸载尽量别中断

Write-Host ''
Write-Host '正在卸载打卡提醒工具...'

# 1. 停掉常驻进程（兼容 powershell.exe 和 pwsh.exe）
$proc = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*clockin-reminder.ps1*' }
foreach ($p in $proc) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "  已停止进程 PID $($p.ProcessId)" } catch { }
}

# 2. 删除开机自启项
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Get-ItemProperty -Path $runKey -Name 'ClockinReminder' -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -Path $runKey -Name 'ClockinReminder' -ErrorAction SilentlyContinue
    Write-Host '  已删除开机自启项 ClockinReminder'
} else {
    Write-Host '  开机自启项不存在（已删除或无）'
}

# 3. 删除数据文件（含历史打卡记录，谨慎；log 周文件在 log 子文件夹里，一并删除，R28）
# R31: 数据与脚本同目录 → 只删数据文件，保留脚本本身（uninstall.ps1 正在运行，不能删整个目录）
$dataDir = $PSScriptRoot
if (Test-Path $dataDir) {
    # 备份提示：数据删除不可恢复
    $resp = Read-Host '  是否删除历史数据（log 文件夹/周文件/history.csv/state.json/config.json）？Y=删除 / N=保留'
    if ($resp -match '^[Yy]') {
        Remove-Item (Join-Path $dataDir 'log') -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($df in @('log.txt', 'history.csv', 'state.json', 'config.json')) {
            Remove-Item (Join-Path $dataDir $df) -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  已删除数据文件（目录 $dataDir 中的 log/ log.txt history.csv state.json config.json）"
    } else {
        Write-Host "  保留数据文件（$dataDir）"
    }
} else {
    Write-Host '  数据目录不存在'
}

Write-Host ''
Write-Host '[OK] 卸载完成' -ForegroundColor Green
Write-Host '  脚本目录（本项目文件夹）需手动删除。'
