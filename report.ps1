#Requires -Version 5.1
<#
  report.ps1  —  打卡时长统计报告（纯文本，不弹窗，v8）
  用法（Windows PowerShell 5.1+）：
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1            # 本周（默认）
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Week
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Month
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -All
    powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Days 7
  说明：
    - 数据来自 %USERPROFILE%\.clockin-reminder\history.csv
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
    [switch]$Save
)
$ErrorActionPreference = 'Stop'

$script:DataDir      = Join-Path $env:USERPROFILE '.clockin-reminder'
$script:HistoryFile  = Join-Path $script:DataDir 'history.csv'
$script:SkippedLines = New-Object System.Collections.ArrayList

# ============ 历史读取与解析（与主脚本一致）============
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
    $threshold = 3000.0   # 50h * 60
    if ($weekdayMin -ge $threshold) {
        Write-Output ("  工作日合计   {0}  ✅ 达标 (≥50h)" -f (Format-Duration $weekdayMin))
    } else {
        Write-Output ("  工作日合计   {0}  ⚠️ 还差 {1} (需≥50h)" -f (Format-Duration $weekdayMin), (Format-Duration ($threshold - $weekdayMin)))
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

# ============ 入口 ============
$report = New-Object System.Collections.ArrayList
if (-not (Test-Path $script:HistoryFile)) {
    $null = $report.Add('history.csv 不存在，暂无记录。')
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
    $form.Text = '打卡统计报告'
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

# -Save：把统计报告内容同时写入 report-<日期>.csv（bat 调用时默认保存）
if ($Save) {
    $savePath = Join-Path $script:DataDir ("report-{0:yyyyMMdd}.csv" -f (Get-Date))
    try {
        $report | Set-Content -Path $savePath -Encoding UTF8
    } catch {
        Write-Warning "保存统计到 $savePath 失败: $($_.Exception.Message)"
    }
}
