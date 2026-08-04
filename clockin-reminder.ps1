#Requires -Version 5.1
<#
  clockin-reminder.ps1  —  打卡提醒常驻脚本 (v2)
  功能：
    1. 工作日(周一~周五)才提醒；周六/周日不弹任何提醒、不写 history（R1）
    2. 8 点前不轮询（睡到 8:00）；8:00-12:00 之间由主循环兜底弹上班提醒（R3/R4）
    3. 上班/下班弹窗在独立 runspace 线程中运行，不阻塞主循环（R2）
    4. 打卡时间 + 10 小时后主循环弹下班提醒；跨天未确认的下班提醒在工作日补弹（R8）
  数据文件：%USERPROFILE%\.clockin-reminder\
    state.json   状态（date / work_reminder_shown / clockin_time / offwork_at / offwork_notified）
    history.csv  历史记录（date,clockin_time,offwork_at）
    log.txt      异常日志
  运行：
    powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File clockin-reminder.ps1
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============ 配置 ============
$script:OffWorkHours      = 10            # 上班打卡后多少小时提醒下班
$script:WorkWindowStart   = 8             # 上班提醒最早时间（8 点）
$script:WorkWindowEnd     = 10            # 打卡时间最晚（提示用；超范围弹 YesNo 确认，不再硬拒）
$script:WorkAutoPopupEnd  = 12            # 上班自动提醒最晚时间（12 点后启动当天不自动弹）
$script:SkipWeekend       = $true         # 周六/周日不提醒、不写历史
$script:DataDir           = Join-Path $env:USERPROFILE '.clockin-reminder'
$script:StateFile         = Join-Path $script:DataDir 'state.json'
$script:HistoryFile       = Join-Path $script:DataDir 'history.csv'
$script:LogFile           = Join-Path $script:DataDir 'log.txt'

# 进行中的弹窗 runspace 引用，防止被垃圾回收杀掉弹窗线程
$script:PendingPopups = [System.Collections.ArrayList]::new()

