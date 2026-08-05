#Requires -Version 5.1
<#
  status.ps1  —  打卡程序运行状态查询（纯文本 / -Gui 弹窗）
  用法（Windows PowerShell 5.1+）：
    powershell -NoProfile -ExecutionPolicy Bypass -File status.ps1          # 文本模式
    powershell -NoProfile -ExecutionPolicy Bypass -File status.ps1 -Gui     # 弹窗
  说明：
    - 核心判定三项：进程（单实例 Mutex 探测）/ 心跳（state.json last_heartbeat_at ≤10 分钟）/ 数据完整性
    - 汇总：三项全绿 = ✅ 运行正常；进程不在 = 🚨 未运行；其余 = ⚠️ 部分异常
    - 数据读脚本同目录（$PSScriptRoot，就地安装 R31）；只读不写，查询脚本自己绝不崩
    - 探测 Mutex 拿到锁会立即 ReleaseMutex + Dispose，绝不让查询进程把锁占住
    - 心跳字段由主脚本（v9+ 含 Write-Heartbeat）每轮写入；旧主脚本无此字段时给出「需更新主脚本」警告
#>
param([switch]$Gui)
$ErrorActionPreference = 'Stop'

# 取 state.json 字段值；字段不存在返回 $null（兼容旧版无此字段）
function Get-StateField {
    param($state, [string]$Name)
    if ($null -eq $state) { return $null }
    $prop = $state.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# 主逻辑整体 try/catch 兜底：查询脚本自己绝不能崩
try {
    $script:DataDir     = $PSScriptRoot
    $script:ConfigFile  = Join-Path $script:DataDir 'config.json'
    $script:StateFile   = Join-Path $script:DataDir 'state.json'
    $script:LogDir      = Join-Path $script:DataDir 'log'
    $script:LogFile     = Join-Path $script:DataDir 'log.txt'

    $items = New-Object System.Collections.ArrayList   # @{ Status; Text } 逐行结果；Status: ok/warn/fail/info

    # ---------- 1) 进程状态（探测单实例 Mutex，拿到锁必须释放）----------
    $procStatus = 'warn'
    $procText   = '进程状态   : ⚠️ 无法探测'
    try {
        try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $sid = 'unknown' }
        $m = New-Object System.Threading.Mutex($false, "ClockinReminder_$sid")
        $acquired = $false
        try {
            if ($m.WaitOne(0)) {
                # 拿到锁 → 没有实例持有 → 未运行
                $acquired = $true
                $procStatus = 'fail'
                $procText   = '进程状态   : 🚨 未运行（无实例在跑）'
            } else {
                # 有人持有 → 有实例在跑
                $procStatus = 'ok'
                $procText   = '进程状态   : ✅ 运行中'
            }
        } catch [System.Threading.AbandonedMutexException] {
            # 上个实例崩溃遗留：框架已把所有权交给当前线程 → 需释放；视为无实例在跑
            $acquired = $true
            $procStatus = 'fail'
            $procText   = '进程状态   : 🚨 未运行（上次实例崩溃遗留）'
        } catch {
            $procStatus = 'warn'
            $procText   = "进程状态   : ⚠️ 无法探测（$($_.Exception.Message)）"
        } finally {
            if ($acquired) { try { $m.ReleaseMutex() } catch { } }
            if ($null -ne $m) { $m.Dispose() }
        }
    } catch {
        $procStatus = 'warn'
        $procText   = "进程状态   : ⚠️ 无法探测（$($_.Exception.Message)）"
    }
    $null = $items.Add([pscustomobject]@{ Status = $procStatus; Text = $procText })

    # ---------- 2) 心跳状态（state.json last_heartbeat_at）----------
    $stateFileExists = Test-Path $script:StateFile
    $state = $null
    if ($stateFileExists) {
        try { $state = Get-Content -Path $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
    }
    # 必须是 JSON 对象；数组/标量/空都视为解析失败（数据异常）
    $stateReadable = ($null -ne $state -and $state -is [System.Management.Automation.PSCustomObject])

    $hbStatus = 'fail'
    $hbText   = '心跳状态   : ❌ state.json 缺失，数据异常'
    if (-not $stateFileExists) {
        $hbStatus = 'fail'
        $hbText   = '心跳状态   : ❌ state.json 缺失，数据异常'
    } elseif (-not $stateReadable) {
        $hbStatus = 'fail'
        $hbText   = '心跳状态   : ❌ state.json 无法解析，数据异常'
    } else {
        $hbRaw = [string](Get-StateField $state 'last_heartbeat_at')
        if ([string]::IsNullOrWhiteSpace($hbRaw)) {
            $hbStatus = 'warn'
            $hbText   = '心跳状态   : ⚠️ 未开启（主脚本版本旧，无 last_heartbeat_at，需更新主脚本）'
        } else {
            $dt = [datetime]::MinValue
            if ([datetime]::TryParseExact($hbRaw, 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
                $ageMin = ((Get-Date) - $dt).TotalMinutes
                if ($ageMin -le 10) {
                    $hbStatus = 'ok'
                    $hbText   = ('心跳状态   : ✅ 正常（{0} 分钟前跳动）' -f [math]::Max(0, [int][math]::Round($ageMin)))
                } else {
                    $hbStatus = 'warn'
                    $hbText   = ('心跳状态   : ⚠️ 疑似卡死/挂起（{0} 分钟未跳动，超过 10 分钟）' -f [int][math]::Round($ageMin))
                }
            } else {
                $hbStatus = 'fail'
                $hbText   = "心跳状态   : ❌ last_heartbeat_at 无法解析（$hbRaw）"
            }
        }
    }
    $null = $items.Add([pscustomobject]@{ Status = $hbStatus; Text = $hbText })

    # ---------- 3) 数据完整性 ----------
    $missing = New-Object System.Collections.ArrayList
    if (-not (Test-Path $script:ConfigFile)) { $null = $missing.Add('config.json') }
    if (-not $stateFileExists)               { $null = $missing.Add('state.json') }
    if (-not (Test-Path $script:LogDir))     { $null = $missing.Add('log 目录') }
    if ($stateFileExists -and -not $stateReadable) { $null = $missing.Add('state.json 无法解析') }
    if ($missing.Count -eq 0) {
        $dataStatus = 'ok'
        $dataText   = '数据完整性 : ✅ config.json / state.json / log 目录完好'
    } else {
        $dataStatus = 'fail'
        $dataText   = '数据完整性 : ❌ ' + ($missing -join '、')
    }
    $null = $items.Add([pscustomobject]@{ Status = $dataStatus; Text = $dataText })

    # ---------- 4) 今日打卡摘要（增值展示，不做核心判定）----------
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $todayText = '今日打卡   : 今天还没有打卡记录'
    if ($stateReadable -and [string](Get-StateField $state 'date') -eq $today) {
        $parts = New-Object System.Collections.ArrayList
        $ck = [string](Get-StateField $state 'clockin_time')
        if (-not [string]::IsNullOrWhiteSpace($ck))  { $null = $parts.Add("上班 $ck") }
        $off = [string](Get-StateField $state 'offwork_at')
        if (-not [string]::IsNullOrWhiteSpace($off))  { $null = $parts.Add("预计下班 $off") }
        $next = [string](Get-StateField $state 'next_remind_at')
        if (-not [string]::IsNullOrWhiteSpace($next)) { $null = $parts.Add("下次提醒 $next") }
        if ($parts.Count -gt 0) {
            $todayText = '今日打卡   : ' + ($parts -join ' / ')
        }
    }
    $null = $items.Add([pscustomobject]@{ Status = 'info'; Text = $todayText })

    # ---------- 5) 异常日志尾部（log.txt 最近 5 行）----------
    if (Test-Path $script:LogFile) {
        try {
            $logLines = @(Get-Content -Path $script:LogFile -Encoding UTF8 -ErrorAction Stop)
            $tail = @($logLines | Select-Object -Last 5)
            if ($tail.Count -eq 0) {
                $null = $items.Add([pscustomobject]@{ Status = 'info'; Text = '异常日志   : 无异常日志（正常）' })
            } else {
                $null = $items.Add([pscustomobject]@{ Status = 'info'; Text = '异常日志   : 最近 5 条：' })
                foreach ($ln in $tail) { $null = $items.Add([pscustomobject]@{ Status = 'info'; Text = "    $ln" }) }
            }
        } catch {
            $null = $items.Add([pscustomobject]@{ Status = 'warn'; Text = "异常日志   : ⚠️ log.txt 读取失败（$($_.Exception.Message)）" })
        }
    } else {
        $null = $items.Add([pscustomobject]@{ Status = 'info'; Text = '异常日志   : 无异常日志（正常）' })
    }

    # ---------- 汇总判定 ----------
    if ($procStatus -eq 'fail') {
        $verdict     = '🚨 未运行'
        $verdictSt   = 'fail'
    } elseif ($procStatus -eq 'ok' -and $hbStatus -eq 'ok' -and $dataStatus -eq 'ok') {
        $verdict     = '✅ 运行正常'
        $verdictSt   = 'ok'
    } else {
        $verdict     = '⚠️ 部分异常'
        $verdictSt   = 'warn'
    }

    # ---------- 输出 ----------
    $verdictColor = @{ ok = 'Green'; warn = 'Yellow'; fail = 'Red' }
    $itemColor    = @{ ok = 'Green'; warn = 'Yellow'; fail = 'Red'; info = 'Gray' }

    if ($Gui) {
        # -Gui 模式：复刻 report.ps1 深色窗口；内容与文本模式同款（带状态标记符号；纯文本不带色，简化优先）
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $text = New-Object System.Collections.ArrayList
        $null = $text.Add($verdict)
        foreach ($it in $items) { $null = $text.Add($it.Text) }
        $form = New-Object System.Windows.Forms.Form
        $form.Text = '打卡程序运行状态'
        $form.Size = New-Object System.Drawing.Size(820, 640)
        $form.StartPosition = 'CenterScreen'
        $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Multiline = $true
        $txt.ReadOnly  = $true
        $txt.ScrollBars = 'Vertical'
        $txt.Font = New-Object System.Drawing.Font('Consolas', 11)
        $txt.Dock = 'Fill'
        $txt.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $txt.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
        $txt.BorderStyle = 'None'
        $txt.Text = $text -join "`r`n"
        $form.Controls.Add($txt)
        $null = $form.ShowDialog()
    } else {
        Write-Host $verdict -ForegroundColor $verdictColor[$verdictSt]
        foreach ($it in $items) {
            Write-Host $it.Text -ForegroundColor $itemColor[$it.Status]
        }
    }
} catch {
    Write-Host "❌ 状态查询失败: $($_.Exception.Message)" -ForegroundColor Red
}
