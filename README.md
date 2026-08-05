# Windows 打卡提醒小工具

常驻后台的 PowerShell 脚本：**工作日 8 点提醒上班打卡（黄底红字、占屏 90%、必须点确认才关），填实际打卡时间后满 10 小时提醒下班打卡。周六/周日不弹提醒，但没去也会自动补记 0 时长。** 解锁/开机启动时上班提醒放宽到 8:00-23:00（下午到也能打卡）；晚上 20 点后若当天没有记录，自动补记全天缺勤 0 时长，统计里不再空白。下班弹窗两个按钮：**确定下班**（填当前时间，记录并结束提醒）或**稍后打卡**（填当前时间，弹窗先关，按间隔默认 30 分钟再次提醒，直到确定下班或超过当天最晚提醒时间默认 23 点）；下班/预计下班时间带完整日期记录，**跨天加班到次日凌晨（下班卡超 24 点）也正常算**；历史记录按周归档到 `log\\<周一日期>.csv`（每周一个文件）；可统计每日/每周/每月工作时长与 50h 达标情况；周末加班可用手动打卡单独记录。

## 文件

| 文件 | 说明 |
|:---|:---|
| `clockin-reminder.ps1` | 常驻主脚本（解锁检测 + 强制确认弹窗 + 统计，单文件） |
| `manual-clockin.ps1` / `manual-clockin.bat` | 手动打卡 / 补录（周末加班记录，或补录过去某天上下班时间；**双击 .bat 即开**，无需命令行） |
| `report.ps1` | 时长统计报告 + **运行状态检查**（命令行纯文本输出；`-Gui` 弹窗显示） |
| `report-gui.bat` | **双击查看运行状态 + 统计报告**（GUI 窗口，任意时间想看就看） |
| `config-gui.ps1` / `config-gui.bat` | **随时修改默认配置**（config.json 图形界面，不必等弹窗） |
| `install.ps1` | 一键安装：拷脚本 + 注册开机自启 + 立即启动 |
| `uninstall.ps1` | 一键卸载：停进程 + 删自启 + 删数据（选 N 保留 log 数据，重装可恢复） |

## 部署（在 Windows 上）

