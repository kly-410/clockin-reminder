<#
  install.ps1  —  一键安装打卡提醒工具（Windows）v8
  用法：powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
  或右键「使用 PowerShell 运行」。
  作用：
    0. 弹配置表单（可改配置，确定后写 config.json）
    1. 就地安装（R31）：脚本留在当前目录，数据也写当前目录（不再拷贝到 %USERPROFILE%）
    2. 注册开机自启（HKCU Run，无需管理员）
    3. 立即启动常驻脚本
  说明：report.ps1 不用安装，与主脚本同目录运行即可（数据读脚本同目录）
  R22：安装前先弹 WinForms 配置表单；预填已存在的 config.json（重装时保留当前配置）
  R30：启动新实例后轮询 3 秒确认进程存活（旧 Mutex 未释放导致新实例退出的问题）
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$srcDir    = $PSScriptRoot
$dstDir    = $PSScriptRoot   # R31: 就地安装——数据与代码同目录，方便查找（不再拷到 %USERPROFILE%）
$scriptPath = Join-Path $dstDir 'clockin-reminder.ps1'
$configFile = Join-Path $dstDir 'log\config.json'        # R38: 配置统一放 log 文件夹
$legacyConfigFile = Join-Path $dstDir 'config.json'      # R38: 老版本根目录配置，兼容读取预填

# R38: 配置路径解析——优先 log\config.json；不存在且根目录有旧 config.json 时用旧的（老版本升级场景）
function Resolve-ConfigPath {
    if (Test-Path $configFile) { return $configFile }
    if (Test-Path $legacyConfigFile) { return $legacyConfigFile }
    return $configFile
}

# ============ R22: 配置表单 ============
# 默认配置（与主脚本 clockin-reminder.ps1 的 DefaultConfig 保持一致）
$script:DefaultConfig = @{
    OffWorkHours             = 10
    WorkWindowStart          = 8
    WorkWindowEnd            = 10
    WorkAutoPopupEnd         = 12
    SkipWeekend              = $true
    ReRemindIntervalMinutes  = 30
    MaxRemindHour            = 23
}

# 读已有 config.json 预填（支持重装时保留当前配置）；文件不存在/解析失败用默认
function Read-ExistingConfig {
    param([string]$Path)
    $cfg = @{}
    foreach ($k in $script:DefaultConfig.Keys) { $cfg[$k] = $script:DefaultConfig[$k] }
    if (Test-Path $Path) {
        try {
            $obj = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $obj) {
                foreach ($p in $obj.PSObject.Properties) {
                    if ($cfg.ContainsKey($p.Name)) { $cfg[$p.Name] = $p.Value }
                }
            }
        } catch { }
    }
    return $cfg
}

# 写 config.json（原子写）
function Write-ConfigFile {
    param([string]$Path, $cfg)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    $cfg | ConvertTo-Json | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}

