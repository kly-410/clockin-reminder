#Requires -Version 5.1
<#
  manual-clockin.ps1  —  手动打卡（周末/任意时间加班记录，v5）
  用法：
    双击运行，或命令行：
      powershell -NoProfile -ExecutionPolicy Bypass -File manual-clockin.ps1
  功能：
    - 选「记上班卡」或「记下班卡」，填时间（HH:mm，默认当前时间），点按钮写入
    - 记下班卡取最晚（R16）：当天已有下班记录时，新时间更晚才确认更新；更早则提示跳过
    - 当天该类型已有记录时弹 YesNo 确认覆盖；没有则新增一行
    - 数据写入同一个 history.csv（date,clockin_time,offwork_at,offwork_actual,duration）
    - 周末/任意时间记录计入周/月统计的「周末加班」单列，不参与 50h 达标判断
    - 普通窗口、可关闭；不触发主脚本任何提醒（主脚本 Test-Workday 守卫不变）
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:DataDir      = Join-Path $env:USERPROFILE '.clockin-reminder'
$script:HistoryFile  = Join-Path $script:DataDir 'history.csv'
$script:SkippedLines = New-Object System.Collections.ArrayList

# ============ 历史读写（与主脚本一致：兼容 3 列/4 列/5 列）============
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

# v5: offwork 时间 CSV 里只存 HH:mm；与 start 组合做跨天推断（end < start → +1 天）；旧格式完整 datetime 仍兼容
function Get-RecordEnd {
    param($row, $start)
    $s = $row.offwork_actual
    if ([string]::IsNullOrWhiteSpace($s)) { $s = $row.offwork_at }
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $t = [datetime]::MinValue
    if ([datetime]::TryParseExact($s, [string[]]@('HH:mm', 'H:mm'), $null, [System.Globalization.DateTimeStyles]::None, [ref]$t)) {
        if ($null -eq $start) { return $null }
        $end = $start.Date.Add($t.TimeOfDay)
        if ($end -lt $start) { $end = $end.AddDays(1) }   # C1: end < start → 视为次日
        return $end
    }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParseExact($s, 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
    if ([datetime]::TryParseExact($s, 'yyyy-MM-dd HH:mm', $null, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
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

# 写入/覆盖当天记录：kind = 'clockin'（上班，写 HH:mm）/ 'offwork'（下班，写 HH:mm）
# v5: 5 列，offwork 时间只存 HH:mm；写入时重算该行 duration 列（优先 actual，空则回退 at）
function Set-ManualRecord {
    param([string]$date, [string]$kind, [string]$hhmm)
    try {
        $lines = @()
        if (Test-Path $script:HistoryFile) {
            $lines = @(Get-Content -Path $script:HistoryFile -Encoding UTF8)
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
                if ($kind -eq 'clockin') { $c1 = $hhmm }
                else { $c3 = $hhmm }
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
                $lines += ('{0},{1},,,' -f $date, $hhmm)   # 缺下班信息，duration 空
            } else {
                $lines += ('{0},,,{1},' -f $date, $hhmm)   # 缺上班卡，duration 空
            }
        }
        # 原子写
        $tmp = "$($script:HistoryFile).tmp"
        $lines | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $script:HistoryFile -Force
        return $true
    } catch {
        try { [System.Windows.Forms.MessageBox]::Show("写入失败：$($_.Exception.Message)", '错误', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null } catch { }
        return $false
    }
}

# ============ 手动打卡弹窗（普通窗口，可关闭）============
function Show-ManualDialog {
    $w = 560
    $h = 500
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
    $title.Text = '手动打卡（加班记录）'
    $title.Font = New-Object System.Drawing.Font('Microsoft YaHei', 22, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(255, 220, 80)
    $title.BackColor = $form.BackColor
    $title.TextAlign = 'MiddleCenter'
    $title.SetBounds(0, 24, $w, 56)
    $form.Controls.Add($title)

    $rbClockin = New-Object System.Windows.Forms.RadioButton
    $rbClockin.Text = '记上班卡'
    $rbClockin.Font = New-Object System.Drawing.Font('Microsoft YaHei', 18)
    $rbClockin.ForeColor = [System.Drawing.Color]::White
    $rbClockin.BackColor = $form.BackColor
    $rbClockin.Checked = $true
    $rbClockin.SetBounds(($cx - 210), 120, 190, 56)
    $form.Controls.Add($rbClockin)

    $rbOffwork = New-Object System.Windows.Forms.RadioButton
    $rbOffwork.Text = '记下班卡'
    $rbOffwork.Font = New-Object System.Drawing.Font('Microsoft YaHei', 18)
    $rbOffwork.ForeColor = [System.Drawing.Color]::White
    $rbOffwork.BackColor = $form.BackColor
    $rbOffwork.SetBounds(($cx + 20), 120, 190, 56)
    $form.Controls.Add($rbOffwork)

    $timeLabel = New-Object System.Windows.Forms.Label
    $timeLabel.Text = '打卡时间（HH:mm）'
    $timeLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 14)
    $timeLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 200, 220)
    $timeLabel.BackColor = $form.BackColor
    $timeLabel.TextAlign = 'MiddleCenter'
    $timeLabel.SetBounds(0, 190, $w, 40)
    $form.Controls.Add($timeLabel)

    $timeBox = New-Object System.Windows.Forms.TextBox
    $timeBox.Text = (Get-Date).ToString('HH:mm')
    $timeBox.Font = New-Object System.Drawing.Font('Microsoft YaHei', 22)
    $timeBox.ForeColor = [System.Drawing.Color]::Black
    $timeBox.TextAlign = 'Center'
    $timeBox.SetBounds(($cx - 130), 240, 260, 52)
    $form.Controls.Add($timeBox)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '周末加班会单独统计，不计入 50h 达标'
    $hint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11)
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(140, 160, 180)
    $hint.BackColor = $form.BackColor
    $hint.TextAlign = 'MiddleCenter'
    $hint.SetBounds(0, 300, $w, 32)
    $form.Controls.Add($hint)

    $form.Tag = @{ RbClockin = $rbClockin; RbOffwork = $rbOffwork; TimeBox = $timeBox; Result = $null }

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = '写入记录'
    $btn.Font = New-Object System.Drawing.Font('Microsoft YaHei', 18, [System.Drawing.FontStyle]::Bold)
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.BackColor = [System.Drawing.Color]::FromArgb(200, 60, 40)
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.SetBounds(($cx - 130), 360, 260, 70)
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
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $hhmm = $t.ToString('HH:mm')

        # 当天该类型已有记录 -> YesNo 覆盖确认；No 则不动
        $rows = @(Read-HistoryRows)
        $existing = @($rows | Where-Object { $_.date -eq $today })
        if ($existing.Count -gt 0) {
            $r = $existing[0]
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
                    # v5: offwork_actual 为 HH:mm，用跨天推断还原完整 end 再比较（00:30 次日 > 23:50 当天）
                    $exStart = Get-RecordStart $r
                    $exEnd = Get-RecordEnd -row $r -start $exStart
                    $newDt = [datetime]::Today.Add($t.TimeOfDay)
                    if ($null -ne $exEnd -and $newDt -le $exEnd) {
                        [System.Windows.Forms.MessageBox]::Show(
                            "已存在更晚的下班记录 $($r.offwork_actual)，不更新",
                            '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                        return
                    }
                    $ask = [System.Windows.Forms.MessageBox]::Show(
                        "已存在下班记录 $($r.offwork_actual)，新时间 $hhmm 更晚，更新为 $hhmm？",
                        '确认更新', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                    if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                }
            }
        }
        if (Set-ManualRecord -date $today -kind $kind -hhmm $hhmm) {
            $kindName = if ($kind -eq 'clockin') { '上班' } else { '下班' }
            [System.Windows.Forms.MessageBox]::Show("已记录：$today $kindName卡 $hhmm", '成功') | Out-Null
            $tag.Result = $true
            $f.Close()
        }
    })
    $form.Controls.Add($btn)
    $form.AcceptButton = $btn   # Enter 键写入

    $null = $form.ShowDialog()
    return $form.Tag.Result
}

Show-ManualDialog
