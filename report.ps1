#Requires -Version 5.1
<#
  report.ps1  —  打卡时长统计报告（纯文本，不弹窗，v8）
  用法（Windows PowerShell 5.1+）：
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1            # 本周（默认）
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Week
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Month
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -All
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Days 7
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Gui          # GUI 窗口
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Gui -Save   # GUI + 存 log\report-日期.csv
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Help         # 显示本帮助
  说明：
    - 数据来自脚本同目录（log 周文件 + history.csv 兼容；R31）
    - 兼容 3 列（旧）/4 列（v3/v4）/5 列（v5 HH:mm / v8 完整 datetime）；offwork_actual 为空时回退 offwork_at（预计值）
    - v8: offwork 时间存完整 datetime（含日期，下班可能次日）；旧 HH:mm 行走跨天推断 fallback（与主脚本 Get-RecordEnd 一致）
    - v6: 请假/全天缺勤行（上班/下班都空）显示 0h 0min (请假)，计入工作日占位（不拉高不拉低）
    - 周 = 周一~周日；工作日合计（周一~周五）用于 50h 达标，周末加班单列
    - 解析失败的行跳过并在末尾提示行号
#>
param(
    [switch]$Week,
    [switch]$Month,
    [switch]$All,
    [int]$Days = 0,
    [switch]$Gui,
    [switch]$Save,
    [switch]$Help
)
$ErrorActionPreference = 'Stop'

# -Help：打印文件头部说明块（<# ... #>）后退出（不读数据、不弹窗）
if ($Help) {
    $raw = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
    if ($raw -match '(?s)<#(.*?)#>') {
        $matches[1] -split "`r?`n" | ForEach-Object { $_ -replace '^\s+', '' } | Where-Object { $_ -ne '' }
    }
    exit 0
}

$script:DataDir      = $PSScriptRoot
$script:HistoryFile  = Join-Path $script:DataDir 'history.csv'          # 旧单文件（兼容，若存在也合并读）
$script:LogDir       = Join-Path $script:DataDir 'log'                  # v8: 周文件目录
$script:StateFile    = Join-Path $script:LogDir 'state.json'            # R38: 状态进 log（老版本在根目录，兼容回退）
$script:ConfigFile   = Join-Path $script:LogDir 'config.json'           # R38: 配置进 log
$script:TargetMinutesPerWeek = 3000   # 每周目标工时默认 50h（可在 config.json 配 TargetMinutesPerWeek）
$script:LogFile      = Join-Path $script:LogDir 'log.txt'               # R38: 日志进 log

# R38: 老版本数据在根目录（state.json / config.json / log.txt）→ 兼容回退读取（老版本升级后 report 也能查到）
foreach ($f in @('state.json', 'config.json', 'log.txt')) {
    $new = Join-Path $script:LogDir $f
    if (-not (Test-Path $new)) {
        $old = Join-Path $script:DataDir $f
        if (Test-Path $old) {
            switch ($f) {
                'state.json'  { $script:StateFile  = $old }
                'config.json' { $script:ConfigFile = $old }
                'log.txt'     { $script:LogFile    = $old }
            }
        }
    }
}
$script:SkippedLines = New-Object System.Collections.ArrayList

