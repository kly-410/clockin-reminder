#Requires -Version 5.1
<#
  clockin-reminder.ps1  —  打卡提醒常驻脚本
  功能：
    1. 8点前不轮询（睡到 8:00 直接弹上班提醒；8点后开机/解锁则立即弹）
    2. 上班弹窗：占屏 90%，黄底红字，必须填实际打卡时间(08:00-10:00)并点「确认已打卡」才关
    3. 打卡时间 + 10 小时后：主循环弹下班提醒（同样必须点「确认已下班」才关）
  数据文件：%USERPROFILE%\.clockin-reminder\
    state.json   当天状态（打卡时间 / 计划下班时间 / 是否已确认下班）
    history.csv  历史记录（date,clockin_time,offwork_at）
  运行：
    powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File clockin-reminder.ps1
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============ 配置 ============
$script:OffWorkHours    = 10            # 上班打卡后多少小时提醒下班
$script:WorkWindowStart = 8             # 上班提醒最早时间（8 点）
$script:WorkWindowEnd   = 10            # 打卡时间最晚（提示用）
$script:DataDir         = Join-Path $env:USERPROFILE '.clockin-reminder'
$script:StateFile       = Join-Path $script:DataDir 'state.json'
$script:HistoryFile     = Join-Path $script:DataDir 'history.csv'

# ============ 数据 ============
function Ensure-DataDir {
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    if (-not (Test-Path $script:HistoryFile)) { Set-Content -Path $script:HistoryFile -Value 'date,clockin_time,offwork_at' -Encoding UTF8 }
}
function Read-State {
    if (Test-Path $script:StateFile) {
        try { return Get-Content -Path $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return $null
}
function Write-State($state) {
    $state | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding UTF8
}

# ============ 强制确认弹窗（黄底红字，占屏 90%，必须点按钮才关） ============
function Show-MandatoryDialog {
    param([string]$Title, [string]$Message, [string]$SubMessage = '', [bool]$WithInput = $false, [string]$InputDefault = '')

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = [int]($screen.Width * 0.9)
    $h = [int]($screen.Height * 0.9)
    $cx = [int]($w / 2)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size($w, $h)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None   # 无标题栏/关闭按钮
    $form.ControlBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 0)       # 刺眼黄
    $form.TopMost = $true
    $form.KeyPreview = $true
    $form.Tag = @{ Value = $null; Input = $null; WithInput = $WithInput }

    # 拦截 Esc
    $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $_.SuppressKeyPress = $true } })
    # 拦截 Alt+F4 / 一切关闭：未确认前禁止关窗
    $form.Add_FormClosing({
        param($sender, $e)
        if ($null -eq $sender.Tag.Value) { $e.Cancel = $true }
    })

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Title
    $label.Font = New-Object System.Drawing.Font('Microsoft YaHei', 48, [System.Drawing.FontStyle]::Bold)
    $label.ForeColor = [System.Drawing.Color]::Red
    $label.BackColor = $form.BackColor
    $label.TextAlign = 'MiddleCenter'
    $label.SetBounds(0, 60, $w, 160)
    $form.Controls.Add($label)

    $msg = New-Object System.Windows.Forms.Label
    $msg.Text = $Message
    $msg.Font = New-Object System.Drawing.Font('Microsoft YaHei', 32, [System.Drawing.FontStyle]::Bold)
    $msg.ForeColor = [System.Drawing.Color]::Red
    $msg.BackColor = $form.BackColor
    $msg.TextAlign = 'MiddleCenter'
    $msg.SetBounds(0, 240, $w, 160)
    $form.Controls.Add($msg)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = $SubMessage
    $sub.Font = New-Object System.Drawing.Font('Microsoft YaHei', 24, [System.Drawing.FontStyle]::Regular)
    $sub.ForeColor = [System.Drawing.Color]::Red
    $sub.BackColor = $form.BackColor
    $sub.TextAlign = 'MiddleCenter'
    $sub.SetBounds(0, 400, $w, 80)
    $form.Controls.Add($sub)

    if ($WithInput) {
        $input = New-Object System.Windows.Forms.TextBox
        $input.Text = $InputDefault
        $input.Font = New-Object System.Drawing.Font('Microsoft YaHei', 40)
        $input.ForeColor = [System.Drawing.Color]::Red
        $input.TextAlign = 'Center'
        $input.SetBounds(($cx - 250), 520, 500, 100)
        $form.Controls.Add($input)
        $form.Tag.Input = $input
    }

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $(if ($WithInput) { '确认已打卡' } else { '确认已下班' })
    $btn.Font = New-Object System.Drawing.Font('Microsoft YaHei', 36, [System.Drawing.FontStyle]::Bold)
    $btn.ForeColor = [System.Drawing.Color]::Red
    $btn.BackColor = [System.Drawing.Color]::White
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.SetBounds(($cx - 300), ($h - 220), 600, 140)
    $btn.Add_Click({
        param($sender, $e)
        $f = $sender.FindForm()
        $tag = $f.Tag
        if ($tag.WithInput) {
            $t = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($tag.Input.Text.Trim(), 'HH:mm', $null,
                    [System.Globalization.DateTimeStyles]::None, [ref]$t)) {
                [System.Windows.Forms.MessageBox]::Show('时间格式不对，请填 HH:mm，例如 08:30', '输入错误') | Out-Null
                return
            }
            $val = [datetime]::Today.AddHours($t.Hour).AddMinutes($t.Minute)
            $min = [datetime]::Today.AddHours($script:WorkWindowStart)
            $max = [datetime]::Today.AddHours($script:WorkWindowEnd)
            if ($val -lt $min -or $val -gt $max) {
                [System.Windows.Forms.MessageBox]::Show("打卡时间应在 $($script:WorkWindowStart):00 - $($script:WorkWindowEnd):00 之间", '输入错误') | Out-Null
                return
            }
            $tag.Value = $val.ToString('HH:mm')
        } else {
            $tag.Value = $true
        }
        $f.Close()
    })
    $form.Controls.Add($btn)

    $null = $form.ShowDialog()
    return $form.Tag.Value
}

