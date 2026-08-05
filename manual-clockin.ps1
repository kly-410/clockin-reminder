#Requires -Version 5.1
<#
  manual-clockin.ps1  —  手动打卡 / 补录指定日期（周末加班记录 + 历史补录，v9）
  用法：
    双击运行，或命令行：
      powershell -NoProfile -ExecutionPolicy Bypass -File manual-clockin.ps1
  功能：
    - 选日期（默认今天，可改过去任意一天做补录）、选「记上班卡」或「记下班卡」，填时间（HH:mm），点按钮写入
    - 记下班卡取最晚（R16）：当天已有下班记录时，新时间更晚才确认更新；更早则提示跳过
    - 当天该类型已有记录时弹 YesNo 确认覆盖；没有则新增一行
    - 数据写入 log 周文件（log\<周一日期>.csv；日期,上班时间,预计下班,实际下班,工作时长；v8 起下班时间存完整 datetime，跨天加班到次日日期 +1）
    - 周末/任意时间记录计入周/月统计的「周末加班」单列，不参与 50h 达标判断
    - 普通窗口、可关闭；不触发主脚本任何提醒（主脚本 Test-Workday 守卫不变）
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:DataDir      = $PSScriptRoot
$script:HistoryFile  = Join-Path $script:DataDir 'history.csv'   # R28: 旧版单一文件，仅迁移兼容读取
$script:LogDir       = Join-Path $script:DataDir 'log'           # R28: 历史记录按周归档 log\<周一日期>.csv
$script:SkippedLines = New-Object System.Collections.ArrayList

# ============ 历史读写（与主脚本一致：兼容 3 列/4 列/5 列；R28 合并读 log 周文件）============
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

# R28: 合并读取全部历史——log\*.csv 周文件（文件名=周一日期，按日期排序）+ 根目录旧 history.csv（迁移兼容）
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

# R28: 所在周的周一/周日（周一到周日）
function Get-WeekRange {
    param([datetime]$d)
    $daysSinceMonday = ([int]$d.DayOfWeek + 6) % 7
    $monday = $d.Date.AddDays(-$daysSinceMonday)
    return @{ Monday = $monday; Sunday = $monday.AddDays(6) }
}

# R28: 周文件路径 = date 所在周的周一日期 → log\<周一日期>.csv
function Get-WeekFile {
    param([string]$dateStr)
    $d = ConvertTo-StatsDate $dateStr
    if ($null -eq $d) { $d = (Get-Date).Date }
    $range = Get-WeekRange $d
    return Join-Path $script:LogDir ($range.Monday.ToString('yyyy-MM-dd') + '.csv')
}

# ============ 时长计算（与主脚本一致：跨天推断 C1）============
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

