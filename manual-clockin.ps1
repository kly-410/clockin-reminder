#Requires -Version 5.1
<#
  manual-clockin.ps1  —  手动打卡（周末/任意时间加班记录，v3）
  用法：
    双击运行，或命令行：
      powershell -NoProfile -ExecutionPolicy Bypass -File manual-clockin.ps1
  功能：
    - 选「记上班卡」或「记下班卡」，填时间（HH:mm，默认当前时间），点按钮写入
    - 当天该类型已有记录时弹 YesNo 确认覆盖；没有则新增一行
    - 数据写入同一个 history.csv（date,clockin_time,offwork_at,offwork_actual）
    - 周末/任意时间记录计入周/月统计的「周末加班」单列，不参与 50h 达标判断
    - 普通窗口、可关闭；不触发主脚本任何提醒（主脚本 Test-Workday 守卫不变）
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:DataDir      = Join-Path $env:USERPROFILE '.clockin-reminder'
$script:HistoryFile  = Join-Path $script:DataDir 'history.csv'
$script:SkippedLines = New-Object System.Collections.ArrayList

# ============ 历史读写（与主脚本一致：兼容 3 列/4 列）============
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
        }
    }
    return $rows
}

# 写入/覆盖当天记录：kind = 'clockin'（上班，写 HH:mm）/ 'offwork'（下班，写 yyyy-MM-dd HH:mm:00）
function Set-ManualRecord {
    param([string]$date, [string]$kind, [string]$hhmm)
    try {
        $lines = @()
        if (Test-Path $script:HistoryFile) {
            $lines = @(Get-Content -Path $script:HistoryFile -Encoding UTF8)
        }
        if ($lines.Count -eq 0) {
            $lines = @('date,clockin_time,offwork_at,offwork_actual')
        }
        $found = $false
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $cols = $lines[$i].Split(',')
            if ($cols.Count -ge 1 -and $cols[0].Trim() -eq $date) {
                $c1 = if ($cols.Count -ge 2) { $cols[1].Trim() } else { '' }
                $c2 = if ($cols.Count -ge 3) { $cols[2].Trim() } else { '' }
                $c3 = if ($cols.Count -ge 4) { $cols[3].Trim() } else { '' }
                if ($kind -eq 'clockin') { $c1 = $hhmm }
                else { $c3 = '{0} {1}:00' -f $date, $hhmm }
                $lines[$i] = "$date,$c1,$c2,$c3"
                $found = $true
            }
        }
        if (-not $found) {
            if ($kind -eq 'clockin') {
                $lines += ('{0},{1},,' -f $date, $hhmm)
            } else {
                $lines += ('{0},,,{1} {2}:00' -f $date, $date, $hhmm)
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
                    $ask = [System.Windows.Forms.MessageBox]::Show(
                        "当天已有下班卡：$($r.offwork_actual)，覆盖？",
                        '确认覆盖', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
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