# R29: 杀旧实例后，旧进程的单实例 Mutex（ClockinReminder_$sid）可能还没释放，新实例 WaitOne(0) 失败会直接退出
# → 装完没常驻进程。Start-Process 前轮询等待旧 Mutex 释放：最多 10 秒，每 0.5 秒试一次。
# 探测到手立刻释放，让新实例能拿到；AbandonedMutexException（旧实例崩溃遗留）等同已释放。
function Wait-InstanceMutexReleased {
    param([string]$MutexName)
    for ($i = 0; $i -lt 20; $i++) {   # 20 次 * 0.5s = 10s
        $m = $null
        try {
            $m = New-Object System.Threading.Mutex($false, $MutexName)
            if ($m.WaitOne(0)) {
                $m.ReleaseMutex()
                return $true
            }
        } catch {
            # AbandonedMutexException：旧实例崩溃遗留，视为已释放
            return $true
        } finally {
            if ($null -ne $m) { $m.Dispose() }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# R30: Start-Process 后轮询 3 秒确认常驻进程真的存活（即使 Mutex 已释放，仍有其他原因导致新实例启动即退）。
# 用命令行匹配 clockin-reminder.ps1（兼容 powershell.exe / pwsh.exe）。
function Confirm-ProcessAlive {
    for ($i = 0; $i -lt 6; $i++) {   # 6 次 * 0.5s = 3s
        $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*clockin-reminder.ps1*' })
        if ($running.Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# 配置表单：确定返回写入的 config hashtable；取消/关闭返回 $null（用默认值，不写 config.json）
function Show-ConfigForm {
    param($cfg)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '打卡提醒 · 安装配置'
    $form.Size = New-Object System.Drawing.Size(640, 580)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 0)   # 与主脚本一致的黄底
    $form.KeyPreview = $true

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '打卡提醒工具 · 安装配置'
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei', 18, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::Red
    $title.BackColor = $form.BackColor
    $title.SetBounds(24, 18, 580, 42)
    $form.Controls.Add($title)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '以下配置写入 config.json，装好后也可在上班/下班弹窗底部「解锁更改配置」再次修改'
    $hint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Regular)
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(170, 0, 0)
    $hint.BackColor = $form.BackColor
    $hint.SetBounds(26, 66, 580, 26)
    $form.Controls.Add($hint)

    $fields = @(
        @{ Name = 'OffWorkHours';            Label = '下班提醒 = 上班打卡 + 几小时'; Min = 1;  Max = 23 },
        @{ Name = 'WorkWindowStart';         Label = '上班提醒最早时间（点）';        Min = 0;  Max = 12 },
        @{ Name = 'WorkWindowEnd';           Label = '打卡时间最晚（点）';            Min = 1;  Max = 23 },
        @{ Name = 'WorkAutoPopupEnd';        Label = '上班自动提醒最晚（点）';        Min = 1;  Max = 23 },
        @{ Name = 'ReRemindIntervalMinutes'; Label = '下班循环提醒间隔（分钟）';      Min = 1;  Max = 480 },
        @{ Name = 'MaxRemindHour';           Label = '最晚自动提醒小时（点）';        Min = 0;  Max = 23 }
    )

    $nuds = @{}
    $y = 106
    foreach ($f in $fields) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $f.Label
        $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11, [System.Drawing.FontStyle]::Regular)
        $lbl.ForeColor = [System.Drawing.Color]::FromArgb(150, 0, 0)
        $lbl.BackColor = $form.BackColor
        $lbl.SetBounds(26, $y, 360, 34)
        $form.Controls.Add($lbl)

        $nud = New-Object System.Windows.Forms.NumericUpDown
        $nud.Minimum = $f.Min
        $nud.Maximum = $f.Max
        $nud.Value = [Math]::Max($f.Min, [Math]::Min($f.Max, [int]$cfg[$f.Name]))
        $nud.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12, [System.Drawing.FontStyle]::Regular)
        $nud.SetBounds(402, $y, 180, 30)
        $form.Controls.Add($nud)
        $nuds[$f.Name] = $nud
        $y += 46
    }

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = '周末跳过（不提醒、不写历史）'
    $chk.Checked = [bool]$cfg.SkipWeekend
    $chk.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11, [System.Drawing.FontStyle]::Regular)
    $chk.ForeColor = [System.Drawing.Color]::FromArgb(150, 0, 0)
    $chk.SetBounds(26, ($y + 4), 380, 32)
    $form.Controls.Add($chk)
    $y += 50

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '确定（保存配置并安装）'
    $btnOk.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12, [System.Drawing.FontStyle]::Bold)
    $btnOk.ForeColor = [System.Drawing.Color]::Red
    $btnOk.BackColor = [System.Drawing.Color]::White
    $btnOk.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnOk.SetBounds(120, $y, 220, 42)
    $form.Controls.Add($btnOk)
    $form.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消（用默认值）'
    $btnCancel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12, [System.Drawing.FontStyle]::Regular)
    $btnCancel.ForeColor = [System.Drawing.Color]::FromArgb(150, 0, 0)
    $btnCancel.BackColor = [System.Drawing.Color]::White
    $btnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnCancel.SetBounds(352, $y, 210, 42)
    $form.Controls.Add($btnCancel)

    $btnOk.Add_Click({
        param($sender, $e)
        # 校验：数值范围由 NumericUpDown 保证；再做交叉校验（上班最早不能晚于自动弹最晚 / 打卡最晚）
        if ($nuds['WorkWindowStart'].Value -gt $nuds['WorkAutoPopupEnd'].Value) {
            [System.Windows.Forms.MessageBox]::Show('上班提醒最早时间不能晚于上班自动提醒最晚时间', '配置错误',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($nuds['WorkWindowStart'].Value -gt $nuds['WorkWindowEnd'].Value) {
            [System.Windows.Forms.MessageBox]::Show('上班提醒最早时间不能晚于打卡时间最晚', '配置错误',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $new = @{}
        foreach ($k in $nuds.Keys) { $new[$k] = [int]$nuds[$k].Value }
        $new['SkipWeekend'] = $chk.Checked
        $f = $sender.FindForm()
        $f.Tag = $new
        $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
    })
    $btnCancel.Add_Click({
        param($sender, $e)
        $f = $sender.FindForm()
        $f.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    })

    $null = $form.ShowDialog()
    if ($form.DialogResult -eq [System.Windows.Forms.DialogResult]::OK) { return $form.Tag }
    return $null
}

# 0. 停掉旧实例（按命令行匹配，避免重复实例双弹窗；兼容 powershell.exe 和 pwsh.exe）
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*clockin-reminder.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 0.5 R22: 弹配置表单；确定则写 config.json，取消用默认（不写，主脚本首次运行自动创建默认）
# R38: 读取兼容老版本根目录 config.json；保存写 log\config.json（Write-ConfigFile 自动建 log 目录）
$cfgResult = Show-ConfigForm -cfg (Read-ExistingConfig -Path (Resolve-ConfigPath))
if ($null -ne $cfgResult) {
    Write-ConfigFile -Path $configFile -cfg $cfgResult
    Write-Host ''
    Write-Host "[OK] 配置已保存 -> $configFile" -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host '[提示] 已取消，使用默认配置（首次运行主脚本会自动创建 config.json）' -ForegroundColor Yellow
}

# 1. 就地安装（R31）：脚本已在本目录，无需拷贝；确保目录存在即可
if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }

# 2. 注册开机自启（HKCU Run，无需管理员）
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$cmd = 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
Set-ItemProperty -Path $runKey -Name 'ClockinReminder' -Value $cmd

# 3. 立即启动
# R29: 先等旧实例的单实例 Mutex 释放（最多 10 秒），再启动新实例，避免新实例 WaitOne(0) 失败退出
try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $sid = 'unknown' }
$null = Wait-InstanceMutexReleased -MutexName "ClockinReminder_$sid"
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`""

# R30: 启动后轮询 3 秒确认进程存活（旧 Mutex 未释放导致新实例退出的问题）
if (Confirm-ProcessAlive) {
    Write-Host ''
    Write-Host '[OK] 打卡提醒工具已安装并启动' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host '[警告] 未检测到常驻进程（可能启动即退出），请查看 log.txt' -ForegroundColor Yellow
}
Write-Host "  脚本目录 : $dstDir"
Write-Host '  配置文件 : log\config.json（弹窗底部「解锁更改配置」可再次修改）'
Write-Host '  手动打卡 : 双击 manual-clockin.ps1（周末加班记录）'
Write-Host '  统计报告 : powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1'
Write-Host '  测试方法 : Win+L 锁屏再解锁，应弹出上班打卡提醒'
Write-Host '  数据说明 : 所有数据在 log 文件夹（周记录/配置/状态/日志）；重装只保留 log 文件夹即不丢数据'
