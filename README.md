# Windows 打卡提醒小工具

常驻后台的 PowerShell 脚本：**工作日 8 点提醒上班打卡（黄底红字、占屏 90%、必须点确认才关），填实际打卡时间后满 10 小时提醒下班打卡。周六/周日自动跳过，不提醒、不写记录。** 下班提醒支持加班循环：确认一次后按间隔（默认 30 分钟）再次提醒，直到不再确认或超过当天最晚提醒时间（默认 23 点）；同一天多次确认下班取**最晚**一次。下班确认后写入实际下班时间，可统计每日/每周/每月工作时长与 50h 达标情况；周末加班可用手动打卡单独记录。

## 文件

| 文件 | 说明 |
|:---|:---|
| `clockin-reminder.ps1` | 常驻主脚本（解锁检测 + 强制确认弹窗 + 统计，单文件） |
| `manual-clockin.ps1` | 手动打卡（周末/任意时间加班记录，普通窗口可关闭） |
| `report.ps1` | 时长统计报告（命令行纯文本输出；`-Gui` 弹窗显示） |
| `report-gui.bat` | **双击查看统计报告**（GUI 窗口，任意时间想看就看） |
| `install.ps1` | 一键安装：拷脚本 + 注册开机自启 + 立即启动 |

## 部署（在 Windows 上）

1. 把整个文件夹拷到 Windows（任意位置，如 `D:\tools\clockin-reminder`）
2. 打开 PowerShell，执行：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File D:\tools\clockin-reminder\install.ps1
   ```
3. 完成。开机自启已注册（HKCU Run，无需管理员）。

## 行为（v4）

- **周末跳过**：周六/周日不弹任何提醒、不写历史记录
- **8 点前**：脚本不轮询，睡到 8:00；8:00-12:00 之间主循环每 15 秒兜底检查，到点弹上班提醒（即使当天没解锁、没开机动作）
- **12 点后启动**：当天不自动弹上班提醒（防止深夜重装/重启误弹）
- **上班弹窗**：占屏 90%、刺眼黄底、红字，带输入框填实际打卡时间（8:00-10:00，超范围弹确认框，可 Yes 记录；Enter 键提交），必须点「确认已打卡」才关；Esc / Alt+F4 / 关闭按钮全部拦截
- **下班提醒（首次）** = 实际打卡时间 + 10 小时，主循环每 15 秒检查，到点弹同样式弹窗，必须点「确认已下班」才关；周五漏确认的提醒，下次工作日开机补弹
- **下班循环提醒（加班）**：确认一次下班后，按 `ReRemindIntervalMinutes`（默认 30 分钟）安排下次提醒，到点再弹，Message 显示「已满 X 小时（加班 Y 小时），再次确认下班打卡」；重复直到用户不再确认（弹窗一直挂着）或当前时间 ≥ `MaxRemindHour`（默认 23 点，23 点后不再自动提醒）。循环提醒只限当天，跨天残留自动停止；周末不自动循环，周末加班用手动打卡记
- **下班确认写库（取最晚）**：点「确认已下班」时，把实际确认时间写入 history.csv 的 `offwork_actual` 列；同一天多次确认只保留**最晚**一次（更早的确认跳过并写日志）；跨天（加班到次日）按完整时间相减，统计更准
- **弹窗附带统计**：上班/下班弹窗 Message 里都附加统计——上班弹窗显示「本周工作日累计 + 50h 达标进度 + 本月累计」；下班弹窗显示「今日时长 + 本周工作日累计 + 50h 达标状态」。仅附加信息，确认动作不变
- **统计口径**：每日时长 = `offwork_actual`（为空回退预计 `offwork_at`）− 上班打卡；周 = 周一~周日，工作日合计（周一~五）用于 50h 达标判断，周末加班单列；月 = 自然月全部记录
- **弹窗不阻塞主循环**：弹窗在独立 runspace 线程运行，锁屏/人不在时挂起的弹窗不影响下班检查
- 单实例互斥（双开自动退出）；state.json 原子写、解析失败跳过不崩脚本；主循环异常自动恢复（30 秒重试）

## 手动打卡（加班记录，manual-clockin.ps1）

周末或任意时间加班：双击 `manual-clockin.ps1`（或命令行 `powershell -NoProfile -ExecutionPolicy Bypass -File manual-clockin.ps1`）。

- 弹窗选「记上班卡」或「记下班卡」，填时间（`HH:mm` / `H:mm`，默认当前时间），点「写入记录」
- 记下班卡取**最晚**：当天已有下班记录时，新时间更晚 → 弹「已存在下班记录 X，新时间 Y 更晚，更新为 Y？」（Yes 更新，No 不动）；新时间更早 → 提示「已存在更晚的下班记录 X，不更新」并跳过；没有则新增一行
- 普通窗口、可关闭，不触发主脚本任何提醒；周末记录计入周/月统计的「周末加班」单列，不参与 50h 达标
- 数据写入同一个 `history.csv`

## 统计报告（report.ps1 / report-gui.bat）

**任意时间想看打卡统计**，两种途径：

- **双击 `report-gui.bat`** → 弹暗色只读窗口显示本周统计（最方便）
- 命令行运行（纯文本输出到控制台）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1            # 本周（默认）
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Week
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Month
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -All
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Days 7
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Gui       # 弹窗模式（同 bat）
```