1. 把整个文件夹拷到 Windows（任意位置，如 `D:\tools\clockin-reminder`）
2. 打开 PowerShell，执行：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File D:\tools\clockin-reminder\install.ps1
   ```
3. 完成。开机自启已注册（HKCU Run，无需管理员）。

`install.ps1`（v7 起）先弹**配置表单**（预填已存在的 config.json——log 或根目录旧配置，重装时保留当前配置）：
- 点「确定（保存配置并安装）」→ 写 `log\config.json` 并继续安装
- 点「取消（用默认值）」→ 用默认配置继续（首次运行主脚本会自动创建 config.json）

**重装/升级不丢数据**：install 不删任何数据；只要 `log` 文件夹还在（没被手动删/卸载时选 N），重装后主程序直接读取 `log` 里的打卡记录、配置、状态。

v8 起，install 杀旧实例后、启动新实例前，会等待旧实例的单实例 Mutex 释放（最多 10 秒，每 0.5 秒试一次），避免新实例因 `WaitOne(0)` 失败直接退出导致装完没有常驻进程；启动后还会轮询 3 秒确认常驻进程确实存活（R30），没起来会给出警告提示查看 `log.txt`。

## 行为（v8）

- **周末跳过**：周六/周日不弹任何提醒、不写历史记录
- **8 点前**：脚本不轮询，睡到 8:00；8:00-12:00 之间主循环每 2 分钟兜底检查，到点弹上班提醒（即使当天没解锁、没开机动作）
- **下午到/迟到也能打卡（v6）**：解锁或开机启动时，上班提醒放宽到 8:00-23:00（12 点后开机/解锁也会弹，人到了才弹）；主循环兜底仍只在 8:00-12:00 弹（防深夜重装/重启误弹）。打卡时间上限放宽到当前时刻——下午 14 点到，填 14:00 不再被拦（超范围仍弹 YesNo 确认，可 Yes 记录）；12 点后的弹窗提示「迟到/下午到，如实填写实际打卡时间」
- **全天缺勤自动补 0 时长（v6）**：工作日晚上 20 点后若当天没有任何记录，自动补一行 `日期,,,,0h 0min`（上班/下班空、工作时长 0h 0min）；启动时若昨天是工作日且无记录，自动补昨天 0 时长行（整天没开电脑不漏记）。补记有去重，已有行不重复补；0 时长行在周/月统计里占一个工作日位置（作为 0，不拉高不拉低）
- **上班弹窗**：占屏 90%、刺眼黄底、红字，带输入框填实际打卡时间（8:00-10:00，超范围弹确认框，可 Yes 记录；Enter 键提交），必须点「确认已打卡」才关；Esc / Alt+F4 / 关闭按钮全部拦截。**强制置顶（v12）**：弹窗 Shown 时自动激活到前台 + BringToFront + SetWindowPos(HWND_TOPMOST) 压到 Z 序最顶，即使有其他置顶窗口/全屏应用也盖不住，保证上班/下班提醒一定能看到。**右下角有「紧急关闭（不打卡）」后门按钮**（低调小字），点它立即关闭弹窗、不写任何打卡数据、当天不再弹——防止强制弹窗异常时电脑没法用（调试逃生通道）
- **下班提醒（首次）** = 实际打卡时间 + 10 小时，主循环每 2 分钟检查，到点弹同样式弹窗（**同样有右下角紧急关闭后门**）；周五漏确认的提醒，下次工作日开机补弹
- **下班弹窗两个按钮（v11）**：**「确定下班」**（填当前时间，写入实际下班时间、结束当天提醒）/ **「稍后打卡」**（填当前时间，弹窗先关闭，按 `ReRemindIntervalMinutes`（默认 30 分钟）间隔再次弹窗）。两个按钮都**必须先手动输入当前时间**（HH:mm，默认已填当前时刻）才会关闭弹窗——和上班弹窗一样防误触；Enter 回车 = 确定下班
- **下班循环提醒（加班）**：点「稍后打卡」后按 `ReRemindIntervalMinutes`（默认 30 分钟）安排下次提醒，到点再弹，Message 显示「已满 X 小时（加班 Y 小时），再次确认下班打卡」；重复直到用户点「确定下班」或当前时间 ≥ `MaxRemindHour`（默认 23 点，23 点后不再自动提醒）。循环提醒只限当天，跨天残留自动停止；周末不自动循环，周末加班用手动打卡记
- **下班确认写库（取最晚）**：点「确定下班」时，把填写的实际时间写入对应 log 周文件的 `offwork_actual` 列（v8 起存**完整 datetime** `yyyy-MM-dd HH:mm:ss`，加班到次日也显式记录）；同一天多次确认只保留**最晚**一次（更早的确认跳过并写日志）；跨天时长直接由完整日期算出，无歧义（旧 `HH:mm` 行走 `end < start → 视为次日` 推断兼容）
- **弹窗附带统计**：上班/下班弹窗 Message 里都附加统计——上班弹窗显示「本周工作日累计 + 50h 达标进度 + 本月累计」；下班弹窗显示「今日时长 + 本周工作日累计 + 50h 达标状态」。仅附加信息，确认动作不变
- **统计口径**：每日时长 = `offwork_actual`（为空回退预计 `offwork_at`）− 上班打卡；v8 起下班时间存完整 datetime（跨天加班到次日直接写次日日期），时长直接 `end - start` 算出；旧 `HH:mm` 行才走「下班早于上班 → 视为次日」推断；周 = 周一~周日，工作日合计（周一~五）用于 50h 达标判断，周末加班单列；月 = 自然月全部记录
- **弹窗不阻塞主循环**：弹窗在独立 runspace 线程运行，锁屏/人不在时挂起的弹窗不影响下班检查
- 单实例互斥（双开自动退出）；state.json 原子写、解析失败跳过不崩脚本；主循环异常自动恢复（30 秒重试）

## 手动打卡 / 补录（manual-clockin.bat）

周末加班、或**补录过去某一天的上下班时间**：双击 `manual-clockin.bat`（或命令行 `powershell -NoProfile -ExecutionPolicy Bypass -File manual-clockin.ps1`）。

- 弹窗**选日期**（默认今天；改到过去任意一天即补录，比如周一周二已过去、周三才用上工具，就选周一/周二补录）、选「记上班卡」或「记下班卡」，填时间（`HH:mm` / `H:mm`，默认当前时间），点「写入记录」
- 补录写入**对应周的 log 周文件**（`log\\<周一日期>.csv`，v9），周/月统计自动纳入
- **写入成功不关闭窗口**（v10）：可连续改日期/类型/时间补录修改多天，写一次存一次；点「退出」按钮、按 Esc 或点右上角 X 才关闭
- 记下班卡取**最晚**：当天已有下班记录时，新时间更晚 → 弹「已存在下班记录 X，新时间 Y 更晚，更新为 Y？」（Yes 更新，No 不动）；新时间更早 → 提示「已存在更晚的下班记录 X，不更新」并跳过；没有则新增一行
- 普通窗口、可关闭，不触发主脚本任何提醒；周末记录计入周/月统计的「周末加班」单列，不参与 50h 达标

## 修改配置（config-gui.bat）

**随时改默认配置，不必等上班/下班弹窗**：双击 `config-gui.bat`（或命令行 `powershell -NoProfile -ExecutionPolicy Bypass -File config-gui.ps1`）。

- 图形界面列出全部配置项：下班提醒小时 / 上班提醒最早 / 打卡时间最晚 / 上班自动提醒最晚 / 下班循环间隔 / 最晚自动提醒 / 周末跳过
- 保存写入 `log\config.json`（原子写；老版本根目录 config.json 自动兼容读取，保存后落在 log）；**主程序最多 2 分钟轮询自动生效**（R23），想立即生效就重跑一次 `install.ps1`
- 与 install.ps1 的配置表单同一套视觉与校验（上班最早不能晚于自动提醒最晚 / 打卡最晚）

**弹窗里也能改**（R23）：上班/下班弹窗底部有「解锁更改配置」按钮，点开后显示每项配置名称 + 数字框（下班提醒小时 / 上班最早 / 打卡最晚 / 自动弹最晚 / 循环间隔 / 最晚提醒 / 周末跳过），改完点「保存配置」写 config.json。配置项名称默认隐藏，解锁后与数字框一起显示（v9 修复）。

## 统计报告 + 运行状态（report.ps1 / report-gui.bat）

**任意时间想看打卡统计 / 确认常驻程序是否在正常运行**，两种途径：

- **双击 `report-gui.bat`** → 弹暗色只读窗口，**顶部显示运行状态**（主程序是否在跑、心跳时间、今日状态、日志异常数、配置摘要），下方是本周统计（最方便，状态 + 报告一次看完）；双击时自动把统计保存到 `log\report-<日期>.csv`（R38 起进 log 文件夹）
- 命令行运行（纯文本输出到控制台）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1            # 本周（默认）
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Week
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Month
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -All
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Days 7
powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Gui       # 弹窗模式（同 bat）
```

