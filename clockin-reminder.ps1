#Requires -Version 5.1
<#
  clockin-reminder.ps1  —  打卡提醒常驻脚本 (v8)
  功能：
    1. 工作日(周一~周五)才提醒；周六/周日不弹任何提醒、不写 history（R1）
    2. 8 点前不轮询（睡到 8:00）；主循环兜底 8:00-12:00 弹上班提醒；解锁/启动触发放宽到 8:00-23:00（R3/R4/R18）
    3. 上班/下班弹窗在独立 runspace 线程中运行，不阻塞主循环（R2）
    4. 打卡时间 + 10 小时后主循环弹下班提醒；跨天未确认的下班提醒在工作日补弹（R8）
    5. 下班确认把实际时间写入 history.csv；下班弹窗附带今日/本周工作时长统计（R10/R12）
    6. 下班提醒循环触发：确认一次后按 ReRemindIntervalMinutes 再提醒，直到不再确认或超过 MaxRemindHour（R15/R17）
    7. offwork_actual 同一天多次确认取最晚（R16）
    8. 全天缺勤补记：工作日 20 点后无记录补 0h 0min；启动时补前一天 0h 0min（R19）
    9. 配置持久化到 config.json；弹窗底部配置区先解锁才能改，保存后下次轮询生效（R21/R23）
  数据文件：%USERPROFILE%\.clockin-reminder\
    state.json   状态（date / work_reminder_shown / clockin_time / offwork_at / offwork_notified / next_remind_at）
    history.csv  历史记录（日期,上班时间,预计下班,实际下班,工作时长；v8 起 offwork 时间存完整 datetime，可能次日）
    log.txt      异常日志
  运行：
    powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File clockin-reminder.ps1
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============ 配置（R21：config.json 持久化；硬编码默认值保留作 fallback）============
$script:DefaultConfig = @{
    OffWorkHours             = 10            # 上班打卡后多少小时提醒下班
    WorkWindowStart          = 8             # 上班提醒最早时间（8 点）
    WorkWindowEnd            = 10            # 打卡时间最晚（提示用；超范围弹 YesNo 确认，不再硬拒；R18 起上限放宽到 max(10, 当前时刻)）
    WorkAutoPopupEnd         = 12            # 上班自动提醒最晚时间（12 点后启动当天不自动弹）
    SkipWeekend              = $true         # 周六/周日不提醒、不写历史
    ReRemindIntervalMinutes  = 30            # 满 10h 后默认每 30 分钟再弹一次（R15）
    MaxRemindHour            = 23            # 超过该小时不再自动提醒下班（防深夜骚扰；可手动记）（R15）
}
$script:DataDir     = Join-Path $env:USERPROFILE '.clockin-reminder'
$script:ConfigFile  = Join-Path $script:DataDir 'config.json'
$script:StateFile   = Join-Path $script:DataDir 'state.json'
$script:HistoryFile = Join-Path $script:DataDir 'history.csv'
$script:LogFile     = Join-Path $script:DataDir 'log.txt'

# R21: 读 config.json → 合并后的 hashtable；缺失字段用默认值；文件不存在返回默认值
function Read-Config {
    return Invoke-DataLocked {
        $cfg = @{}
        foreach ($k in $script:DefaultConfig.Keys) { $cfg[$k] = $script:DefaultConfig[$k] }
        if (Test-Path $script:ConfigFile) {
            try {
                $obj = Get-Content -Path $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $obj) {
                    foreach ($p in $obj.PSObject.Properties) {
                        if ($cfg.ContainsKey($p.Name)) { $cfg[$p.Name] = $p.Value }
                    }
                }
            } catch {
                Write-Log "Read-Config 失败，用默认值: $($_.Exception.Message)"
            }
        }
        return $cfg
    }
}

# R21: 写 config.json（原子写，防写一半损坏）
function Write-Config {
    param($cfg)
    Invoke-DataLocked {
        try {
            if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
            $tmp = "$($script:ConfigFile).tmp"
            $cfg | ConvertTo-Json | Set-Content -Path $tmp -Encoding UTF8
            Move-Item -Path $tmp -Destination $script:ConfigFile -Force
        } catch {
            Write-Log "Write-Config 失败: $($_.Exception.Message)"
        }
    }
}

# R23: 弹窗底部配置摘要（只读小字显示当前配置）
function Get-ConfigSummary {
    param($cfg)
    $parts = New-Object System.Collections.ArrayList
    $null = $parts.Add("满$($cfg.OffWorkHours)h提醒下班")
    $null = $parts.Add("上班窗$($cfg.WorkWindowStart)-$($cfg.WorkAutoPopupEnd)点")
    $null = $parts.Add("打卡最晚$($cfg.WorkWindowEnd)点")
    $null = $parts.Add("循环$($cfg.ReRemindIntervalMinutes)min")
    $null = $parts.Add("$($cfg.MaxRemindHour)点截止")
    if ($cfg.SkipWeekend) { $null = $parts.Add('周末跳过✓') } else { $null = $parts.Add('周末提醒') }
    return ($parts -join ' · ')
}

# R23: 重载 config.json 到脚本配置变量（每次轮询/弹窗前调用 → 配置变更下次轮询生效）
# P1-4: 逐项校验类型/范围，非法值一律回退默认，避免 config.json 手改坏后脚本行为异常
function Get-ValidatedInt {
    param($Value, [int]$Default, [int]$Min, [int]$Max)
    try {
        $n = [int]$Value
        if ($n -ge $Min -and $n -le $Max) { return $n }
    } catch { }
    return $Default
}

function Get-ValidatedBool {
    param($Value, [bool]$Default)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [string]) {
        if ($Value -match '^(true|1|是|yes)$') { return $true }
        if ($Value -match '^(false|0|否|no)$') { return $false }
        return $Default
    }
    try { return [bool]$Value } catch { return $Default }
}

function Reload-Config {
    try {
        $cfg = Read-Config
        $d = $script:DefaultConfig
        $script:OffWorkHours             = Get-ValidatedInt $cfg.OffWorkHours             $d.OffWorkHours             1   23
        $script:WorkWindowStart          = Get-ValidatedInt $cfg.WorkWindowStart          $d.WorkWindowStart          0   12
        $script:WorkWindowEnd            = Get-ValidatedInt $cfg.WorkWindowEnd            $d.WorkWindowEnd            1   23
        $script:WorkAutoPopupEnd         = Get-ValidatedInt $cfg.WorkAutoPopupEnd         $d.WorkAutoPopupEnd         1   23
        $script:ReRemindIntervalMinutes  = Get-ValidatedInt $cfg.ReRemindIntervalMinutes  $d.ReRemindIntervalMinutes  1   480
        $script:MaxRemindHour            = Get-ValidatedInt $cfg.MaxRemindHour            $d.MaxRemindHour            0   23
        $script:SkipWeekend              = Get-ValidatedBool $cfg.SkipWeekend $d.SkipWeekend
    } catch {
        Write-Log "Reload-Config 失败，回退默认: $($_.Exception.Message)"
        foreach ($k in $script:DefaultConfig.Keys) { Set-Variable -Name $k -Value $script:DefaultConfig[$k] -Scope Script }
    }
}
# 当前生效配置变量（启动时由 Reload-Config 从 config.json 覆盖）
$script:OffWorkHours             = $script:DefaultConfig.OffWorkHours
$script:WorkWindowStart          = $script:DefaultConfig.WorkWindowStart
$script:WorkWindowEnd            = $script:DefaultConfig.WorkWindowEnd
$script:WorkAutoPopupEnd         = $script:DefaultConfig.WorkAutoPopupEnd
$script:SkipWeekend              = $script:DefaultConfig.SkipWeekend
$script:ReRemindIntervalMinutes  = $script:DefaultConfig.ReRemindIntervalMinutes
$script:MaxRemindHour            = $script:DefaultConfig.MaxRemindHour

