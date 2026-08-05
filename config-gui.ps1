#Requires -Version 5.1
<#
  config-gui.ps1  —  随时修改打卡默认配置（v9）
  用法：
    双击 config-gui.bat，或命令行：
      powershell -NoProfile -ExecutionPolicy Bypass -File config-gui.ps1
  功能：
    - 图形界面修改 config.json（脚本同目录），不再局限于上班/下班弹窗底部的「解锁更改配置」
    - 字段与主脚本一致：下班提醒小时 / 上班提醒最早 / 打卡最晚 / 自动提醒最晚 / 循环间隔 / 最晚提醒 / 周末跳过
    - 保存后主脚本最多 2 分钟轮询重载自动生效（R23）；想立即生效就重跑 install.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:DataDir     = $PSScriptRoot
$script:ConfigFile  = Join-Path $script:DataDir 'config.json'

# 与主脚本 clockin-reminder.ps1 的 DefaultConfig 保持一致
$script:DefaultConfig = @{
    OffWorkHours             = 10
    WorkWindowStart          = 8
    WorkWindowEnd            = 10
    WorkAutoPopupEnd         = 12
    SkipWeekend              = $true
    ReRemindIntervalMinutes  = 30
    MaxRemindHour            = 23
}

# 读已有 config.json → 合并默认值（重装/已有配置时保留当前值）
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

# 写 config.json（原子写，防写一半损坏）
function Write-ConfigFile {
    param([string]$Path, $cfg)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    $cfg | ConvertTo-Json | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}

# 配置表单（黄底红字，与 install.ps1 / 主脚本弹窗一致的视觉语言）
function Show-ConfigForm {
    param($cfg)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '打卡提醒 · 修改配置'
    $form.Size = New-Object System.Drawing.Size(640, 580)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 0)
    $form.KeyPreview = $true

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '打卡提醒工具 · 修改配置'
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei', 18, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::Red
    $title.BackColor = $form.BackColor
    $title.SetBounds(24, 18, 580, 42)
    $form.Controls.Add($title)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '保存后主程序最多 2 分钟轮询自动生效；想立即生效就重跑 install.ps1'
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
    $btnOk.Text = '保存配置'
    $btnOk.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12, [System.Drawing.FontStyle]::Bold)
    $btnOk.ForeColor = [System.Drawing.Color]::Red
    $btnOk.BackColor = [System.Drawing.Color]::White
    $btnOk.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnOk.SetBounds(120, $y, 220, 42)
    $form.Controls.Add($btnOk)
    $form.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12, [System.Drawing.FontStyle]::Regular)
    $btnCancel.ForeColor = [System.Drawing.Color]::FromArgb(150, 0, 0)
    $btnCancel.BackColor = [System.Drawing.Color]::White
    $btnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnCancel.SetBounds(352, $y, 160, 42)
    $form.Controls.Add($btnCancel)

    $btnOk.Add_Click({
        param($sender, $e)
        # 交叉校验：上班提醒最早不能晚于自动弹最晚 / 打卡最晚
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

# ============ 入口 ============
$cfg = Read-ExistingConfig -Path $script:ConfigFile
$result = Show-ConfigForm -cfg $cfg
if ($null -ne $result) {
    Write-ConfigFile -Path $script:ConfigFile -cfg $result
    $summary = @()
    $null = $summary.Add("满 $($result.OffWorkHours)h 提醒下班")
    $null = $summary.Add("上班窗 $($result.WorkWindowStart)-$($result.WorkAutoPopupEnd) 点")
    $null = $summary.Add("打卡最晚 $($result.WorkWindowEnd) 点")
    $null = $summary.Add("循环 $($result.ReRemindIntervalMinutes) min")
    $null = $summary.Add("$($result.MaxRemindHour) 点截止")
    if ($result.SkipWeekend) { $null = $summary.Add('周末跳过') } else { $null = $summary.Add('周末提醒') }
    [System.Windows.Forms.MessageBox]::Show(
        "配置已保存：$($summary -join ' · ')`n`n主程序最多 2 分钟内自动生效（R23 轮询重载）；想立即生效请重跑 install.ps1。",
        '保存成功', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
} else {
    Write-Host '已取消，未修改配置。'
}