# ============ 运行状态检查（R32：双击 report-gui.bat 即可查看主程序是否正常运行）============
# 判定逻辑（心跳源 = state.json last_heartbeat_at）：
#   - state.json 的 last_heartbeat_at ≤10 分钟前更新 → 运行中（主脚本每 2 分钟写一次）
#   - 心跳缺失或过期 → 未运行 / 主循环卡死
#   - 附带显示：进程实例数、今日 state、最近日志错误计数、配置摘要
function Get-RunStatus {
    $lines = New-Object System.Collections.ArrayList

    # 1) 心跳（读 state.json last_heartbeat_at，主脚本每轮写；≤10 分钟 = 正常）
    $hbOk = $false
    $hbTime = $null
    $hbMissing = $true
    if (Test-Path $script:StateFile) {
        try {
            $st = Get-Content -Path $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $st -and $null -ne $st.PSObject.Properties['last_heartbeat_at']) {
                $hbRaw = [string]$st.last_heartbeat_at
                if (-not [string]::IsNullOrWhiteSpace($hbRaw)) {
                    $hbMissing = $false
                    $hbTime = [datetime]::MinValue
                    if ([datetime]::TryParseExact($hbRaw, 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$hbTime)) {
                        $hbOk = ((Get-Date) - $hbTime).TotalMinutes -le 10
                    }
                }
            }
        } catch { }
    }

    if ($hbOk) {
        $null = $lines.Add('✅ 主程序运行中')
        $null = $lines.Add(("   心跳: {0:yyyy-MM-dd HH:mm:ss}（{1:N0} 分钟前）" -f $hbTime, ((Get-Date) - $hbTime).TotalMinutes))
    } else {
        $null = $lines.Add('❌ 主程序未运行')
        if ($hbMissing) {
            $null = $lines.Add('   心跳: state.json 无 last_heartbeat_at（主脚本版本旧，需更新）')
        } elseif ($null -eq $hbTime) {
            $null = $lines.Add('   心跳: last_heartbeat_at 无法解析')
        } else {
            $null = $lines.Add(("   心跳: {0:yyyy-MM-dd HH:mm:ss}（已过期 {1:N1} 分钟）" -f $hbTime, ((Get-Date) - $hbTime).TotalMinutes))
        }
    }

    # 2) 进程探测（辅助确认：按命令行匹配 clockin-reminder.ps1；非 Windows/权限不足时跳过不阻塞）
    try {
        $proc = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*clockin-reminder.ps1*' })
        if ($proc.Count -gt 0) {
            $null = $lines.Add(("   进程: 找到 {0} 个实例（PID {1}）" -f $proc.Count, (($proc | ForEach-Object { $_.ProcessId }) -join ', ')))
        } elseif (-not $hbOk) {
            $null = $lines.Add('   进程: 未找到 clockin-reminder.ps1 实例')
        }
    } catch {
        $null = $lines.Add('   进程: 无法探测（非 Windows 环境或权限不足）')
    }

    # 3) 今日状态（state.json）
    if (Test-Path $script:StateFile) {
        try {
            $st = Get-Content -Path $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $today = (Get-Date).ToString('yyyy-MM-dd')
            if ($null -ne $st -and $st.date -eq $today) {
                $ckStr = if ([string]::IsNullOrWhiteSpace([string]$st.clockin_time)) { '--' } else { $st.clockin_time }
                $null = $lines.Add(("   今日 {0}: 上班 {1} · 下班提醒 {2}" -f $today, $ckStr, $(if ($st.offwork_notified) { '已触发' } else { '未触发' })))
            } else {
                $null = $lines.Add(('   今日 {0}: 尚无记录' -f $today))
            }
        } catch {
            $null = $lines.Add('   state.json 读取失败（可能损坏）')
        }
    } else {
        $null = $lines.Add('   今日: 无 state.json（今天尚未解锁/打卡）')
    }

    # 4) 最近日志错误计数（log.txt 中 ERROR/失败/异常）
    $errCount = 0
    if (Test-Path $script:LogFile) {
        try {
            $errCount = @(Get-Content -Path $script:LogFile -Encoding UTF8 -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '失败|异常|Error|错误' }).Count
        } catch { }
        $null = $lines.Add(("   日志: log.txt 共 {0} 条异常记录" -f $errCount))
    } else {
        $null = $lines.Add('   日志: log.txt 不存在（无异常记录）')
    }

    # 5) 配置摘要
    if (Test-Path $script:ConfigFile) {
        try {
            $cfg = Get-Content -Path $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.TargetMinutesPerWeek) { $script:TargetMinutesPerWeek = [int]$cfg.TargetMinutesPerWeek }
            $null = $lines.Add(("   配置: 满 {0}h 提醒下班 · 上班窗 {1}-{2}点 · 循环 {3}min · {4}点截止 · 周目标 {5}h{6}" -f
                $cfg.OffWorkHours, $cfg.WorkWindowStart, $cfg.WorkAutoPopupEnd, $cfg.ReRemindIntervalMinutes, $cfg.MaxRemindHour,
                [math]::Round(([double]($cfg.TargetMinutesPerWeek) / 60), 1),
                $(if ($cfg.SkipWeekend) { ' · 周末跳过' } else { '' })))
        } catch {
            $null = $lines.Add('   配置: config.json 读取失败（可能损坏，主脚本将用默认值）')
        }
    } else {
        $null = $lines.Add('   配置: config.json 不存在（使用默认配置）')
    }

    return $lines
}