示例输出：

```
本周 (2026-08-03 ~ 2026-08-09)
  周一 08-03  09:12 -> 19:12  10h 00m
  周二 08-04  09:00 -> 19:30  10h 30m
  ...
  工作日合计   50h 00m  ✅ 达标 (≥50h)
  周末加班     0h 00m
  本周总计     50h 00m
本月 (2026-08) 工作日 50h 00m / 加班 0h 00m / 合计 50h 00m
```

- 无记录日期显示 `-`；只有上班卡没下班卡显示 `缺下班卡`
- 解析失败/旧格式行跳过，末尾提示行号

## 数据文件（history.csv 格式）

`history.csv` 位于 `%USERPROFILE%\.clockin-reminder\`，表头 v3 为 4 列：

```
date,clockin_time,offwork_at,offwork_actual
2026-08-03,09:12,2026-08-03 19:12,
2026-08-03,09:12,2026-08-03 19:12,2026-08-03 19:05:30
```

- `date` 上班日期；`clockin_time` 上班打卡（`HH:mm`）
- `offwork_at` **预计**下班时间（= 上班 + 10h，兼容旧数据）；`offwork_actual` **实际**确认下班时间
- `offwork_actual` 同一天多次确认取**最晚**一次（主脚本自动循环确认 / 手动打卡都遵守）
- 统计时优先 `offwork_actual`，为空回退 `offwork_at`（预计值，精度略差）
- 旧 3 列文件不强制迁移，读取按列数容错

`state.json` 新增字段 `next_remind_at`（下次下班循环提醒时间，`yyyy-MM-dd HH:mm:ss`）；旧 state 没有该字段时自动回退 `offwork_at` 首次提醒，无需迁移。

## 验证

1. 按 `Win+L` 锁屏再解锁（工作日 8-12 点）→ 应弹出上班提醒
2. 查看记录：
   ```powershell
   Get-Content "$env:USERPROFILE\.clockin-reminder\state.json"
   Get-Content "$env:USERPROFILE\.clockin-reminder\history.csv"
   Get-Content "$env:USERPROFILE\.clockin-reminder\log.txt"   # 异常日志
   ```
3. 快速验证：把主脚本里 `$script:WorkWindowStart = 8` 改成 `0`、`$script:OffWorkHours = 10` 改成 `0.05`（3 分钟），
   重跑 `install.ps1` → 立即弹上班提醒，填时间后 3 分钟弹下班提醒。验完改回。

## 常见问题

- **弹窗没出现**：确认任务管理器里有 `powershell.exe`（无窗口）在跑；没有就跑一次 `install.ps1`；再看 `log.txt`
- **开机自启失效**：检查 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run` 里 `ClockinReminder` 项
- **改时长/窗口**：编辑主脚本顶部配置区（`$script:OffWorkHours` / `$script:WorkWindowStart` / `$script:WorkAutoPopupEnd` / `$script:SkipWeekend` / `$script:ReRemindIntervalMinutes` 下班循环间隔分钟 / `$script:MaxRemindHour` 最晚自动提醒小时），然后重跑 `install.ps1`

## 卸载

```powershell
# 1. 停掉常驻进程
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" |
    Where-Object { $_.CommandLine -like '*clockin-reminder.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 2. 删开机自启项
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ClockinReminder'

# 3. 删数据目录
Remove-Item "$env:USERPROFILE\.clockin-reminder" -Recurse -Force
```

## 说明

- 只做**提醒弹窗**，不自动打卡（飞书打卡需企业 API，不在此工具范围）
- 依赖 Windows 自带 PowerShell 5.1+，零第三方依赖；低资源占用（15 秒轻量轮询 + WTS API 会话状态查询）