运行状态判定（R32）：

- 主程序每 2 分钟把心跳时间写入 `state.json` 的 `last_heartbeat_at`；心跳 ≤10 分钟前更新 → `✅ 主程序运行中`；缺失/过期 → `❌ 主程序未运行`
- 辅助显示：进程实例数（按命令行匹配 `clockin-reminder.ps1`）、今日打卡状态（state.json）、log.txt 累计异常条数、当前配置摘要

示例输出：

```
==================== 运行状态 ====================
✅ 主程序运行中
   心跳: 2026-08-05 16:30:00（1 分钟前）
   进程: 找到 1 个实例（PID 12345）
   今日 2026-08-05: 上班 09:12 · 下班提醒 已触发
   日志: log.txt 共 2 条异常记录
   配置: 满 10h 提醒下班 · 上班窗 8-12点 · 循环 30min · 23点截止 · 周末跳过

==================== 打卡统计 ====================
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
- 请假/全天缺勤行（上班/下班都空）显示 `周一 08-11  -  -  0h 0min  (请假)`，计入工作日占位（不影响 50h 合计数值）
- 解析失败/旧格式行跳过，末尾提示行号

## 数据文件（log 周文件）

数据与脚本**同目录**（R31，就地安装，不再用 `%USERPROFILE%\\.clockin-reminder\\`），R38 起**所有运行产物统一放 `log` 文件夹**（周记录 / 配置 / 状态 / 日志）：

```
<脚本所在目录>\
  log\config.json            配置（R38 从根目录迁入；老版本升级启动时自动迁移）
  log\state.json             状态（date / clockin_time / offwork_at / next_remind_at / last_heartbeat_at 心跳，R32）
  log\log.txt                异常日志
  log\2026-08-03.csv         本周记录（文件名 = 该周周一的日期）
  log\2026-08-10.csv         上周记录
  ...
  history.csv                旧版单一文件（v8 起不再写入；若存在，读取时仍合并，迁移兼容）