# 进行中的弹窗 runspace 引用，防止被垃圾回收杀掉弹窗线程
$script:PendingPopups = [System.Collections.ArrayList]::new()
$script:SkippedLines  = New-Object System.Collections.ArrayList   # 历史解析失败行号（容错用）

# ============ 日志 ============
# P2-1: 日志轮转——log.txt 超过 1MB 时改名 log.txt.old 保留一份，重新开始写（防日志无限膨胀）
function Write-Log {
    param([string]$Message)
    try {
        if (Test-Path $script:LogFile) {
            $f = Get-Item -Path $script:LogFile -ErrorAction SilentlyContinue
            if ($null -ne $f -and $f.Length -gt 1MB) {
                $backup = "$($script:LogFile).old"
                Remove-Item -Path $backup -Force -ErrorAction SilentlyContinue
                Move-Item -Path $script:LogFile -Destination $backup -Force -ErrorAction SilentlyContinue
            }
        }
        Add-Content -Path $script:LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

# ============ 数据 ============
function Ensure-DataDir {
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    if (-not (Test-Path $script:HistoryFile)) { Set-Content -Path $script:HistoryFile -Value '日期,上班时间,预计下班,实际下班,工作时长' -Encoding UTF8 }
    # P2-2: 清理原子写残留 .tmp（上次进程崩溃/被杀可能留下写一半的临时文件；正式文件 Move-Item 是原子的不受影响）
    foreach ($f in @($script:StateFile, $script:HistoryFile, $script:ConfigFile)) {
        $tmp = "$f.tmp"
        if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# P1-3: 数据文件互斥锁。主循环线程与弹窗 runspace 线程并发读写 history/state/config 会互相踩
# （读改写竞态：一个线程基于旧文件改写后覆盖另一个线程的更新），统一走命名 Mutex 串行化。
# 命名 Mutex 同进程多线程/跨进程可共享；$script:DataMutex 在启动时创建，runspace 里由 ctx 传入。
function Invoke-DataLocked {
    param([scriptblock]$Action)
    if ($null -eq $script:DataMutex) { return & $Action }   # 创建失败退化为不加锁（原子写仍防写一半）
    $acquired = $false
    try {
        $acquired = $script:DataMutex.WaitOne(10000)
        if (-not $acquired) { throw '数据锁等待超时' }
        return & $Action
    } finally {
        if ($acquired) { $script:DataMutex.ReleaseMutex() }
    }
}

# 读取 state.json；统一转成 hashtable，避免 PSCustomObject 加属性报错（R5）
function Read-State {
    return Invoke-DataLocked {
        if (-not (Test-Path $script:StateFile)) { return $null }
        try {
            $obj = Get-Content -Path $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -eq $obj) { return $null }
            $h = @{}
            foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
            return $h
        } catch { return $null }
    }
}

# 原子写：临时文件 + Move-Item，避免写一半崩掉损坏 state.json（R5）
function Write-State($state) {
    Invoke-DataLocked {
        try {
            $tmp = "$($script:StateFile).tmp"
            $state | ConvertTo-Json | Set-Content -Path $tmp -Encoding UTF8
            Move-Item -Path $tmp -Destination $script:StateFile -Force
        } catch {
            Write-Log "Write-State 失败: $($_.Exception.Message)"
        }
    }
}

# 写入历史前先去重：当天已有行则跳过（R9）
# v8: 5 列，offwork_at 存完整 datetime（state.offwork_at 本来就是 yyyy-MM-dd HH:mm:ss，直接写入，下班可能次日）
#     写上班卡时同时算 duration（缺实际下班回退预计 offwork_at）
function Add-HistoryLine {
    param([string]$date, [string]$clockin, [string]$offworkAt)
    Invoke-DataLocked {
        try {
            if (-not (Test-Path $script:HistoryFile)) {
                Set-Content -Path $script:HistoryFile -Value '日期,上班时间,预计下班,实际下班,工作时长' -Encoding UTF8
            }
            if (Select-String -Path $script:HistoryFile -Pattern "^$date," -Quiet) { return }
            $offTime = $offworkAt
            $durStr = ''
            $row = [pscustomobject]@{ date = $date; clockin = $clockin; offwork_at = $offTime; offwork_actual = '' }
            $min = Get-RecordMinutes $row
            if ($null -ne $min) { $durStr = Format-RowDuration $min }
            Add-Content -Path $script:HistoryFile -Value "$date,$clockin,$offTime,,$durStr" -Encoding UTF8
        } catch {
            Write-Log "Add-HistoryLine 失败: $($_.Exception.Message)"
        }
    }
}

# ============ 历史统计（R10/R11）============
# history.csv 兼容 3 列（旧）/4 列（v3/v4）/5 列（v5 HH:mm 版 / v8 完整 datetime 版）；offwork_actual 为空时回退 offwork_at（预计值）
# v8: offwork_at / offwork_actual 在 CSV 里存完整 datetime（含日期，下班可能次日）；旧 HH:mm 行走跨天推断 fallback（见 Get-RecordEnd）

# 读取 history.csv 为行对象数组；解析失败的行跳过并记行号（供 report 提示）
function Read-HistoryRows {
    param([string]$Path = $script:HistoryFile)
    $rows = @()
    if (-not (Test-Path $Path)) { return $rows }
    $lines = @(Get-Content -Path $Path -Encoding UTF8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq 0) { continue }   # 表头
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $cols = $line.Split(',')
        $d = [datetime]::MinValue
        $dateOk = $cols.Count -ge 1 -and [datetime]::TryParseExact($cols[0].Trim(), 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$d)
        if ($cols.Count -lt 3 -or -not $dateOk) {
            $null = $script:SkippedLines.Add($i + 1)
            continue
        }
        $rows += [pscustomobject]@{
            date           = $cols[0].Trim()
            clockin        = $(if ($cols.Count -ge 2) { $cols[1].Trim() } else { '' })
            offwork_at     = $(if ($cols.Count -ge 3) { $cols[2].Trim() } else { '' })
            offwork_actual = $(if ($cols.Count -ge 4) { $cols[3].Trim() } else { '' })
            duration       = $(if ($cols.Count -ge 5) { $cols[4].Trim() } else { '' })
        }
    }
    return $rows
}

function ConvertTo-StatsDate {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParseExact($s, 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
    return $null
}

# v5: 把 offwork 时间统一转成 HH:mm（兼容 HH:mm / 旧格式 yyyy-MM-dd HH:mm:ss / yyyy-MM-dd HH:mm）
function ConvertTo-HHmm {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $t = [datetime]::MinValue
    if ([datetime]::TryParseExact($s, [string[]]@('HH:mm:ss', 'HH:mm', 'H:mm'), $null, [System.Globalization.DateTimeStyles]::None, [ref]$t)) { return $t.ToString('HH:mm') }
    if ([datetime]::TryParseExact($s, 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$t)) { return $t.ToString('HH:mm') }
    if ([datetime]::TryParseExact($s, 'yyyy-MM-dd HH:mm', $null, [System.Globalization.DateTimeStyles]::None, [ref]$t)) { return $t.ToString('HH:mm') }
    return $s
}

# 记录开始时间 = 该行 date + clockin（HH:mm）
function Get-RecordStart {
    param($row)
    $d = ConvertTo-StatsDate $row.date
    if ($null -eq $d) { return $null }
    $t = [datetime]::MinValue
    if ([datetime]::TryParseExact($row.clockin, [string[]]@('HH:mm', 'H:mm'), $null, [System.Globalization.DateTimeStyles]::None, [ref]$t)) {
        return $d.Date.Add($t.TimeOfDay)
    }
    return $null
}

# 记录结束时间：优先 offwork_actual，为空回退 offwork_at（预计值）
# v8: offwork 时间在 CSV 里存完整 datetime（yyyy-MM-dd HH:mm:ss，含日期，下班可能次日）→ 直接解析，无需推断
#     旧 HH:mm 版行（无日期）→ 保留"end < start → 视为次日"推断作 fallback（R28 兼容）
function Get-RecordEnd {
    param($row, $start)
    $s = $row.offwork_actual
    if ([string]::IsNullOrWhiteSpace($s)) { $s = $row.offwork_at }
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    # v8 完整 datetime（含空格即有日期，可能次日）：直接解析，无歧义
    if ($s.Contains(' ')) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($s, 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
        if ([datetime]::TryParseExact($s, 'yyyy-MM-dd HH:mm', $null, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
        return $null
    }
    # v5 纯时间（HH:mm）：与 start 同一天组合；end < start 视为跨天（C1 fallback）
    $t = [datetime]::MinValue
    if ([datetime]::TryParseExact($s, [string[]]@('HH:mm', 'H:mm'), $null, [System.Globalization.DateTimeStyles]::None, [ref]$t)) {
        if ($null -eq $start) { return $null }
        $end = $start.Date.Add($t.TimeOfDay)
        if ($end -lt $start) { $end = $end.AddDays(1) }
        return $end
    }
    return $null
}

# 单条记录时长（分钟）；缺上班或下班时间返回 $null
function Get-RecordMinutes {
    param($row)
    $start = Get-RecordStart $row
    if ($null -eq $start) { return $null }
    $end = Get-RecordEnd -row $row -start $start
    if ($null -eq $end) { return $null }
    $diff = $end - $start
    if ($diff.TotalMinutes -lt 0) { $diff = [TimeSpan]::Zero }
    return $diff.TotalMinutes
}

# 时长显示：Xh Ymin（如 3h 30min）
function Format-Duration {
    param([double]$Minutes)
    if ($Minutes -lt 0) { $Minutes = 0 }
    $total = [math]::Round($Minutes)
    $h = [math]::Floor($total / 60)
    $m = $total % 60
    return ('{0}h {1}min' -f $h, $m)
}

# P2-3: 单条记录时长显示；超过 18h 视为可疑（跨天推断/手滑填错），末尾加 ? 标记。
# 仅用于 history.csv 的 duration 列；周/月合计仍走 Format-Duration（合计超 18h 正常，不标记）。
function Format-RowDuration {
    param([double]$Minutes)
    $s = Format-Duration $Minutes
    if ($Minutes -gt (18 * 60)) { $s += '?' }
    return $s
}

function Test-Weekend {
    param([datetime]$d)
    $dow = $d.DayOfWeek
    return ($dow -eq [DayOfWeek]::Saturday) -or ($dow -eq [DayOfWeek]::Sunday)
}

# 所在周的周一/周日（周一到周日）
function Get-WeekRange {
    param([datetime]$d)
    $daysSinceMonday = ([int]$d.DayOfWeek + 6) % 7
    $monday = $d.Date.AddDays(-$daysSinceMonday)
    return @{ Monday = $monday; Sunday = $monday.AddDays(6) }
}

function Get-WeekdayName {
    param([datetime]$d)
    switch ([int]$d.DayOfWeek) {
        0 { return '周日' }
        1 { return '周一' }
        2 { return '周二' }
        3 { return '周三' }
        4 { return '周四' }
        5 { return '周五' }
        6 { return '周六' }
    }
}

# 某周统计：Weekday=周一~周五合计（用于 50h 达标），Weekend=周末加班单列
function Get-WeekStats {
    param([datetime]$d)
    $range = Get-WeekRange $d
    $rows = @(Read-HistoryRows)
    $weekday = 0.0
    $weekend = 0.0
    foreach ($row in $rows) {
        $rd = ConvertTo-StatsDate $row.date
        if ($null -eq $rd) { continue }
        if ($rd -lt $range.Monday -or $rd -gt $range.Sunday) { continue }
        $min = Get-RecordMinutes $row
        if ($null -eq $min) { continue }
        if (Test-Weekend $rd) { $weekend += $min } else { $weekday += $min }
    }
    return @{ Weekday = $weekday; Weekend = $weekend; Total = $weekday + $weekend }
}

# 某自然月统计：Weekday=工作日合计，Weekend=周末加班，Total=合计
function Get-MonthStats {
    param([datetime]$d)
    $rows = @(Read-HistoryRows)
    $weekday = 0.0
    $weekend = 0.0
    foreach ($row in $rows) {
        $rd = ConvertTo-StatsDate $row.date
        if ($null -eq $rd) { continue }
        if ($rd.Year -ne $d.Year -or $rd.Month -ne $d.Month) { continue }
        $min = Get-RecordMinutes $row
        if ($null -eq $min) { continue }
        if (Test-Weekend $rd) { $weekend += $min } else { $weekday += $min }
    }
    return @{ Weekday = $weekday; Weekend = $weekend; Total = $weekday + $weekend }
}

# 统计摘要行（上班/下班弹窗共用）：本周工作日累计 + 50h 达标 + 本月累计
function Get-StatsSummaryLine {
    $now = Get-Date
    $wk = Get-WeekStats $now
    $mo = Get-MonthStats $now
    $parts = New-Object System.Collections.ArrayList
    $null = $parts.Add("本周工作日 $(Format-Duration $wk.Weekday)")
    if ($wk.Weekday -ge 3000) {
        $null = $parts.Add('✅ 达标 (≥50h)')
    } else {
        $null = $parts.Add("还差 $(Format-Duration (3000 - $wk.Weekday)) 达 50h")
    }
    $null = $parts.Add("本月 $(Format-Duration $mo.Total)")
    return ($parts -join ' ｜ ')
}

# 今日工作时长：state 里 date+clockin 到当前时刻；跨天补弹（非当天）用预计 offwork_at
function Get-StateTodayMinutes {
    param($state)
    try {
        if (-not $state -or [string]::IsNullOrWhiteSpace($state.date) -or [string]::IsNullOrWhiteSpace($state.clockin_time)) { return $null }
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$state.date, 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { return $null }
        $t = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$state.clockin_time, [string[]]@('HH:mm', 'H:mm'), $null, [System.Globalization.DateTimeStyles]::None, [ref]$t)) { return $null }
        $start = $d.Date.Add($t.TimeOfDay)
        if ($d.Date -eq (Get-Date).Date) {
            $diff = (Get-Date) - $start
        } else {
            if ([string]::IsNullOrWhiteSpace($state.offwork_at)) { return $null }
            $off = [datetime]::MinValue
            if (-not [datetime]::TryParseExact([string]$state.offwork_at, 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$off)) { return $null }
            $diff = $off - $start
        }
        if ($diff.TotalMinutes -lt 0) { return 0 }
        return $diff.TotalMinutes
    } catch { return $null }
}

# R10/R16: 下班确认后把实际确认时间写入 history.csv 对应行（offwork_actual 列，取最晚）
# v8: offwork_actual 存完整 datetime（yyyy-MM-dd HH:mm:ss，可能次日）；确认后重算该行 duration 列（取最晚后时长可能变）
function Set-HistoryOffworkActual {
    param([string]$date, [string]$actual)
    Invoke-DataLocked {
        try {
            if (-not (Test-Path $script:HistoryFile)) { return }
            $lines = @(Get-Content -Path $script:HistoryFile -Encoding UTF8)
            $changed = $false
            for ($i = 1; $i -lt $lines.Count; $i++) {
                $cols = $lines[$i].Split(',')
                if ($cols.Count -ge 1 -and $cols[0].Trim() -eq $date) {
                    $c1 = if ($cols.Count -ge 2) { $cols[1].Trim() } else { '' }
                    $c2 = if ($cols.Count -ge 3) { $cols[2].Trim() } else { '' }
                    $c3 = if ($cols.Count -ge 4) { $cols[3].Trim() } else { '' }
                    # R16: 同一天多次下班打卡只取最晚——已有更晚记录则跳过（写日志）
                    # v8: 新时间完整 datetime 直接与已有 end 比较；旧 HH:mm 行经跨天推断还原（00:30 次日 > 23:50 当天）
                    if (-not [string]::IsNullOrWhiteSpace($c3)) {
                        $exRow = [pscustomobject]@{ date = $date; clockin = $c1; offwork_at = $c2; offwork_actual = $c3 }
                        $exStart = Get-RecordStart $exRow
                        $exEnd = Get-RecordEnd -row $exRow -start $exStart
                        $newDt = [datetime]::MinValue
                        if ($null -ne $exEnd -and
                            [datetime]::TryParseExact($actual, 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$newDt) -and
                            $newDt -le $exEnd) {
                            Write-Log "Set-HistoryOffworkActual 跳过：$date 已有更晚下班记录 $c3，新时间 $actual 不覆盖"
                            continue
                        }
                    }
                    # v8: 存完整 datetime；用 Get-RecordMinutes 重算 duration（优先 actual，空则回退 at）
                    $durStr = ''
                    $row = [pscustomobject]@{ date = $date; clockin = $c1; offwork_at = $c2; offwork_actual = $actual }
                    $min = Get-RecordMinutes $row
                    if ($null -ne $min) { $durStr = Format-RowDuration $min }
                    $lines[$i] = "$date,$c1,$c2,$actual,$durStr"
                    $changed = $true
                }
            }
            if ($changed) {
                $tmp = "$($script:HistoryFile).tmp"
                $lines | Set-Content -Path $tmp -Encoding UTF8
                Move-Item -Path $tmp -Destination $script:HistoryFile -Force
            }
        } catch {
            Write-Log "Set-HistoryOffworkActual 失败: $($_.Exception.Message)"
        }
    }
}

# R15: 下班确认回写（弹窗线程调用）。
# 校验 state 当前待提醒基准 == 发起弹窗时的基准，防旧弹窗串改新一天数据（ExpectedOffworkAt 防串改）。
# 确认后：offwork_notified=$false 允许再次提醒；next_remind_at = 确认时间 + ReRemindIntervalMinutes。
function Invoke-OffworkConfirm {
    param(
        [string]$ExpectedOffworkAt,
        [datetime]$ConfirmedAt,
        [int]$ReRemindIntervalMinutes = $script:ReRemindIntervalMinutes
    )
    try {
        $state = Read-State
        if (-not $state) { return $false }
        # 当前待提醒基准：next_remind_at（有值用）否则回退 offwork_at
        $stateBase = if (-not [string]::IsNullOrWhiteSpace([string]$state.next_remind_at)) { [string]$state.next_remind_at } else { [string]$state.offwork_at }
        if ($stateBase -ne $ExpectedOffworkAt) {
            Write-Log "Invoke-OffworkConfirm 跳过：state 基准 [$stateBase] != 发起时基准 [$ExpectedOffworkAt]（旧弹窗防串改）"
            return $false
        }
        $state.offwork_notified = $false
        $state.next_remind_at = $ConfirmedAt.AddMinutes($ReRemindIntervalMinutes).ToString('yyyy-MM-dd HH:mm:ss')
        Write-State $state
        # R10/R16: 实际确认时间写入历史（取最晚）
        Set-HistoryOffworkActual -date $state.date -actual $ConfirmedAt.ToString('yyyy-MM-dd HH:mm:ss')
        return $true
    } catch {
        Write-Log "弹窗确认回写失败: $($_.Exception.Message)"
        return $false
    }
}

# ============ 工作日守卫（R1）============
# 周一~周五返回 $true；周六/周日返回 $false
function Test-Workday {
    if (-not $script:SkipWeekend) { return $true }
    $dow = (Get-Date).DayOfWeek
    return ($dow -ne [DayOfWeek]::Saturday) -and ($dow -ne [DayOfWeek]::Sunday)
}

# P1-2: 判断指定日期是否工作日（按 SkipWeekend 配置）。弹窗跨天确认时用发起日判断，
# 避免「周五 23:59 弹窗、周六 00:01 确认」因当前时刻已跨天/跨周末而把确认吞掉。
function Test-WorkdayAt {
    param([string]$dateStr)
    if (-not $script:SkipWeekend) { return $true }
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($dateStr, 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { $d = Get-Date }
    $dow = $d.DayOfWeek
    return ($dow -ne [DayOfWeek]::Saturday) -and ($dow -ne [DayOfWeek]::Sunday)
}

# 上班自动提醒时间窗（R18）：主循环兜底保持 8:00-12:00（防深夜重装误弹）；解锁/启动触发 -AllowLate 放宽到 8:00-23:00
function Test-WorkAutoWindow {
    param([bool]$AllowLate = $false)
    $hour = (Get-Date).Hour
    if ($AllowLate) {
        return ($hour -ge $script:WorkWindowStart) -and ($hour -lt 23)
    }
    return ($hour -ge $script:WorkWindowStart) -and ($hour -lt $script:WorkAutoPopupEnd)
}

# R18: 打卡时间上限小时 = max(WorkWindowEnd, 当前小时)；下午到的人可填 14:00
function Get-WorkEndHour {
    $h = (Get-Date).Hour
    if ($h -lt $script:WorkWindowEnd) { return $script:WorkWindowEnd }
    return $h
}

# R18: 打卡时间是否在允许范围：不早于 WorkStart:00，不晚于 max(WorkEnd:00, 当前时刻)。
# 下午到的人填 14:00（= 当前时刻）不再被拦；超范围保留弹窗 YesNo 确认逻辑（R9）。
# 返回 @{ InRange; MinStr; MaxStr }；时间格式错误返回 $null（弹窗已先做过格式校验）。
function Test-ClockinTimeRange {
    param([string]$HHmm, [int]$WorkStart = $script:WorkWindowStart, [int]$WorkEnd = $script:WorkWindowEnd)
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($HHmm, [string[]]@('HH:mm', 'H:mm'), $null, [System.Globalization.DateTimeStyles]::None, [ref]$t)) { return $null }
    $val = [datetime]::Today.AddHours($t.Hour).AddMinutes($t.Minute)
    $min = [datetime]::Today.AddHours($WorkStart)
    $max = [datetime]::Today.AddHours($WorkEnd)
    $now = Get-Date
    if ($now -gt $max) { $max = $now }
    return @{ InRange = ($val -ge $min -and $val -le $max); MinStr = $min.ToString('H:mm'); MaxStr = $max.ToString('H:mm') }
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
    $form.Tag = @{ Value = $null; Input = $null; Skipped = $false; WithInput = $WithInput; WorkStart = $WorkStart; WorkEnd = $WorkEnd }

    # 拦截 Esc
    $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $_.SuppressKeyPress = $true } })
    # 拦截 Alt+F4 / 一切关闭：未确认且未点后门按钮前禁止关窗
    $form.Add_FormClosing({
        param($sender, $e)
        if ($null -eq $sender.Tag.Value -and -not $sender.Tag.Skipped) { $e.Cancel = $true }
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
            $range = Test-ClockinTimeRange -HHmm $text -WorkStart $tag.WorkStart -WorkEnd $tag.WorkEnd
            if ($null -eq $range) { return }   # 格式错误（上方已校验，理论上不会到这）
            if (-not $range.InRange) {
                # 超范围不再硬拒，弹 YesNo 让用户决定（R9/R18）
                $ask = [System.Windows.Forms.MessageBox]::Show(
                    "实际时间 $text 不在 $($range.MinStr)-$($range.MaxStr)，仍要记录？",
                    '确认', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
            $tag.Value = $t.ToString('HH:mm')
        } else {
            $tag.Value = $true
        }
        $f.Close()
    })
    $form.Controls.Add($btn)
    $form.AcceptButton = $btn   # Enter 键提交（R9）

    # 后门按钮：紧急逃生（防调试时强制弹窗卡死电脑）。低调放右下角，点它关闭弹窗且不写任何打卡数据。
    # 主循环弹窗前已置防重复标记（work_reminder_shown / offwork_notified），关闭后当天不会再弹，不会死循环。
    $escape = New-Object System.Windows.Forms.Button
    $escape.Text = '紧急关闭（不打卡）'
    $escape.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12, [System.Drawing.FontStyle]::Regular)
    $escape.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 0)
    $escape.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 0)
    $escape.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $escape.FlatAppearance.BorderSize = 0
    $escape.SetBounds(($w - 180), ($h - 60), 170, 50)
    $escape.Add_Click({
        param($sender, $e)
        $f = $sender.FindForm()
        $f.Tag.Skipped = $true
        $f.Close()
    })
    $form.Controls.Add($escape)

    # ---- R23: 底部配置区（默认只读摘要；先点「解锁更改配置」才能改，防误触；保存写 config.json）----
    # 锁定条：整宽条（在主确认按钮下方，不与按钮重叠）
    $cfgStrip = New-Object System.Windows.Forms.Panel
    $cfgStrip.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 0)
    $cfgStrip.SetBounds(15, ($h - 62), ($w - 205), 52)
    $form.Controls.Add($cfgStrip)

    $cfgSummary = New-Object System.Windows.Forms.Label
    $cfgSummary.Text = '配置 · ' + (Get-ConfigSummary (Read-Config))
    $cfgSummary.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Regular)
    $cfgSummary.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 0)
    $cfgSummary.BackColor = $cfgStrip.BackColor
    $cfgSummary.SetBounds(8, 4, ($cfgStrip.Width - 140), 44)
    $cfgSummary.TextAlign = 'MiddleLeft'
    $cfgStrip.Controls.Add($cfgSummary)

    $btnUnlock = New-Object System.Windows.Forms.Button
    $btnUnlock.Text = '解锁更改配置'
    $btnUnlock.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9, [System.Drawing.FontStyle]::Regular)
    $btnUnlock.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 0)
    $btnUnlock.BackColor = [System.Drawing.Color]::White
    $btnUnlock.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnUnlock.FlatAppearance.BorderSize = 0
    $btnUnlock.SetBounds(($cfgStrip.Width - 118), 8, 108, 36)
    $cfgStrip.Controls.Add($btnUnlock)

    # 编辑控件（默认隐藏，解锁后显示；放左下角窄区，避开中央确认按钮）
    $cfgNarrow = [Math]::Max(220, [Math]::Min(360, ($cx - 325)))
    $editTop = ($h - 62 - 252)
    $cfgRows = @(
        @{ Name = 'OffWorkHours';            Label = '下班提醒(小时)';  Min = 1;  Max = 23 },
        @{ Name = 'WorkWindowStart';         Label = '上班最早(点)';    Min = 0;  Max = 12 },
        @{ Name = 'WorkWindowEnd';           Label = '打卡最晚(点)';    Min = 1;  Max = 23 },
        @{ Name = 'WorkAutoPopupEnd';        Label = '自动弹最晚(点)';  Min = 1;  Max = 23 },
        @{ Name = 'ReRemindIntervalMinutes'; Label = '循环间隔(分)';    Min = 1;  Max = 480 },
        @{ Name = 'MaxRemindHour';           Label = '最晚提醒(点)';    Min = 0;  Max = 23 }
    )
    $curCfg = Read-Config
    $cfgNuds = @{}
    $rowY = $editTop + 6
    foreach ($r in $cfgRows) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $r.Label
        $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9, [System.Drawing.FontStyle]::Regular)
        $lbl.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 0)
        $lbl.BackColor = $form.BackColor
        $lbl.SetBounds(23, ($rowY + 4), 118, 22)
        $lbl.Visible = $false
        $form.Controls.Add($lbl)

        $nud = New-Object System.Windows.Forms.NumericUpDown
        $nud.Minimum = $r.Min
        $nud.Maximum = $r.Max
        $nud.Value = [Math]::Max($r.Min, [Math]::Min($r.Max, [int]$curCfg[$r.Name]))
        $nud.SetBounds(147, $rowY, 70, 28)
        $nud.Visible = $false
        $form.Controls.Add($nud)
        $cfgNuds[$r.Name] = $nud
        $rowY += 34
    }
    $cfgChk = New-Object System.Windows.Forms.CheckBox
    $cfgChk.Text = '周末跳过'
    $cfgChk.Checked = [bool]$curCfg.SkipWeekend
    $cfgChk.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9, [System.Drawing.FontStyle]::Regular)
    $cfgChk.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 0)
    $cfgChk.SetBounds(23, ($editTop + 214), 100, 28)
    $cfgChk.Visible = $false
    $form.Controls.Add($cfgChk)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = '保存配置'
    $btnSave.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9, [System.Drawing.FontStyle]::Regular)
    $btnSave.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 0)
    $btnSave.BackColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSave.SetBounds((15 + $cfgNarrow - 206), ($editTop + 208), 92, 36)
    $btnSave.Visible = $false
    $form.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9, [System.Drawing.FontStyle]::Regular)
    $btnCancel.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 0)
    $btnCancel.BackColor = [System.Drawing.Color]::White
    $btnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnCancel.SetBounds((15 + $cfgNarrow - 106), ($editTop + 208), 92, 36)
    $btnCancel.Visible = $false
    $form.Controls.Add($btnCancel)

    # 共享引用（事件回调用，与主按钮/逃生按钮一致走 form.Tag）
    $form.Tag.CfgStrip     = $cfgStrip
    $form.Tag.CfgSummary   = $cfgSummary
    $form.Tag.CfgUnlockBtn = $btnUnlock
    $form.Tag.CfgNuds      = $cfgNuds
    $form.Tag.CfgChk       = $cfgChk
    $form.Tag.CfgSaveBtn   = $btnSave
    $form.Tag.CfgCancelBtn = $btnCancel
    $form.Tag.CfgUnlocked  = $false

    $btnUnlock.Add_Click({
        param($sender, $e)
        $f = $sender.FindForm()
        $tag = $f.Tag
        $tag.CfgUnlocked = $true
        $tag.CfgStrip.Visible = $false
        foreach ($n in $tag.CfgNuds.Values) { $n.Visible = $true }
        $tag.CfgChk.Visible = $true
        $tag.CfgSaveBtn.Visible = $true
        $tag.CfgCancelBtn.Visible = $true
    })

    $btnSave.Add_Click({
        param($sender, $e)
        $f = $sender.FindForm()
        $tag = $f.Tag
        $new = @{}
        foreach ($k in $tag.CfgNuds.Keys) { $new[$k] = [int]$tag.CfgNuds[$k].Value }
        $new['SkipWeekend'] = $tag.CfgChk.Checked
        Write-Config $new                                   # 写 config.json；主循环下次轮询重载生效
        $tag.CfgSummary.Text = '配置 · ' + (Get-ConfigSummary $new)
        $tag.CfgUnlocked = $false
        $tag.CfgStrip.Visible = $true
        foreach ($n in $tag.CfgNuds.Values) { $n.Visible = $false }
        $tag.CfgChk.Visible = $false
        $tag.CfgSaveBtn.Visible = $false
        $tag.CfgCancelBtn.Visible = $false
    })

    $btnCancel.Add_Click({
        param($sender, $e)
        $f = $sender.FindForm()
        $tag = $f.Tag
        $tag.CfgUnlocked = $false
        $tag.CfgStrip.Visible = $true
        foreach ($n in $tag.CfgNuds.Values) { $n.Visible = $false }
        $tag.CfgChk.Visible = $false
        $tag.CfgSaveBtn.Visible = $false
        $tag.CfgCancelBtn.Visible = $false
    })

    $null = $form.ShowDialog()
    if ($form.Tag.Skipped) { return $null }   # 逃生：调用方当"未确认"处理
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
        [string]$ExpectedOffworkAt = '',  # 下班弹窗确认时校验，防止旧弹窗串改新一天数据
        [string]$WorkdayDate = '',        # P1-2: 弹窗所属工作日（yyyy-MM-dd）；跨天确认用它做周末守卫，防止周五弹周六确认被吞
        [int]$WorkEnd = $script:WorkWindowEnd   # R18: 打卡时间上限（提示用；下午到放宽到当前时刻）
    )

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.Open()

        $ps = [powershell]::Create()
        $ps.Runspace = $rs

        # 注入共享函数（同进程内线程，避免每弹一次起一个新 powershell 进程）
        $null = $ps.AddScript("function Show-MandatoryDialog { $((Get-Command -Name 'Show-MandatoryDialog').Definition) }")
        $null = $ps.AddScript("function Test-WorkdayAt { $((Get-Command -Name 'Test-WorkdayAt').Definition) }")
        $null = $ps.AddScript("function Invoke-DataLocked { $((Get-Command -Name 'Invoke-DataLocked').Definition) }")
        $null = $ps.AddScript("function Write-State { $((Get-Command -Name 'Write-State').Definition) }")
        $null = $ps.AddScript("function Read-State { $((Get-Command -Name 'Read-State').Definition) }")
        $null = $ps.AddScript("function Add-HistoryLine { $((Get-Command -Name 'Add-HistoryLine').Definition) }")
        $null = $ps.AddScript("function Set-HistoryOffworkActual { $((Get-Command -Name 'Set-HistoryOffworkActual').Definition) }")
        $null = $ps.AddScript("function ConvertTo-HHmm { $((Get-Command -Name 'ConvertTo-HHmm').Definition) }")
        $null = $ps.AddScript("function ConvertTo-StatsDate { $((Get-Command -Name 'ConvertTo-StatsDate').Definition) }")
        $null = $ps.AddScript("function Get-RecordStart { $((Get-Command -Name 'Get-RecordStart').Definition) }")
        $null = $ps.AddScript("function Get-RecordEnd { $((Get-Command -Name 'Get-RecordEnd').Definition) }")
        $null = $ps.AddScript("function Get-RecordMinutes { $((Get-Command -Name 'Get-RecordMinutes').Definition) }")
        $null = $ps.AddScript("function Format-Duration { $((Get-Command -Name 'Format-Duration').Definition) }")
        $null = $ps.AddScript("function Format-RowDuration { $((Get-Command -Name 'Format-RowDuration').Definition) }")
        $null = $ps.AddScript("function Test-ClockinTimeRange { $((Get-Command -Name 'Test-ClockinTimeRange').Definition) }")
        $null = $ps.AddScript("function Invoke-OffworkConfirm { $((Get-Command -Name 'Invoke-OffworkConfirm').Definition) }")
        $null = $ps.AddScript("function Write-Log { $((Get-Command -Name 'Write-Log').Definition) }")
        $null = $ps.AddScript("function Read-Config { $((Get-Command -Name 'Read-Config').Definition) }")
        $null = $ps.AddScript("function Write-Config { $((Get-Command -Name 'Write-Config').Definition) }")
        $null = $ps.AddScript("function Get-ConfigSummary { $((Get-Command -Name 'Get-ConfigSummary').Definition) }")

        $main = @'