# ============ 日志 ============
function Write-Log {
    param([string]$Message)
    try {
        Add-Content -Path $script:LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

# ============ 数据 ============
function Ensure-DataDir {
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    if (-not (Test-Path $script:HistoryFile)) { Set-Content -Path $script:HistoryFile -Value 'date,clockin_time,offwork_at' -Encoding UTF8 }
}

# 读取 state.json；统一转成 hashtable，避免 PSCustomObject 加属性报错（R5）
function Read-State {
    if (-not (Test-Path $script:StateFile)) { return $null }
    try {
        $obj = Get-Content -Path $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $obj) { return $null }
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch { return $null }
}

# 原子写：临时文件 + Move-Item，避免写一半崩掉损坏 state.json（R5）
function Write-State($state) {
    try {
        $tmp = "$($script:StateFile).tmp"
        $state | ConvertTo-Json | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $script:StateFile -Force
    } catch {
        Write-Log "Write-State 失败: $($_.Exception.Message)"
    }
}

# 写入历史前先去重：当天已有行则跳过（R9）
function Add-HistoryLine {
    param([string]$date, [string]$clockin, [string]$offworkAt)
    try {
        if (-not (Test-Path $script:HistoryFile)) {
            Set-Content -Path $script:HistoryFile -Value 'date,clockin_time,offwork_at' -Encoding UTF8
        }
        if (Select-String -Path $script:HistoryFile -Pattern "^$date," -Quiet) { return }
        Add-Content -Path $script:HistoryFile -Value "$date,$clockin,$offworkAt" -Encoding UTF8
    } catch {
        Write-Log "Add-HistoryLine 失败: $($_.Exception.Message)"
    }
}

# ============ 工作日守卫（R1）============
# 周一~周五返回 $true；周六/周日返回 $false
function Test-Workday {
    if (-not $script:SkipWeekend) { return $true }
    $dow = (Get-Date).DayOfWeek
    return ($dow -ne [DayOfWeek]::Saturday) -and ($dow -ne [DayOfWeek]::Sunday)
}

# 上班自动提醒时间窗：8:00 <= now < 12:00（R3 每天 8 点兜底 / R4 深夜启动不弹）
function Test-WorkAutoWindow {
    $hour = (Get-Date).Hour
    return ($hour -ge $script:WorkWindowStart) -and ($hour -lt $script:WorkAutoPopupEnd)
}

# ============ 锁屏检测（R7，WTS API）============
if (-not ('WtsNative' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WtsNative {
    [DllImport("kernel32.dll")]
    public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32.dll", SetLastError = true)]
    public static extern bool WTSQuerySessionInformation(IntPtr hServer, uint SessionId, int WTSInfoClass, out IntPtr ppBuffer, out uint pBytesReturned);
    [DllImport("wtsapi32.dll")]
    public static extern void WTSFreeMemory(IntPtr pMemory);
}
'@
    } catch {
        Write-Log "WTS Add-Type 失败: $($_.Exception.Message)"
    }
}

function Test-Locked {
    try {
        $sessionId = [WtsNative]::WTSGetActiveConsoleSessionId()
        $ptr = [IntPtr]::Zero
        $bytes = [uint32]0
        # WTSInfoClass=1 -> WTSConnectState：0=Active(解锁)，Disconnected 等非 0 状态视为锁屏
        if ([WtsNative]::WTSQuerySessionInformation([IntPtr]::Zero, $sessionId, 1, [ref]$ptr, [ref]$bytes)) {
            $state = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr)
            [WtsNative]::WTSFreeMemory($ptr)
            return ($state -ne 0)
        }
        return $false
    } catch {
        return $false
    }
}

# ============ 强制确认弹窗（黄底红字，占屏 90%，必须点按钮才关；Enter 提交 R9）============
function Show-MandatoryDialog {
    param(
        [string]$Title,
        [string]$Message,
        [string]$SubMessage = '',
        [bool]$WithInput = $false,
        [string]$InputDefault = '',
        [int]$WorkStart = $script:WorkWindowStart,
        [int]$WorkEnd = $script:WorkWindowEnd
    )
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
    $form.Tag = @{ Value = $null; Input = $null; WithInput = $WithInput; WorkStart = $WorkStart; WorkEnd = $WorkEnd }

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
            $text = $tag.Input.Text.Trim()
            $t = [datetime]::MinValue
            # 兼容 HH:mm 和 H:mm；格式错误仍拒绝（R9）
            if (-not [datetime]::TryParseExact($text, [string[]]@('HH:mm', 'H:mm'), $null,
                    [System.Globalization.DateTimeStyles]::None, [ref]$t)) {
                [System.Windows.Forms.MessageBox]::Show('时间格式不对，请填 HH:mm 或 H:mm，例如 08:30 或 8:30', '输入错误') | Out-Null
                return
            }
            $val = [datetime]::Today.AddHours($t.Hour).AddMinutes($t.Minute)
            $min = [datetime]::Today.AddHours($tag.WorkStart)
            $max = [datetime]::Today.AddHours($tag.WorkEnd)
            if ($val -lt $min -or $val -gt $max) {
                # 超范围不再硬拒，弹 YesNo 让用户决定（R9）
                $ask = [System.Windows.Forms.MessageBox]::Show(
                    "实际时间 $text 不在 $($tag.WorkStart):00-$($tag.WorkEnd):00，仍要记录？",
                    '确认', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
            $tag.Value = $val.ToString('HH:mm')
        } else {
            $tag.Value = $true
        }
        $f.Close()
    })
    $form.Controls.Add($btn)
    $form.AcceptButton = $btn   # Enter 键提交（R9）

    $null = $form.ShowDialog()
    return $form.Tag.Value
}

