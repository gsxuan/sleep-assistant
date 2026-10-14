# 休眠助手 · Windows 版

macOS 版的 Windows 对应实现：托盘常驻开关，让笔记本**合盖也不休眠**，任务不被打断。C# / .NET 8 / WinForms，运行期零第三方依赖。

> 与 macOS 版共用同一套产品逻辑与「实心=不休眠 / 空心=正常休眠」的弯月图标。

## 它怎么让电脑不休眠

Windows 上用两件事，缺一不可：

1. **`SetThreadExecutionState`**（本进程持有，无需管理员）
   设置 `ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED | ES_AWAYMODE_REQUIRED`，
   阻止系统/显示器休眠，并以“离开模式(away mode)”继续跑任务。进程退出或清除即恢复。
2. **合盖动作改为“无操作”**（`powercfg`，需管理员）
   Windows 笔记本默认“合盖即睡”，这是电源计划设置，只能由管理员改写。
   程序把「电源按钮和盖子 → 合盖操作」设为 0（无操作），并记住原值以便恢复。

> 电池供电时的合盖策略同理受电源计划控制；本程序对交流/直流（插电/电池）都会设置。

## 构建

需要 .NET 8 SDK（<https://dotnet.microsoft.com/download/dotnet/8.0>）。

```bat
build.bat
```

或手动：

```bat
dotnet publish -c Release -r win-x64 --self-contained true /p:PublishSingleFile=true -o publish
```

产物：`publish\SleepAssistant.exe`（单文件、自包含，目标机器无需安装 .NET 运行时）。
在 macOS/Linux 上交叉编译加 `-p:EnableWindowsTargeting=true`。

## 使用

1. 双击 `SleepAssistant.exe`，任务栏托盘出现弯月图标（空心=正常休眠）。
2. **双击图标**或右键「开启不休眠」→ 变实心，开始阻止休眠并计时。
3. 首次点「设置合盖不休眠（需管理员）」会弹一次 **UAC**，授权后合盖也不再睡；
   再点一次「恢复合盖默认」还原。退出时如改过合盖设置会询问是否恢复。
4. 「开机自动启动」写入注册表 `HKCU\...\CurrentVersion\Run`（默认关）。

## 菜单

```
● 不休眠中（合盖、闲置都不睡）
已阻止休眠 2 时 15 分 · 合盖：无操作 ✓
───
开启不休眠 / 结束不休眠
设置合盖不休眠（需管理员） / 恢复合盖默认
───
开机自动启动  [√]
───
退出
```

## 安全说明

- `SetThreadExecutionState` 完全在用户态，不需要任何提权。
- 只有「合盖动作」这一项需要管理员（改电源计划），通过标准 UAC 提权执行固定几条 `powercfg`，
  程序不保存、不读取你的密码，也不上传任何数据。
- 原始合盖值保存在 `%APPDATA%\SleepAssistant\lid_backup.txt`，仅用于恢复。

## 文件

- `Program.cs` —— 全部逻辑（托盘、图标绘制、执行状态、powercfg、自启动）
- `SleepAssistant.csproj` —— .NET 8 WinForms，win-x64 自包含单文件
- `build.bat` —— 一键构建

MIT License.