param($ctx)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:DataDir      = $ctx.DataDir
$script:StateFile    = $ctx.StateFile
$script:HistoryFile  = $ctx.HistoryFile
$script:LogFile      = $ctx.LogFile
$script:ConfigFile   = $ctx.ConfigFile
$script:DefaultConfig = $ctx.DefaultConfig
$script:DataMutex    = $ctx.DataMutex
$script:SkipWeekend  = $ctx.SkipWeekend
$script:OffWorkHours = $ctx.OffWorkHours
$script:ReRemindIntervalMinutes = $ctx.ReRemindIntervalMinutes

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
        # P1-2: 用发起日判断（弹窗跨天到周末不吞确认）；WorkdayDate 为空时 Test-WorkdayAt 回退当前时刻
        if (-not (Test-WorkdayAt $ctx.WorkdayDate)) { return }
        $clockinDt = [datetime]::ParseExact($result, 'HH:mm', $null)
        # P1-2: 日期、预计下班都锚定发起日，避免跨天确认时记到/算到第二天
        $workDate = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($ctx.WorkdayDate, 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$workDate)) { $workDate = (Get-Date).Date }
        $offworkAt = $workDate.AddHours($clockinDt.Hour).AddMinutes($clockinDt.Minute).AddHours($ctx.OffWorkHours)
        $today = $ctx.WorkdayDate
        $state = Read-State
        if (-not $state) { $state = @{} }
        $state.date = $today
        $state.clockin_time = $result
        $state.offwork_at = $offworkAt.ToString('yyyy-MM-dd HH:mm:ss')
        $state.offwork_notified = $false
        $state.next_remind_at = $null   # R15: 新工作日清掉昨天的循环提醒链，重新从首次提醒开始
        $state.work_reminder_shown = $true
        Write-State $state
        Add-HistoryLine -date $today -clockin $result -offworkAt $state.offwork_at
    } else {
        # P1-2: 用发起日（state.date，周五）判断，周五 23:59 弹、周六 00:01 确认不再被吞
        if (-not (Test-WorkdayAt $ctx.WorkdayDate)) { return }
        # R15: 确认回写（校验基准防串改；offwork_notified=$false 允许再次提醒；next_remind_at = 确认时间 + 间隔）
        Invoke-OffworkConfirm -ExpectedOffworkAt $ctx.ExpectedOffworkAt -ConfirmedAt (Get-Date) -ReRemindIntervalMinutes $ctx.ReRemindIntervalMinutes
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
            WorkWindowEnd = $WorkEnd
            OffWorkHours = $script:OffWorkHours
            ReRemindIntervalMinutes = $script:ReRemindIntervalMinutes
            SkipWeekend = $script:SkipWeekend
            DataDir = $script:DataDir
            StateFile = $script:StateFile
            HistoryFile = $script:HistoryFile
            LogFile = $script:LogFile
            ConfigFile = $script:ConfigFile
            DefaultConfig = $script:DefaultConfig
            DataMutex = $script:DataMutex
            WorkdayDate = $WorkdayDate
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

# ============ 上班打卡流程（异步弹窗；R1/R2/R3/R4 守卫；R18 解锁/启动放宽）============
function Invoke-WorkReminder {
    param([bool]$AllowLate = $false)          # R18: 解锁/启动触发传 $true，时间窗放宽到 8:00-23:00
    Reload-Config                                          # R23: 配置变更下次轮询生效
    if (-not (Test-Workday)) { return }                    # R1 周末守卫
    if (-not (Test-WorkAutoWindow -AllowLate $AllowLate)) { return }   # R3/R4 兜底 8-12；R18 解锁/启动放宽
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
    $statLine = Get-StatsSummaryLine
    $endHour = Get-WorkEndHour
    if ($now.Hour -ge 12) {
        # R18: 下午到/迟到，提示如实填写实际打卡时间（可填 14:00）
        $subMsg = "迟到/下午到，如实填写实际打卡时间（$($script:WorkWindowStart):00-$($now.ToString('H:mm'))）"
    } else {
        $subMsg = "填写实际打卡时间（$($script:WorkWindowStart):00-$endHour:00）"
    }
    Start-DialogRunspace -Kind 'work' -Title '上班打卡提醒' `
        -Message "记得飞书打卡上班！`n$statLine" `
        -SubMessage $subMsg `
        -InputDefault $now.ToString('HH:mm') `
        -WorkdayDate $today `
        -WorkEnd $endHour
}

# ============ 下班检查（主循环调用；跨天补弹 R8；周末守卫 R1；异步弹窗 R2；加班循环 R15）============
function Invoke-OffWorkCheck {
    Reload-Config                                          # R23: 配置变更下次轮询生效
    if (-not (Test-Workday)) { return }                    # R1 周末守卫
    $state = Read-State
    if (-not $state -or $state.offwork_notified) { return }
    $now = Get-Date
    # R15: 待提醒基准 = next_remind_at（有值用，循环提醒），否则回退 offwork_at（首次提醒 / 旧 state 兼容）
    $isRepeat = -not [string]::IsNullOrWhiteSpace([string]$state.next_remind_at)
    $baseRaw = if ($isRepeat) { [string]$state.next_remind_at } else { [string]$state.offwork_at }
    $target = $null
    try { $target = [datetime]::ParseExact($baseRaw, 'yyyy-MM-dd HH:mm:ss', $null) } catch { return }  # R5
    if ($now -lt $target) { return }
    # R15: 循环提醒只限当天（防跨天残留 next_remind_at 深夜/次日骚扰）；首次提醒保留跨天补弹（R8）
    if ($isRepeat -and $target.Date -ne $now.Date) { return }
    # R15: 超过当天最晚提醒时间不再自动弹（防深夜骚扰）
    if ($now.Hour -ge $script:MaxRemindHour) { return }

    # 先置标记再弹（R2），防止重复弹；下次确认后再重置为 $false 允许循环（R15）
    $state.offwork_notified = $true
    Write-State $state

    # R17: 首次「可以打下班卡了」；第 N 次（N>=2）显示已满 X 小时（加班 Y 小时）再确认
    if ($isRepeat) {
        $start = $null
        $sd = [datetime]::MinValue
        $st = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$state.date, 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$sd) -and
            [datetime]::TryParseExact([string]$state.clockin_time, [string[]]@('HH:mm', 'H:mm'), $null, [System.Globalization.DateTimeStyles]::None, [ref]$st)) {
            $start = $sd.Date.Add($st.TimeOfDay)
        }
        if ($null -ne $start) {
            $X = [math]::Floor(($target - $start).TotalHours)
            $Y = $X - $script:OffWorkHours
            $msg = "上班 $($state.clockin_time) 打卡，已满 $X 小时（加班 $Y 小时），再次确认下班打卡！"
        } else {
            $msg = "上班 $($state.clockin_time) 打卡，已满 $script:OffWorkHours 小时，再次确认下班打卡！"
        }
    } else {
        $msg = "上班 $($state.clockin_time) 打卡，已满 $script:OffWorkHours 小时，可以打下班卡了！"
    }
    # R12: 下班确认弹窗附带 今日时长 + 本周工作日累计 + 50h 达标状态（附加信息，不改变强制确认语义）
    $todayMin = Get-StateTodayMinutes $state
    $wk = Get-WeekStats $now
    $statParts = New-Object System.Collections.ArrayList
    if ($null -ne $todayMin) {
        $null = $statParts.Add("今日时长 $(Format-Duration $todayMin)")
    }
    $null = $statParts.Add("本周工作日合计 $(Format-Duration $wk.Weekday)")
    $statLine = $statParts -join ' ｜ '
    if ($wk.Weekday -ge 3000) {
        $statLine += ' ✅ 达标 (≥50h)'
    } else {
        $statLine += " ⚠️ 还差 $(Format-Duration (3000 - $wk.Weekday)) 达 50h"
    }
    $msg += "`n$statLine"
    Start-DialogRunspace -Kind 'offwork' -Title '下班打卡提醒' -Message $msg `
        -ExpectedOffworkAt $baseRaw `
        -WorkdayDate $state.date   # P1-2: 弹窗所属工作日（state.date），周五弹周六确认不被吞
}

# ============ 全天缺勤补记 0 时长（R19）============
# 补 0 时长行：date,,,,0h 0min（上班/下班空，工作时长 0h 0min）；当天已有行则跳过（去重，防重复补）
function Add-AbsenceLine {
    param([string]$date)
    Invoke-DataLocked {
        try {
            if (-not (Test-Path $script:HistoryFile)) {
                Set-Content -Path $script:HistoryFile -Value '日期,上班时间,预计下班,实际下班,工作时长' -Encoding UTF8
            }
            if (Select-String -Path $script:HistoryFile -Pattern "^$date," -Quiet) { return }   # 去重：已有行不重复补
            Add-Content -Path $script:HistoryFile -Value "$date,,,,0h 0min" -Encoding UTF8
            Write-Log "补记缺勤：$date 0h 0min"
        } catch {
            Write-Log "Add-AbsenceLine 失败: $($_.Exception.Message)"
        }
    }
}

# 主循环调用：当天 20 点后无记录 → 补当天 0h 0min（白天还在上班不判；周末没去也补 0，用户要求）
function Invoke-AbsenceCheck {
    if ((Get-Date).Hour -lt 20) { return }         # 20 点前不算"今天没来"
    Add-AbsenceLine -date (Get-Date).ToString('yyyy-MM-dd')
}

# 启动时调用：昨天无记录 → 补昨天 0h 0min（整天没开电脑漏记；周末没去也补 0）
function Invoke-AbsenceBackfill {
    $yesterday = (Get-Date).Date.AddDays(-1)
    Add-AbsenceLine -date $yesterday.ToString('yyyy-MM-dd')
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

# P1-3: 数据文件互斥（与上面的单实例 Mutex 是不同名字）。history/state/config 读写串行化，
# 防 runspace 弹窗线程与主循环并发写竞态。命名 Mutex 同进程多线程/跨进程共享，runspace 里由 ctx 传入。
$script:DataMutex = $null
try {
    $script:DataMutex = New-Object System.Threading.Mutex($false, "ClockinReminder_Data_$sid")
} catch {
    Write-Log "数据互斥创建失败，退化为不加锁: $($_.Exception.Message)"
}

# ============ 启动 ============
Ensure-DataDir
# R21: 启动读 config.json；不存在则用默认值并写出（自动创建）
if (-not (Test-Path $script:ConfigFile)) { Write-Config $script:DefaultConfig }
Reload-Config
Invoke-AbsenceBackfill                          # R19: 启动时补前一天（整天没开电脑漏记 0h 0min）
$now = Get-Date
if ((Test-Workday) -and $now.Hour -lt $script:WorkWindowStart) {
    # 8 点前：不轮询，睡到 8 点（过工作日守卫；周末不睡不弹）
    $eight = [datetime]::Today.AddHours($script:WorkWindowStart)
    Start-Sleep -Seconds ([int](($eight - $now).TotalSeconds) + 1)
}
# R18: 启动触发（人到了开机才弹）：放宽到 8:00-23:00（12 点后启动当天也弹；主循环兜底仍 8-12 不覆盖）
Invoke-WorkReminder -AllowLate $true
# 8:00-12:00 启动：主循环仍每 2 分钟兜底（R3）

# ============ 主循环（2 分钟轮询；try/catch 防脚本自杀 R5）============
$prevLocked = Test-Locked
while ($true) {
    try {
        Start-Sleep -Seconds 120
        Invoke-OffWorkCheck
        Invoke-AbsenceCheck              # R19: 工作日 20 点后无记录补 0h 0min（去重）
        Invoke-WorkReminder              # R3 每天 8 点兜底（不依赖启动/解锁事件；跨天常驻第二天 8 点也能弹）
        Cleanup-DialogRunspaces
        $locked = Test-Locked
        if ($prevLocked -and -not $locked) {
            Invoke-WorkReminder -AllowLate $true   # R18: 解锁触发放宽到 8:00-23:00（人到了解锁才弹）
        }
        $prevLocked = $locked
    } catch {
        Write-Log "主循环异常: $($_.Exception.Message)"
        Start-Sleep -Seconds 30          # 睡 30 秒继续，不允许脚本自己死掉
    }
}
