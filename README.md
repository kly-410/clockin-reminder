# Windows 打卡提醒小工具

一个常驻后台的小工具：**到点弹窗提醒你打卡上下班**，自动记录工时、统计每周是否达标 50 小时。

## 🚀 快速开始（30 秒）

1. 把整个文件夹拷到 Windows（任意位置，如 `D:\tools\clockin-reminder`）
2. **双击 `install.bat`** → 弹配置表单 → 点确定
3. 完成。已注册开机自启，从此不用管它。

## ✅ 它帮你做什么

| 功能 | 说明 |
|:---|:---|
| ⏰ **上班提醒** | 工作日 8-10 点弹窗，填实际打卡时间 |
| 🕕 **下班提醒** | 上班打卡后满 10 小时弹窗，填实际下班时间 |
| 🔁 **加班循环提醒** | 点"稍后打卡"后每 30 分钟再提醒，直到你确认下班 |
| 📊 **自动统计** | 每日/每周/每月工时，50h 达标判断 |
| 🚫 **周末跳过** | 周六日不弹提醒，周末加班可手动补录 |
| 📁 **按周归档** | 记录存 `log\2026-08-03.csv`（文件名=周一日期）|

## 📖 日常怎么用

| 想做什么 | 操作 |
|:---|:---|
| 查看统计 / 确认程序在跑 | 双击 `report-gui.bat` |
| 补录某天打卡 / 记周末加班 | 双击 `manual-clockin.bat` |
| 修改提醒时间等配置 | 双击 `config-gui.bat` |
| 卸载 | 双击 `uninstall.bat` |

## ⚙️ 可配置项

所有配置可在 `log\config.json` 修改，或双击 `config-gui.bat` 图形界面调整：

| 配置项 | 默认值 | 说明 |
|:---|:---:|:---|
| `OffWorkHours` | 10 | 上班打卡后几小时提醒下班 |
| `WorkWindowStart` | 8 | 上班提醒最早时间（点）|
| `WorkWindowEnd` | 10 | 打卡时间最晚（点）|
| `WorkAutoPopupEnd` | 12 | 上班自动提醒最晚（点）|
| `ReRemindIntervalMinutes` | 30 | 下班循环提醒间隔（分钟）|
| `MaxRemindHour` | 23 | 最晚自动提醒小时（点）|
| `TargetMinutesPerWeek` | 3000 | **每周目标工时（分钟）= 50h** |
| `SkipWeekend` | true | 周六/周日跳过提醒 |

## 📁 数据在哪

所有数据在脚本同目录的 `log` 文件夹：

```
log\config.json        配置
log\state.json         状态
log\2026-08-03.csv     本周打卡记录（每周一个文件）
log\log.txt            运行日志
```

**重装/升级不丢数据**：只要 `log` 文件夹还在，重装后自动恢复。

## ❓ 常见问题

- **弹窗没出现** → 看任务管理器有没有 `powershell.exe` 在跑；没有就重跑一次 `install.bat`
- **开机自启失效** → 检查注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `ClockinReminder` 项
- **想改提醒时间** → 双击 `config-gui.bat`

## 📝 说明

- 只做**提醒弹窗**，不自动打卡（飞书打卡需企业 API，不在工具范围）
- 依赖 Windows 自带 PowerShell 5.1+，零第三方依赖
- 低资源占用：2 分钟轻量轮询

## 📦 版本

**v0.1** — 首个版本
