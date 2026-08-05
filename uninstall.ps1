<#
  uninstall.ps1  —  一键卸载打卡提醒工具（Windows）
  用法：powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
  或双击运行。
  作用：
    1. 停掉常驻进程（clockin-reminder.ps1）
    2. 删除开机自启项（HKCU Run）
    3. 删除数据（log 文件夹 = 周记录/配置/状态/日志，R38 数据统一在 log；可保留，重装后自动恢复）
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

# 3. 删除数据文件（log 文件夹 = 全部数据：周记录/配置/状态/日志；R38 数据统一在 log）
# 重装恢复：只要不删 log 文件夹，重装后主脚本自动读取 log 里的数据（config/state/周记录）
$dataDir = $PSScriptRoot
if (Test-Path $dataDir) {
    $resp = Read-Host '  是否删除 log 文件夹（含全部打卡记录/配置/状态/日志）？Y=删除 / N=保留（推荐，重装后自动恢复数据）'
    if ($resp -match '^[Yy]') {
        Remove-Item (Join-Path $dataDir 'log') -Recurse -Force -ErrorAction SilentlyContinue
        # 老版本残留：根目录旧 config.json / state.json / log.txt / history.csv（R38 前数据在根目录）
        foreach ($df in @('config.json', 'state.json', 'log.txt', 'history.csv')) {
            Remove-Item (Join-Path $dataDir $df) -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  已删除数据（log 文件夹 + 根目录旧版残留文件）"
    } else {
        Write-Host "  保留数据（log 文件夹未动；重装后自动恢复打卡记录/配置）"
    }
} else {
    Write-Host '  数据目录不存在'
}

Write-Host ''
Write-Host '[OK] 卸载完成' -ForegroundColor Green
Write-Host '  脚本目录（本项目文件夹）需手动删除。'