# ============ 历史读取与解析（与主脚本一致：log 周文件 + 旧 history.csv 合并；R28）============
function Read-HistoryFile {
    param([string]$Path)
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

# R28: 合并读取全部历史——log\*.csv 周文件（文件名=周一日期，按日期排序）+ 根目录旧 history.csv（迁移兼容）。
# 只合并周数据文件（yyyy-MM-dd.csv）；跳过 week-*.csv 等非数据文件（旧导出格式，防止误解析进统计）。
function Read-HistoryRows {
    $rows = @()
    $files = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace([string]$script:LogDir) -and (Test-Path $script:LogDir)) {
        foreach ($f in @(Get-ChildItem -Path $script:LogDir -Filter '*.csv' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            $fd = [datetime]::MinValue
            if ([datetime]::TryParseExact($base, 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$fd)) {
                $null = $files.Add($f.FullName)
            }
        }
    }
    if (Test-Path $script:HistoryFile) { $null = $files.Add($script:HistoryFile) }
    foreach ($f in @($files)) {
        foreach ($row in @(Read-HistoryFile -Path $f)) { $rows += $row }
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

# v8: offwork 时间 CSV 里存完整 datetime（含日期，下班可能次日）→ 直接解析；旧 HH:mm 行走跨天推断 fallback（R28 兼容）
function Get-RecordEnd {
    param($row, $start)
    $s = $row.offwork_actual
    if ([string]::IsNullOrWhiteSpace($s)) { $s = $row.offwork_at }
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    # v8 完整 datetime（含空格即有日期，可能次日）：直接解析
    if ($s.Contains(' ')) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($s, 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
        if ([datetime]::TryParseExact($s, 'yyyy-MM-dd HH:mm', $null, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
        return $null
    }
    # v5 纯时间（HH:mm）：与 start 组合做跨天推断（end < start → +1 天，C1 fallback）
    $t = [datetime]::MinValue
    if ([datetime]::TryParseExact($s, [string[]]@('HH:mm', 'H:mm'), $null, [System.Globalization.DateTimeStyles]::None, [ref]$t)) {
        if ($null -eq $start) { return $null }
        $end = $start.Date.Add($t.TimeOfDay)
        if ($end -lt $start) { $end = $end.AddDays(1) }
        return $end
    }
    return $null
}

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

function Format-Duration {
    param([double]$Minutes)
    if ($Minutes -lt 0) { $Minutes = 0 }
    $total = [math]::Round($Minutes)
    $h = [math]::Floor($total / 60)
    $m = $total % 60
    return ('{0}h {1}min' -f $h, $m)
}

function Test-Weekend {
    param([datetime]$d)
    $dow = $d.DayOfWeek
    return ($dow -eq [DayOfWeek]::Saturday) -or ($dow -eq [DayOfWeek]::Sunday)
}

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

# ============ 输出 ============
# 某一天的所有记录明细；返回 @{ Lines; Weekday; Weekend; Count }，不直接输出
function Write-DayDetail {
    param([datetime]$day, $rows)
    $dayRows = @($rows | Where-Object { $_.date -eq $day.ToString('yyyy-MM-dd') })
    $lines = New-Object System.Collections.ArrayList
    $weekday = 0.0
    $weekend = 0.0
    if ($dayRows.Count -eq 0) {
        $null = $lines.Add(("  {0} {1:MM-dd}  -" -f (Get-WeekdayName $day), $day))
        return @{ Lines = @($lines); Weekday = $weekday; Weekend = $weekend; Count = 0 }
    }
    foreach ($row in $dayRows) {
        $start = Get-RecordStart $row
        $end = Get-RecordEnd -row $row -start $start
        $min = Get-RecordMinutes $row
        # R20: 请假/全天缺勤行（上班/下班都空）→ 显示 0h 0min (请假)，而不是缺卡标记
        if ([string]::IsNullOrWhiteSpace($row.clockin) -and [string]::IsNullOrWhiteSpace($row.offwork_at) -and [string]::IsNullOrWhiteSpace($row.offwork_actual)) {
            $durDisp = if ([string]::IsNullOrWhiteSpace($row.duration)) { '0h 0min' } else { $row.duration }
            $null = $lines.Add(("  {0} {1:MM-dd}  -  -  {2}  (请假)" -f (Get-WeekdayName $day), $day, $durDisp))
        } elseif ($null -eq $start) {
            $null = $lines.Add(("  {0} {1:MM-dd}  缺上班卡" -f (Get-WeekdayName $day), $day))
        } elseif ($null -eq $end) {
            $null = $lines.Add(("  {0} {1:MM-dd}  {2:HH:mm} -> 缺下班卡" -f (Get-WeekdayName $day), $day, $start))
        } else {
            $null = $lines.Add(("  {0} {1:MM-dd}  {2:HH:mm} -> {3:HH:mm}  {4}" -f (Get-WeekdayName $day), $day, $start, $end, (Format-Duration $min)))
        }
        if ($null -ne $min) {
            if (Test-Weekend $day) { $weekend += $min } else { $weekday += $min }
        }
    }
    return @{ Lines = @($lines); Weekday = $weekday; Weekend = $weekend; Count = $dayRows.Count }
}

function Show-WeekReport {
    param([datetime]$d)
    $range = Get-WeekRange $d
    Write-Output ("本周 ({0:yyyy-MM-dd} ~ {1:yyyy-MM-dd})" -f $range.Monday, $range.Sunday)
    $rows = @(Read-HistoryRows)
    $weekdayMin = 0.0
    $weekendMin = 0.0
    for ($day = $range.Monday; $day -le $range.Sunday; $day = $day.AddDays(1)) {
        $r = Write-DayDetail -day $day -rows $rows
        foreach ($ln in $r.Lines) { Write-Output $ln }
        $weekdayMin += $r.Weekday
        $weekendMin += $r.Weekend
    }
    Write-Output ''
    $threshold = [double]($script:TargetMinutesPerWeek)   # 每周目标工时（默认 50h*60=3000）
    if ($weekdayMin -ge $threshold) {
        Write-Output ("  工作日合计   {0}  ✅ 达标 (≥{1}h)" -f (Format-Duration $weekdayMin), [math]::Round($threshold / 60, 1))
    } else {
        Write-Output ("  工作日合计   {0}  ⚠️ 还差 {1} (需≥{2}h)" -f (Format-Duration $weekdayMin), (Format-Duration ($threshold - $weekdayMin)), [math]::Round($threshold / 60, 1))
    }
    Write-Output ("  周末加班     {0}" -f (Format-Duration $weekendMin))
    Write-Output ("  本周总计     {0}" -f (Format-Duration ($weekdayMin + $weekendMin)))
}

function Show-MonthReport {
    param([datetime]$d)
    $first = [datetime]::new($d.Year, $d.Month, 1)
    $last = $first.AddMonths(1).AddDays(-1)
    $rows = @(Read-HistoryRows)
    $weekdayMin = 0.0
    $weekendMin = 0.0
    foreach ($row in $rows) {
        $rd = ConvertTo-StatsDate $row.date
        if ($null -eq $rd) { continue }
        if ($rd -lt $first -or $rd -gt $last) { continue }
        $min = Get-RecordMinutes $row
        if ($null -eq $min) { continue }
        if (Test-Weekend $rd) { $weekendMin += $min } else { $weekdayMin += $min }
    }
    Write-Output ("本月 ({0:yyyy-MM}) 工作日 {1} / 加班 {2} / 合计 {3}" -f $d, (Format-Duration $weekdayMin), (Format-Duration $weekendMin), (Format-Duration ($weekdayMin + $weekendMin)))
}

function Show-AllReport {
    Write-Output '全部明细'
    $rows = @(Read-HistoryRows)
    if ($rows.Count -eq 0) { Write-Output '  （无记录）'; return }
    $totalMin = 0.0
    foreach ($row in $rows) {
        $rd = ConvertTo-StatsDate $row.date
        if ($null -eq $rd) { continue }
        $start = Get-RecordStart $row
        $end = Get-RecordEnd -row $row -start $start
        $min = Get-RecordMinutes $row
        # R20: 请假/全天缺勤行 → 显示 0h 0min (请假)
        if ([string]::IsNullOrWhiteSpace($row.clockin) -and [string]::IsNullOrWhiteSpace($row.offwork_at) -and [string]::IsNullOrWhiteSpace($row.offwork_actual)) {
            $durDisp = if ([string]::IsNullOrWhiteSpace($row.duration)) { '0h 0min' } else { $row.duration }
            Write-Output ("  {0:yyyy-MM-dd}（{1}）  -  -  {2}  (请假)" -f $rd, (Get-WeekdayName $rd), $durDisp)
        } elseif ($null -eq $start) {
            Write-Output ("  {0:yyyy-MM-dd}（{1}）  缺上班卡" -f $rd, (Get-WeekdayName $rd))
        } elseif ($null -eq $end) {
            Write-Output ("  {0:yyyy-MM-dd}（{1}）  {2:HH:mm} -> 缺下班卡" -f $rd, (Get-WeekdayName $rd), $start)
        } else {
            Write-Output ("  {0:yyyy-MM-dd}（{1}）  {2:HH:mm} -> {3:HH:mm}  {4}" -f $rd, (Get-WeekdayName $rd), $start, $end, (Format-Duration $min))
        }
        if ($null -ne $min) { $totalMin += $min }
    }
    Write-Output ''
    Write-Output ("  合计  {0}" -f (Format-Duration $totalMin))
}

function Show-DaysReport {
    param([int]$N)
    if ($N -le 0) { $N = 1 }
    $rows = @(Read-HistoryRows)
    $startDay = (Get-Date).Date.AddDays(-($N - 1))
    $endDay = (Get-Date).Date
    Write-Output ("最近 {0} 天 ({1:yyyy-MM-dd} ~ {2:yyyy-MM-dd})" -f $N, $startDay, $endDay)
    $weekdayMin = 0.0
    $weekendMin = 0.0
    for ($day = $startDay; $day -le $endDay; $day = $day.AddDays(1)) {
        $r = Write-DayDetail -day $day -rows $rows
        foreach ($ln in $r.Lines) { Write-Output $ln }
        $weekdayMin += $r.Weekday
        $weekendMin += $r.Weekend
    }
    Write-Output ''
    Write-Output ("  工作日合计   {0}" -f (Format-Duration $weekdayMin))
    Write-Output ("  周末加班     {0}" -f (Format-Duration $weekendMin))
    Write-Output ("  总计         {0}" -f (Format-Duration ($weekdayMin + $weekendMin)))
}

# ============ 每周 CSV 导出（log 文件夹，每周期一个文件）============
# 生成 脚本同目录\log\week-<年-W周>.csv
# 内容：本周每天的明细（CSV 行）+ 周统计 + 本月累计统计（满足"包含该月已有数据"）
function Export-WeeklyCsv {
    param([datetime]$d = (Get-Date))
    try {
        $logDir = Join-Path $script:DataDir 'log'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

        $range = Get-WeekRange $d
        $weekNum = [System.Globalization.CultureInfo]::InvariantCulture.Calendar.GetWeekOfYear(
            $d, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)
        $file = Join-Path $logDir ("week-{0}-W{1:D2}.csv" -f $d.Year, $weekNum)

        $rows = @(Read-HistoryRows)
        $lines = New-Object System.Collections.ArrayList
        $null = $lines.Add('日期,星期,上班时间,预计下班,实际下班,工作时长')
        $weekdayMin = 0.0; $weekendMin = 0.0
        $weekStart = $range.Monday; $weekEnd = $range.Sunday
        for ($day = $weekStart; $day -le $weekEnd; $day = $day.AddDays(1)) {
            $dayStr = $day.ToString('yyyy-MM-dd')
            $row = $rows | Where-Object { $_.date -eq $dayStr } | Select-Object -First 1
            if ($null -eq $row) {
                $null = $lines.Add(("{0},{1},,,," -f $dayStr, (Get-WeekdayName $day)))
                continue
            }
            $start = Get-RecordStart $row
            $end = Get-RecordEnd $row $start
            $min = Get-RecordMinutes $row
            $startStr = if ($null -ne $start) { $start.ToString('HH:mm') } else { '' }
            $endStr = if ($null -ne $end) { $end.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
            $durStr = if ($null -ne $min) { Format-Duration $min } else { '' }
            $null = $lines.Add(("{0},{1},{2},{3},{4},{5}" -f $dayStr, (Get-WeekdayName $day), $startStr, $row.offwork_at, $endStr, $durStr))
            if ($null -ne $min) {
                if (Test-Weekend $day) { $weekendMin += $min } else { $weekdayMin += $min }
            }
        }

        # 周统计
        $null = $lines.Add('')
        $null = $lines.Add(('本周统计,{0} ~ {1}' -f $weekStart.ToString('yyyy-MM-dd'), $weekEnd.ToString('yyyy-MM-dd')))
        $null = $lines.Add(('工作日合计,,{0}' -f (Format-Duration $weekdayMin)))
        $null = $lines.Add(('周末加班,,{0}' -f (Format-Duration $weekendMin)))
        $null = $lines.Add(('本周总计,,{0}' -f (Format-Duration ($weekdayMin + $weekendMin))))
        if ($weekdayMin -ge $script:TargetMinutesPerWeek) {
            $null = $lines.Add(('50h达标,,✅ 达标 (≥{0}h)' -f [math]::Round($script:TargetMinutesPerWeek / 60, 1)))
        } else {
            $null = $lines.Add(('50h达标,,⚠️ 还差 {0} 达目标工时' -f (Format-Duration ($script:TargetMinutesPerWeek - $weekdayMin))))
        }

        # 本月累计（满足"包含该月已有数据"）— 内联计算（report 无 Get-MonthStats）
        $first = [datetime]::new($d.Year, $d.Month, 1)
        $last = $first.AddMonths(1).AddDays(-1)
        $mWeekday = 0.0; $mWeekend = 0.0
        foreach ($row in $rows) {
            $rd = ConvertTo-StatsDate $row.date
            if ($null -eq $rd) { continue }
            if ($rd -lt $first -or $rd -gt $last) { continue }
            $min = Get-RecordMinutes $row
            if ($null -eq $min) { continue }
            if (Test-Weekend $rd) { $mWeekend += $min } else { $mWeekday += $min }
        }
        $null = $lines.Add('')
        $null = $lines.Add(('本月累计,{0:yyyy-MM}' -f $d))
        $null = $lines.Add(('本月工作日,,{0}' -f (Format-Duration $mWeekday)))
        $null = $lines.Add(('本月加班,,{0}' -f (Format-Duration $mWeekend)))
        $null = $lines.Add(('本月合计,,{0}' -f (Format-Duration ($mWeekday + $mWeekend))))

        $lines | Set-Content -Path $file -Encoding UTF8
        return $file
    } catch {
        Write-Warning "生成每周 CSV 失败: $($_.Exception.Message)"
        return $null
    }
}

# ============ 入口 ============
$report = New-Object System.Collections.ArrayList
# R32: 运行状态检查（主程序是否在跑）——始终置顶显示，双击 report-gui.bat 即可查看
$null = $report.AddRange(@('==================== 运行状态 ====================', ''))
try {
    $null = $report.AddRange(@(Get-RunStatus))
} catch {
    $null = $report.AddRange(@("⚠️ 运行状态检查失败: $($_.Exception.Message)"))
}
$null = $report.AddRange(@('', '==================== 打卡统计 ===================='))
# R28: 数据在 log 周文件（v8+）或旧根目录 history.csv（迁移兼容）；两者都没有才算无记录
$logHasData = (Test-Path $script:LogDir) -and @(Get-ChildItem -Path $script:LogDir -Filter '*.csv' -File -ErrorAction SilentlyContinue | Where-Object {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    $fd = [datetime]::MinValue
    [datetime]::TryParseExact($base, 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$fd)
}).Count -gt 0
if (-not $logHasData -and -not (Test-Path $script:HistoryFile)) {
    $null = $report.Add('暂无打卡记录（log 周文件与 history.csv 均无数据）。')
} else {
    if ($Days -gt 0)      { $null = $report.AddRange(@(Show-DaysReport -N $Days)) }
    elseif ($Month)       { $null = $report.AddRange(@(Show-MonthReport -d (Get-Date))) }
    elseif ($All)         { $null = $report.AddRange(@(Show-AllReport)) }
    else                  { $null = $report.AddRange(@(Show-WeekReport -d (Get-Date))) }   # 默认本周

    if ($script:SkippedLines.Count -gt 0) {
        $null = $report.Add('')
        $null = $report.Add("提示：已跳过 $($script:SkippedLines.Count) 行无法解析的记录（第 $($script:SkippedLines -join '、') 行）")
    }
}

if ($Gui) {
    # GUI 模式：弹只读窗口显示统计（双击 report-gui.bat 或 -Gui 参数）
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = '打卡工具 · 运行状态与统计报告'
    $form.Size = New-Object System.Drawing.Size(820, 640)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true
    $txt.ReadOnly = $true
    $txt.ScrollBars = 'Vertical'
    $txt.Font = New-Object System.Drawing.Font('Consolas', 11)
    $txt.Dock = 'Fill'
    $txt.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txt.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $txt.BorderStyle = 'None'
    $txt.Text = $report -join "`r`n"
    $form.Controls.Add($txt)
    $null = $form.ShowDialog()
} else {
    $report | ForEach-Object { Write-Output $_ }
}

# -Save：把统计报告内容同时写入 log\report-<日期>.csv + 生成每周 log CSV（bat 调用时默认保存）
if ($Save) {
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    $savePath = Join-Path $script:LogDir ("report-{0:yyyyMMdd}.csv" -f (Get-Date))   # R38: 报告产物也进 log 文件夹
    try {
        $report | Set-Content -Path $savePath -Encoding UTF8
    } catch {
        Write-Warning "保存统计到 $savePath 失败: $($_.Exception.Message)"
    }
    # 生成 log/week-<年-W周>.csv（本周明细 + 周统计 + 本月累计）
    $weekFile = Export-WeeklyCsv
    if ($weekFile) { Write-Host "已生成每周统计: $weekFile" }
}