# ============ 异步弹窗（R2：runspace 线程，不阻塞主循环）============
# 选 runspace（同进程内新线程）而不是 Start-Job（每次起一个新 powershell 进程），
# 开销最小；WinForms 需要 STA 线程，故设 ApartmentState = 'STA'。
# 确认结果通过写 state.json 回传；先置标记再弹，防止重复弹。
function Start-DialogRunspace {
    param(
        [string]$Kind,                 # 'work' 上班 / 'offwork' 下班
        [string]$Title,
        [string]$Message,
        [string]$SubMessage = '',
        [string]$InputDefault = '',
        [string]$ExpectedOffworkAt = ''  # 下班弹窗确认时校验，防止旧弹窗串改新一天数据
    )

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.Open()

        $ps = [powershell]::Create()
        $ps.Runspace = $rs

        # 注入共享函数（同进程内线程，避免每弹一次起一个新 powershell 进程）
        $null = $ps.AddScript("function Show-MandatoryDialog { $((Get-Command -Name 'Show-MandatoryDialog').Definition) }")
        $null = $ps.AddScript("function Test-Workday { $((Get-Command -Name 'Test-Workday').Definition) }")
        $null = $ps.AddScript("function Write-State { $((Get-Command -Name 'Write-State').Definition) }")
        $null = $ps.AddScript("function Read-State { $((Get-Command -Name 'Read-State').Definition) }")
        $null = $ps.AddScript("function Add-HistoryLine { $((Get-Command -Name 'Add-HistoryLine').Definition) }")
        $null = $ps.AddScript("function Write-Log { $((Get-Command -Name 'Write-Log').Definition) }")

        $main = @'
param($ctx)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:DataDir      = $ctx.DataDir
$script:StateFile    = $ctx.StateFile
$script:HistoryFile  = $ctx.HistoryFile
$script:LogFile      = $ctx.LogFile
$script:SkipWeekend  = $ctx.SkipWeekend
$script:OffWorkHours = $ctx.OffWorkHours

$dialogParams = @{
    Title       = $ctx.Title
    Message     = $ctx.Message
    SubMessage  = $ctx.SubMessage
    WithInput   = $ctx.WithInput
    InputDefault = $ctx.InputDefault
    WorkStart   = $ctx.WorkWindowStart
    WorkEnd     = $ctx.WorkWindowEnd
}
$result = Show-MandatoryDialog @dialogParams
if ($null -eq $result) { return }   # 保险：没确认到（正常流程不会）

try {
    if ($ctx.Kind -eq 'work') {
        if (-not (Test-Workday)) { return }   # 弹窗跨天到周末的兜底：周末不写历史
        $clockinDt = [datetime]::ParseExact($result, 'HH:mm', $null)
        $offworkAt = [datetime]::Today.AddHours($clockinDt.Hour).AddMinutes($clockinDt.Minute).AddHours($ctx.OffWorkHours)
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $state = Read-State
        if (-not $state) { $state = @{} }
        $state.date = $today
        $state.clockin_time = $result
        $state.offwork_at = $offworkAt.ToString('yyyy-MM-dd HH:mm:ss')
        $state.offwork_notified = $false
        $state.work_reminder_shown = $true
        Write-State $state
        Add-HistoryLine -date $today -clockin $result -offworkAt $state.offwork_at
    } else {
        if (-not (Test-Workday)) { return }
        $state = Read-State
        # 仅当仍是发起时的那次下班提醒才回写，避免旧弹窗覆盖新一天数据
        if ($state -and $state.offwork_at -eq $ctx.ExpectedOffworkAt) {
            $state.offwork_notified = $true
            Write-State $state
        }
    }
} catch {
    Write-Log "弹窗确认回写失败: $($_.Exception.Message)"
}
'@
        $null = $ps.AddScript($main)
        $null = $ps.AddArgument(@{
            Kind = $Kind
            Title = $Title
            Message = $Message
            SubMessage = $SubMessage
            WithInput = ($Kind -eq 'work')
            InputDefault = $InputDefault
            WorkWindowStart = $script:WorkWindowStart
            WorkWindowEnd = $script:WorkWindowEnd
            OffWorkHours = $script:OffWorkHours
            SkipWeekend = $script:SkipWeekend
            DataDir = $script:DataDir
            StateFile = $script:StateFile
            HistoryFile = $script:HistoryFile
            LogFile = $script:LogFile
            ExpectedOffworkAt = $ExpectedOffworkAt
        })

        # 异步执行；保留引用，防止 GC 回收掉弹窗线程
        $handle = $ps.BeginInvoke()
        $null = $script:PendingPopups.Add([pscustomobject]@{ PS = $ps; Handle = $handle; Runspace = $rs })
    } catch {
        Write-Log "启动弹窗 runspace 失败: $($_.Exception.Message)"
    }
}