```

**重装/升级保留数据**：只要不删除 `log` 文件夹，再次安装后主程序自动读取 `log` 里的全部数据（打卡记录 / 配置 / 状态）。老版本根目录的 `config.json` / `state.json` / `log.txt` 在升级后首次启动自动迁入 `log` 文件夹，配置不丢。

每个周文件表头 5 列：

```
日期,上班时间,预计下班,实际下班,工作时长
2026-08-03,09:12,2026-08-03 19:12:00,2026-08-03 19:05:30,9h 53min
2026-08-06,14:00,2026-08-07 00:00:00,2026-08-07 00:30:00,10h 30min   ← 跨天：下班卡超 24 点，完整日期显式写次日
2026-08-11,,,,0h 0min                                                ← 全天缺勤/请假（v6 自动补记）：上班下班空，时长 0h 0min
```

- `date` 上班日期（`yyyy-MM-dd`）；`clockin` 上班打卡（`HH:mm`）
- `offwork_at` **预计**下班时间（= 上班 + 10h），`offwork_actual` **实际**确认下班时间；v8 起两者都存**完整 datetime**（`yyyy-MM-dd HH:mm:ss`，下班跨天到次日直接写下一天日期，无歧义）
- `duration` 当天实际工作时长（`Xh Ymin`）；缺上班或下班信息时为空
- **请假/全天缺勤行**（v6）：`date,,,,0h 0min`（上班/下班列空、时长 `0h 0min`），由主脚本在当晚 20 点后或启动时自动补记，写入该日期所在周文件；report 显示为 `-  -  0h 0min  (请假)`，计入工作日占位
- **跨天计算**：完整 datetime 直接解析 `end - start`；旧 `HH:mm` 行（无日期）才走推断 `end = date + 时间`，若 `end < start` 则视为次日（`+1 天`）；主脚本 / manual-clockin / report 三处实现一致
- `offwork_actual` 同一天多次确认取**最晚**一次（主脚本自动循环确认 / 手动打卡都遵守）；确认后 `duration` 列会随之重算
- 统计时优先 `offwork_actual`，为空回退 `offwork_at`（预计值，精度略差）
- 读取 = 合并所有 `log\*.csv` 周文件（按日期排序）+ 根目录旧 `history.csv`（若存在），跨周/跨月统计天然支持
- 兼容读取：3 列（v1）/ 4 列（v3/v4）/ 5 列（v5 HH:mm）/ v8 完整 datetime 均可读；旧文件不强制迁移

`state.json` 内部 `offwork_at` / `next_remind_at` 保持完整 datetime（`yyyy-MM-dd HH:mm:ss`）。旧 state 没有 `next_remind_at` 字段时自动回退 `offwork_at` 首次提醒，无需迁移。

## 验证

1. 按 `Win+L` 锁屏再解锁（工作日 8-12 点）→ 应弹出上班提醒
2. 查看记录（脚本同目录，数据全在 `log` 文件夹）：
   ```powershell
   Get-Content ".\log\state.json"
   Get-Content ".\log\*.csv"      # 按周归档的历史记录
   Get-Content ".\log\log.txt"    # 异常日志
   ```
3. 快速验证：把主脚本里 `$script:WorkWindowStart = 8` 改成 `0`、`$script:OffWorkHours = 10` 改成 `0.05`（3 分钟），
   重跑 `install.ps1` → 立即弹上班提醒，填时间后 3 分钟弹下班提醒。验完改回。

## 每周一个 CSV（log 文件夹）

v8 起历史记录**本身就按周归档**：每天记录写入当天所在周的周文件 `log\<周一日期>.csv`（文件不存在自动建、含中文表头；启动时自动创建 log 目录）。每个周文件就是这一周的完整记录，可直接打开查看：

- 文件名 = 该周周一的日期，例如 `log\2026-08-03.csv` 存 8/3~8/9 这一周
- 统计（report / 弹窗 / 50h 达标）读取时合并所有周文件 + 旧 `history.csv`，跨周/跨月无感知
- 旧版根目录 `history.csv` 不再写入，仅保留读取兼容；`uninstall` 会连同 `log` 文件夹一起删除（Y 确认时）

## 常见问题

- **弹窗没出现**：确认任务管理器里有 `powershell.exe`（无窗口）在跑；没有就跑一次 `install.ps1`；再看 `log.txt`
- **开机自启失效**：检查 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run` 里 `ClockinReminder` 项
- **改时长/窗口**：编辑主脚本顶部配置区（`$script:OffWorkHours` / `$script:WorkWindowStart` / `$script:WorkAutoPopupEnd` / `$script:SkipWeekend` / `$script:ReRemindIntervalMinutes` 下班循环间隔分钟 / `$script:MaxRemindHour` 最晚自动提醒小时），然后重跑 `install.ps1`

## 卸载

双击或命令行运行 `uninstall.ps1`（停进程 + 删自启 + 删数据，删数据前会确认；**选 N 保留 `log` 文件夹，重装后自动恢复全部数据**；R31 起只删数据文件、保留脚本本身）：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```

手动卸载等价命令：
```powershell
# 1. 停掉常驻进程
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" |
    Where-Object { $_.CommandLine -like '*clockin-reminder.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 2. 删开机自启项
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ClockinReminder'

# 3. 删数据（数据全在 log 文件夹；删了 log 即重装不恢复）
Remove-Item ".\log" -Recurse -Force
Remove-Item ".\history.csv" -Force   # 旧版残留（如有）
```

## 说明

- 只做**提醒弹窗**，不自动打卡（飞书打卡需企业 API，不在此工具范围）
- 依赖 Windows 自带 PowerShell 5.1+，零第三方依赖；低资源占用（2 分钟轻量轮询 + WTS API 会话状态查询）