# ============ 上班打卡流程 ============
function Invoke-WorkReminder {
    $now = Get-Date
    $today = $now.ToString('yyyy-MM-dd')
    $state = Read-State
    if ($state -and $state.date -eq $today) { return }   # 当天已提醒过

    $clockin = Show-MandatoryDialog -Title '上班打卡提醒' -Message '记得飞书打卡上班！' `
        -SubMessage "填写实际打卡时间（$($script:WorkWindowStart):00 - $($script:WorkWindowEnd):00）" `
        -WithInput -InputDefault $now.ToString('HH:mm')
    if ($null -eq $clockin) { return }   # 保险：没确认到（正常流程不会）

    $clockinDt = [datetime]::ParseExact($clockin, 'HH:mm', $null)
    $offworkAt = [datetime]::Today.AddHours($clockinDt.Hour).AddMinutes($clockinDt.Minute).AddHours($script:OffWorkHours)
    $offworkStr = $offworkAt.ToString('yyyy-MM-dd HH:mm:ss')

    Write-State @{
        date             = $today
        clockin_time     = $clockin
        offwork_at       = $offworkStr
        offwork_notified = $false
    }
    "$today,$clockin,$offworkStr" | Add-Content -Path $script:HistoryFile -Encoding UTF8
}

# ============ 下班检查（主循环调用，15 秒粒度足够） ============
function Invoke-OffWorkCheck {
    $state = Read-State
    if (-not $state) { return }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($state.date -ne $today -or $state.offwork_notified) { return }
    $target = [datetime]::ParseExact($state.offwork_at, 'yyyy-MM-dd HH:mm:ss', $null)
    if ((Get-Date) -lt $target) { return }

    $msg = "上班 $($state.clockin_time) 打卡，已满 $script:OffWorkHours 小时，可以打下班卡了！"
    $null = Show-MandatoryDialog -Title '下班打卡提醒' -Message $msg
    $state.offwork_notified = $true
    Write-State $state
}

function Test-Locked { return [bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue) }

# ============ 启动 ============
Ensure-DataDir
$today = (Get-Date).ToString('yyyy-MM-dd')
$state = Read-State
if (-not ($state -and $state.date -eq $today)) {
    $now = Get-Date
    $eight = [datetime]::Today.AddHours($script:WorkWindowStart)
    if ($now -lt $eight) {
        # 8点前：不轮询，睡到 8 点弹上班提醒（覆盖"8点前已解锁"场景）
        Start-Sleep -Seconds ([int](($eight - $now).TotalSeconds) + 1)
    }
    Invoke-WorkReminder   # 8点后开机（登录桌面）也直接弹
}

# ============ 主循环 ============
$prevLocked = Test-Locked
while ($true) {
    Start-Sleep -Seconds 15
    Invoke-OffWorkCheck
    $locked = Test-Locked
    if ($prevLocked -and -not $locked) { Invoke-WorkReminder }   # 8点后解锁即弹；当天已记录自动跳过
    $prevLocked = $locked
}