# 清理已结束的弹窗线程
function Cleanup-DialogRunspaces {
    foreach ($p in @($script:PendingPopups)) {
        try {
            if ($p.Handle.IsCompleted) {
                $p.Runspace.Close()
                $p.PS.Dispose()
                $null = $script:PendingPopups.Remove($p)
            }
        } catch { }
    }
}

# ============ 上班打卡流程（异步弹窗；R1/R2/R3/R4 守卫）============
function Invoke-WorkReminder {
    if (-not (Test-Workday)) { return }                    # R1 周末守卫
    if (-not (Test-WorkAutoWindow)) { return }             # R3/R4 仅 8:00-12:00 才自动弹
    $state = Read-State
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($state -and $state.work_reminder_shown -and $state.date -eq $today) { return }  # 已提醒过

    # 先置标记再弹（R2），防止重复弹；保留旧下班数据不覆盖，避免补弹场景丢信息
    $newState = $state
    if (-not $newState) { $newState = @{} }
    $newState.date = $today
    $newState.work_reminder_shown = $true
    Write-State $newState

    $now = Get-Date
    Start-DialogRunspace -Kind 'work' -Title '上班打卡提醒' `
        -Message '记得飞书打卡上班！' `
        -SubMessage "填写实际打卡时间（$($script:WorkWindowStart):00 - $($script:WorkWindowEnd):00）" `
        -InputDefault $now.ToString('HH:mm')
}

# ============ 下班检查（主循环调用；跨天补弹 R8；周末守卫 R1；异步弹窗 R2）============
function Invoke-OffWorkCheck {
    if (-not (Test-Workday)) { return }                    # R1 周末守卫
    $state = Read-State
    if (-not $state -or $state.offwork_notified) { return }
    $target = $null
    try { $target = [datetime]::ParseExact($state.offwork_at, 'yyyy-MM-dd HH:mm:ss', $null) } catch { return }  # R5
    if ((Get-Date) -lt $target) { return }

    # 先置标记再弹（R2），防止重复弹
    $state.offwork_notified = $true
    Write-State $state

    $msg = "上班 $($state.clockin_time) 打卡，已满 $script:OffWorkHours 小时，可以打下班卡了！"
    Start-DialogRunspace -Kind 'offwork' -Title '下班打卡提醒' -Message $msg `
        -ExpectedOffworkAt $state.offwork_at
}

# ============ 单实例互斥（R6）============
# 用户级命名 Mutex（不用 Global\，避免权限问题）；已有实例直接退出
try {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
} catch {
    $sid = 'unknown'
}
$script:Mutex = New-Object System.Threading.Mutex($false, "ClockinReminder_$sid")
try {
    $script:HasMutex = $script:Mutex.WaitOne(0)
} catch {
    # AbandonedMutexException：上个实例崩溃遗留，视为可持有
    $script:HasMutex = $true
}
if (-not $script:HasMutex) { exit }

# ============ 启动 ============
Ensure-DataDir
$now = Get-Date
if ((Test-Workday) -and $now.Hour -lt $script:WorkWindowStart) {
    # 8 点前：不轮询，睡到 8 点（过工作日守卫；周末不睡不弹）
    $eight = [datetime]::Today.AddHours($script:WorkWindowStart)
    Start-Sleep -Seconds ([int](($eight - $now).TotalSeconds) + 1)
}
# 8:00-12:00 启动：由主循环 15 秒内兜底触发（R3）；12 点后启动当天不自动弹（R4）

# ============ 主循环（15 秒轮询；try/catch 防脚本自杀 R5）============
$prevLocked = Test-Locked
while ($true) {
    try {
        Start-Sleep -Seconds 15
        Invoke-OffWorkCheck
        Invoke-WorkReminder              # R3 每天 8 点兜底（不依赖启动/解锁事件；跨天常驻第二天 8 点也能弹）
        Cleanup-DialogRunspaces
        $locked = Test-Locked
        if ($prevLocked -and -not $locked) {
            Invoke-WorkReminder          # 解锁触发（内部已过工作日+时间窗+去重守卫）
        }
        $prevLocked = $locked
    } catch {
        Write-Log "主循环异常: $($_.Exception.Message)"
        Start-Sleep -Seconds 30          # 睡 30 秒继续，不允许脚本自己死掉
    }
}
