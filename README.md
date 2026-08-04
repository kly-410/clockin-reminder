# Windows 打卡提醒小工具

常驻后台的 PowerShell 脚本：**工作日 8 点提醒上班打卡（黄底红字、占屏 90%、必须点确认才关），填实际打卡时间后满 10 小时提醒下班打卡。周六/周日自动跳过，不提醒、不写记录。**

## 文件

| 文件 | 说明 |
|:---|:---|
| `clockin-reminder.ps1` | 常驻主脚本（解锁检测 + 强制确认弹窗，单文件） |
| `install.ps1` | 一键安装：拷脚本 + 注册开机自启 + 立即启动 |

## 部署（在 Windows 上）

1. 把整个文件夹拷到 Windows（任意位置，如 `D:\tools\clockin-reminder`）
2. 打开 PowerShell，执行：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File D:\tools\clockin-reminder\install.ps1
   ```
3. 完成。开机自启已注册（HKCU Run，无需管理员）。

## 行为（v2）

- **周末跳过**：周六/周日不弹任何提醒、不写历史记录
- **8 点前**：脚本不轮询，睡到 8:00；8:00-12:00 之间主循环每 15 秒兜底检查，到点弹上班提醒（即使当天没解锁、没开机动作）
- **12 点后启动**：当天不自动弹上班提醒（防止深夜重装/重启误弹）
- **上班弹窗**：占屏 90%、刺眼黄底、红字，带输入框填实际打卡时间（8:00-10:00，超范围弹确认框，可 Yes 记录；Enter 键提交），必须点「确认已打卡」才关；Esc / Alt+F4 / 关闭按钮全部拦截
- **下班提醒** = 实际打卡时间 + 10 小时，主循环每 15 秒检查，到点弹同样式弹窗，必须点「确认已下班」才关；周五漏确认的提醒，下次工作日开机补弹
- **弹窗不阻塞主循环**：弹窗在独立 runspace 线程运行，锁屏/人不在时挂起的弹窗不影响下班检查
- 单实例互斥（双开自动退出）；state.json 原子写、解析失败跳过不崩脚本；主循环异常自动恢复（30 秒重试）

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
- **改时长/窗口**：编辑主脚本顶部配置区（`$script:OffWorkHours` / `$script:WorkWindowStart` / `$script:WorkAutoPopupEnd` / `$script:SkipWeekend`），然后重跑 `install.ps1`

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