# v8: 显示用——完整 datetime 或 HH:mm 都取 HH:mm 部分（弹窗文案保持简洁）
function ConvertTo-HHmm {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $t = [datetime]::MinValue
    if ([datetime]::TryParseExact($s, [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm', 'HH:mm', 'H:mm'), $null,
            [System.Globalization.DateTimeStyles]::None, [ref]$t)) {
        return $t.ToString('HH:mm')
    }
    return $s
}

# v8: 下班卡组合完整 datetime = 所选日期 + HH:mm；填的时间早于上班时间（跨天加班到次日）→ 日期 +1 天
function New-OffworkDateTime {
    param([string]$date, [string]$hhmm, [string]$clockinHHmm = '')
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($date, 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { $d = (Get-Date).Date }
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($hhmm, [string[]]@('HH:mm', 'H:mm'), $null, [System.Globalization.DateTimeStyles]::None, [ref]$t)) { return "$date $hhmm:00" }
    $result = $d.Date.Add($t.TimeOfDay)
    if (-not [string]::IsNullOrWhiteSpace($clockinHHmm)) {
        $ck = [datetime]::MinValue
        if ([datetime]::TryParseExact($clockinHHmm, [string[]]@('HH:mm', 'H:mm'), $null, [System.Globalization.DateTimeStyles]::None, [ref]$ck) -and
            $t.TimeOfDay -lt $ck.TimeOfDay) {
            $result = $result.AddDays(1)
        }
    }
    return $result.ToString('yyyy-MM-dd HH:mm:ss')
}

# 写入/覆盖当天记录：kind = 'clockin'（上班，写 HH:mm）/ 'offwork'（下班，写完整 datetime，可能次日）
# v8: 5 列，offwork 时间存完整 datetime；写入时重算该行 duration 列（优先 actual，空则回退 at）
# R28: 写入 date 所在周文件（log\<周一日期>.csv）；文件不存在自动建（含中文表头）
function Set-ManualRecord {
    param([string]$date, [string]$kind, [string]$timeValue)
    try {
        $weekFile = Get-WeekFile $date
        $dir = Split-Path $weekFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $lines = @()
        if (Test-Path $weekFile) {
            $lines = @(Get-Content -Path $weekFile -Encoding UTF8)
        }
        if ($lines.Count -eq 0) {
            $lines = @('日期,上班时间,预计下班,实际下班,工作时长')
        }
        $found = $false
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $cols = $lines[$i].Split(',')
            if ($cols.Count -ge 1 -and $cols[0].Trim() -eq $date) {
                $c1 = if ($cols.Count -ge 2) { $cols[1].Trim() } else { '' }
                $c2 = if ($cols.Count -ge 3) { $cols[2].Trim() } else { '' }
                $c3 = if ($cols.Count -ge 4) { $cols[3].Trim() } else { '' }
                if ($kind -eq 'clockin') { $c1 = $timeValue }
                else { $c3 = $timeValue }
                # 重算 duration
                $durStr = ''
                $row = [pscustomobject]@{ date = $date; clockin = $c1; offwork_at = $c2; offwork_actual = $c3 }
                $min = Get-RecordMinutes $row
                if ($null -ne $min) { $durStr = Format-Duration $min }
                $lines[$i] = "$date,$c1,$c2,$c3,$durStr"
                $found = $true
            }
        }
        if (-not $found) {
            if ($kind -eq 'clockin') {
                $lines += ('{0},{1},,,' -f $date, $timeValue)   # 缺下班信息，duration 空
            } else {
                $lines += ('{0},,,{1},' -f $date, $timeValue)   # 缺上班卡，duration 空
            }
        }
        # 原子写
        $tmp = "$weekFile.tmp"
        $lines | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $weekFile -Force
        return $true
    } catch {
        try { [System.Windows.Forms.MessageBox]::Show("写入失败：$($_.Exception.Message)", '错误', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null } catch { }
        return $false
    }
}

# ============ 手动打卡弹窗（普通窗口，可关闭）============
function Show-ManualDialog {
    $w = 560
    $h = 470
    $cx = [int]($w / 2)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '手动打卡'
    $form.Size = New-Object System.Drawing.Size($w, $h)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 32, 48)
    $form.TopMost = $true
    $form.KeyPreview = $true

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '手动打卡 / 补录'
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei', 22, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(255, 220, 80)
    $title.BackColor = $form.BackColor
    $title.TextAlign = 'MiddleCenter'
    $title.SetBounds(0, 14, $w, 48)
    $form.Controls.Add($title)

    $rbClockin = New-Object System.Windows.Forms.RadioButton
    $rbClockin.Text = '记上班卡'
    $rbClockin.Font = New-Object System.Drawing.Font('Microsoft YaHei', 18)
    $rbClockin.ForeColor = [System.Drawing.Color]::White
    $rbClockin.BackColor = $form.BackColor
    $rbClockin.Checked = $true
    $rbClockin.SetBounds(($cx - 210), 84, 190, 50)
    $form.Controls.Add($rbClockin)

    $rbOffwork = New-Object System.Windows.Forms.RadioButton
    $rbOffwork.Text = '记下班卡'
    $rbOffwork.Font = New-Object System.Drawing.Font('Microsoft YaHei', 18)
    $rbOffwork.ForeColor = [System.Drawing.Color]::White
    $rbOffwork.BackColor = $form.BackColor
    $rbOffwork.SetBounds(($cx + 20), 84, 190, 50)
    $form.Controls.Add($rbOffwork)

    $dateLabel = New-Object System.Windows.Forms.Label
    $dateLabel.Text = '日期（默认今天，可补录过去）'
    $dateLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 14)
    $dateLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 200, 220)
    $dateLabel.BackColor = $form.BackColor
    $dateLabel.TextAlign = 'MiddleCenter'
    $dateLabel.SetBounds(0, 146, $w, 28)
    $form.Controls.Add($dateLabel)

    $datePicker = New-Object System.Windows.Forms.DateTimePicker
    $datePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
    $datePicker.Font = New-Object System.Drawing.Font('Microsoft YaHei', 16)
    $datePicker.SetBounds(($cx - 110), 178, 220, 40)
    $form.Controls.Add($datePicker)

    $timeLabel = New-Object System.Windows.Forms.Label
    $timeLabel.Text = '打卡时间（HH:mm）'
    $timeLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 14)
    $timeLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 200, 220)
    $timeLabel.BackColor = $form.BackColor
    $timeLabel.TextAlign = 'MiddleCenter'
    $timeLabel.SetBounds(0, 226, $w, 28)
    $form.Controls.Add($timeLabel)

    $timeBox = New-Object System.Windows.Forms.TextBox
    $timeBox.Text = (Get-Date).ToString('HH:mm')
    $timeBox.Font = New-Object System.Drawing.Font('Microsoft YaHei', 22)
    $timeBox.ForeColor = [System.Drawing.Color]::Black
    $timeBox.TextAlign = 'Center'
    $timeBox.SetBounds(($cx - 130), 258, 260, 50)
    $form.Controls.Add($timeBox)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "写入成功不关闭，可连续补录/修改多天；点「退出」或右上角 X 关闭`n补录过去日期写入对应周文件；周末加班单列不计 50h 达标"
    $hint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11)
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(140, 160, 180)
    $hint.BackColor = $form.BackColor
    $hint.TextAlign = 'MiddleCenter'
    $hint.SetBounds(0, 316, $w, 46)
    $form.Controls.Add($hint)

    $form.Tag = @{ RbClockin = $rbClockin; RbOffwork = $rbOffwork; DatePicker = $datePicker; TimeBox = $timeBox; Result = $null }

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = '写入记录'
    $btn.Font = New-Object System.Drawing.Font('Microsoft YaHei', 18, [System.Drawing.FontStyle]::Bold)
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.BackColor = [System.Drawing.Color]::FromArgb(200, 60, 40)
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.SetBounds(($cx - 230), 372, 210, 56)
    $btn.Add_Click({
        param($sender, $e)
        $f = $sender.FindForm()
        $tag = $f.Tag
        $kind = if ($tag.RbClockin.Checked) { 'clockin' } else { 'offwork' }
        $text = $tag.TimeBox.Text.Trim()
        $t = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($text, [string[]]@('HH:mm', 'H:mm'), $null,
                [System.Globalization.DateTimeStyles]::None, [ref]$t)) {
            [System.Windows.Forms.MessageBox]::Show('时间格式不对，请填 HH:mm 或 H:mm，例如 08:30 或 8:30', '输入错误') | Out-Null
            return
        }
        $today = $tag.DatePicker.Value.ToString('yyyy-MM-dd')
        $hhmm = $t.ToString('HH:mm')

        # 当天该类型已有记录 -> YesNo 覆盖确认；No 则不动
        $rows = @(Read-HistoryRows)
        $existing = @($rows | Where-Object { $_.date -eq $today })
        $r = if ($existing.Count -gt 0) { $existing[0] } else { $null }

        # v8: 组合写入值——上班卡存 HH:mm；下班卡存完整 datetime（跨天加班到次日 → 日期 +1 天）
        $value = $hhmm
        if ($kind -eq 'offwork') {
            $ckHHmm = if ($null -ne $r -and -not [string]::IsNullOrWhiteSpace($r.clockin)) { $r.clockin } else { '' }
            $value = New-OffworkDateTime -date $today -hhmm $hhmm -clockinHHmm $ckHHmm
        }

        if ($null -ne $r) {
            if ($kind -eq 'clockin') {
                if (-not [string]::IsNullOrWhiteSpace($r.clockin)) {
                    $ask = [System.Windows.Forms.MessageBox]::Show(
                        "当天已有上班卡：$($r.clockin)，覆盖为 $hhmm？",
                        '确认覆盖', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                    if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                }
            } else {
                if (-not [string]::IsNullOrWhiteSpace($r.offwork_actual)) {
                    # R16: 同一天多次下班打卡取最晚——新时间更晚才确认更新；更早则提示并跳过
                    # v8: 新时间完整 datetime 直接与已有 end 比较；旧 HH:mm 行经跨天推断还原（00:30 次日 > 23:50 当天）
                    $exStart = Get-RecordStart $r
                    $exEnd = Get-RecordEnd -row $r -start $exStart
                    $newDt = [datetime]::MinValue
                    if (-not [datetime]::TryParseExact($value, 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$newDt)) {
                        $newDt = [datetime]::Today.Add($t.TimeOfDay)
                    }
                    if ($null -ne $exEnd -and $newDt -le $exEnd) {
                        [System.Windows.Forms.MessageBox]::Show(
                            "已存在更晚的下班记录 $(ConvertTo-HHmm $r.offwork_actual)，不更新",
                            '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                        return
                    }
                    $ask = [System.Windows.Forms.MessageBox]::Show(
                        "已存在下班记录 $(ConvertTo-HHmm $r.offwork_actual)，新时间 $(ConvertTo-HHmm $value) 更晚，更新为 $(ConvertTo-HHmm $value)？",
                        '确认更新', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                    if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                }
            }
        }
        if (Set-ManualRecord -date $today -kind $kind -timeValue $value) {
            $kindName = if ($kind -eq 'clockin') { '上班' } else { '下班' }
            # v10: 写入成功后不关闭窗口——支持连续补录/修改多天；点「退出」按钮或右上角 X 关闭
            [System.Windows.Forms.MessageBox]::Show("已记录：$today $kindName卡 $hhmm`n可继续补录/修改其他日期，点「退出」或右上角 X 关闭", '成功') | Out-Null
            $tag.Result = $true
        }
    })
    $form.Controls.Add($btn)

    $btnExit = New-Object System.Windows.Forms.Button
    $btnExit.Text = '退出'
    $btnExit.Font = New-Object System.Drawing.Font('Microsoft YaHei', 16, [System.Drawing.FontStyle]::Bold)
    $btnExit.ForeColor = [System.Drawing.Color]::White
    $btnExit.BackColor = [System.Drawing.Color]::FromArgb(90, 100, 120)
    $btnExit.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnExit.SetBounds(($cx + 20), 372, 210, 56)
    $btnExit.Add_Click({
        param($sender, $e)
        $sender.FindForm().Close()
    })
    $form.Controls.Add($btnExit)
    $form.CancelButton = $btnExit   # Esc 键关闭
    $form.AcceptButton = $btn   # Enter 键写入

    $null = $form.ShowDialog()
    return $form.Tag.Result
}

Show-ManualDialog
