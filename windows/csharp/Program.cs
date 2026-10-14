// 休眠助手 · Sleep Assistant (Windows)
// 菜单栏/托盘常驻开关：让笔记本合盖也不休眠、任务不被打断。
//
// 原理（与 macOS 版对应）：
//   1) SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED|ES_DISPLAY_REQUIRED|ES_AWAYMODE_REQUIRED)
//      —— 由本进程持有，阻止系统/显示器休眠，配合 ES_AWAYMODE_REQUIRED 进入“离开模式”继续跑任务。
//      进程退出或清除标志即恢复休眠。无需管理员。
//   2) 合盖动作：Windows 笔记本默认“合盖睡眠”，这是电源计划设置，需管理员改写。
//      powercfg 把「合盖子菜单的操作」设为“无操作”(0)。首次设置会弹 UAC。
//
// 依赖：.NET 8（构建见 build.bat）。运行期零第三方依赖。

using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace SleepAssistant;

internal static class Program
{
    private const string MutexName = "SleepAssistant_SingleInstanceMutex";

    [STAThread]
    static void Main()
    {
        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        // 单实例：重复启动只唤醒已有实例
        using var mtx = new Mutex(true, MutexName, out bool isNew);
        if (!isNew) return;

        Application.Run(new TrayApplicationContext());
    }
}

internal sealed class TrayApplicationContext : ApplicationContext
{
    // ---- SetThreadExecutionState ----
    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint esFlags);
    private const uint ES_CONTINUOUS = 0x80000000;
    private const uint ES_SYSTEM_REQUIRED = 0x00000001;
    private const uint ES_DISPLAY_REQUIRED = 0x00000002;
    private const uint ES_AWAYMODE_REQUIRED = 0x00000040;

    // 电源计划：「电源按钮和盖子」子组 + 「合盖操作」设置
    private static readonly Guid LidSubgroup = new("4f971e89-eebd-4455-a8de-9e59040e7347");
    private static readonly Guid LidClose = new("5ca83367-6e45-459f-a27b-476b1d01c936");
    // 开机自启动（注册表 Run 项）
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string AutostartValueName = "SleepAssistant";

    private readonly NotifyIcon _tray;
    private readonly ContextMenuStrip _menu;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _toggleItem;
    private readonly ToolStripMenuItem _timerItem;
    private readonly ToolStripMenuItem _lidItem;
    private readonly ToolStripMenuItem _autostartItem;
    private readonly ToolStripMenuItem _exitItem;
    private readonly System.Windows.Forms.Timer _tick;
    private readonly System.Windows.Forms.Timer _refresh;

    private bool _isOn;
    private DateTime _onSince;
    private bool _lidManaged;          // 是否由本程序改过合盖设置
    private (int ac, int dc) _lidOriginal;

    private Icon _iconOn = null!;      // 实心（不休眠）
    private Icon _iconOff = null!;     // 空心（正常休眠）
    private Bitmap _bmpOn = null!;     // 保活：FromHandle 的位图不能提前释放
    private Bitmap _bmpOff = null!;

    private readonly string _stateDir;
    private readonly string _lidBackupFile;

    public TrayApplicationContext()
    {
        _stateDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SleepAssistant");
        _lidBackupFile = Path.Combine(_stateDir, "lid_backup.txt");
        Directory.CreateDirectory(_stateDir);

        (_iconOn, _bmpOn) = MakeIcon(true);
        (_iconOff, _bmpOff) = MakeIcon(false);

        _menu = new ContextMenuStrip();
        _statusItem = new ToolStripMenuItem("状态：检测中…") { Enabled = false };
        _timerItem = new ToolStripMenuItem("") { Enabled = false };
        _toggleItem = new ToolStripMenuItem("开启不休眠", null, (_, _) => Toggle());
        _lidItem = new ToolStripMenuItem("设置合盖不休眠（需管理员）", null, async (_, _) => await SetupLidAsync());
        _autostartItem = new ToolStripMenuItem("开机自动启动", null, (_, _) => ToggleAutostart()) { CheckOnClick = true };
        _exitItem = new ToolStripMenuItem("退出", null, (_, _) => ExitApp());

        _menu.Items.AddRange(new ToolStripItem[]
        {
            _statusItem, _timerItem,
            new ToolStripSeparator(),
            _toggleItem, _lidItem,
            new ToolStripSeparator(),
            _autostartItem,
            new ToolStripSeparator(),
            _exitItem,
        });

        _tray = new NotifyIcon
        {
            Icon = _iconOff,
            Text = "休眠助手",
            Visible = true,
            ContextMenuStrip = _menu,
        };
        _tray.DoubleClick += (_, _) => Toggle();

        // 每 30s 重新声明一次执行状态（离开模式建议周期性刷新）
        _refresh = new System.Windows.Forms.Timer { Interval = 30_000 };
        _refresh.Tick += (_, _) => { if (_isOn) ApplyAwake(); };
        _refresh.Start();

        // 每秒刷新计时显示
        _tick = new System.Windows.Forms.Timer { Interval = 1000 };
        _tick.Tick += (_, _) => UpdateStatus();
        _tick.Start();

        LoadLidState();
        UpdateStatus();
    }

    // MARK: 切换不休眠
    private void Toggle()
    {
        if (_isOn) Disable(); else Enable();
    }

    private void Enable()
    {
        _isOn = true;
        _onSince = DateTime.Now;
        ApplyAwake();
        _tray.Icon = _iconOn;
        _tray.Text = "休眠助手 · 不休眠中";
        UpdateStatus();
    }

    private void Disable()
    {
        _isOn = false;
        SetThreadExecutionState(ES_CONTINUOUS); // 清除，恢复休眠
        _tray.Icon = _iconOff;
        _tray.Text = "休眠助手 · 正常休眠";
        UpdateStatus();
    }

    private void ApplyAwake()
        => SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED | ES_AWAYMODE_REQUIRED);

    // MARK: 合盖不休眠（powercfg，需管理员）
    private async Task SetupLidAsync()
    {
        if (_lidManaged)
        {
            // 已设置 → 恢复默认
            await RestoreLidAsync();
            return;
        }

        var cur = ReadLidAction();
        _lidOriginal = cur;
        SaveLidBackup(cur);

        // 合盖 = 0（无操作）
        bool ok = await RunElevatedAsync(
            $"powercfg /setacvalueindex SCHEME_CURRENT {LidSubgroup} {LidClose} 0 && " +
            $"powercfg /setdcvalueindex SCHEME_CURRENT {LidSubgroup} {LidClose} 0 && " +
            $"powercfg /setactive SCHEME_CURRENT");

        if (ok)
        {
            _lidManaged = true;
            SaveLidState();
        }
        UpdateStatus();
    }

    private async Task RestoreLidAsync()
    {
        if (!_lidManaged) return;
        bool ok = await RunElevatedAsync(
            $"powercfg /setacvalueindex SCHEME_CURRENT {LidSubgroup} {LidClose} {_lidOriginal.ac} && " +
            $"powercfg /setdcvalueindex SCHEME_CURRENT {LidSubgroup} {LidClose} {_lidOriginal.dc} && " +
            $"powercfg /setactive SCHEME_CURRENT");
        if (ok)
        {
            _lidManaged = false;
            File.Delete(_lidBackupFile);
        }
        UpdateStatus();
    }

    private (int ac, int dc) ReadLidAction()
    {
        try
        {
            var psi = new ProcessStartInfo("powercfg",
                $"/query SCHEME_CURRENT {LidSubgroup} {LidClose}")
            { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
            using var p = Process.Start(psi);
            string outp = p!.StandardOutput.ReadToEnd();
            p.WaitForExit();
            // 只取最后的两个 0x????????（即当前 AC / DC 索引；其余为 GUID，与语言无关）
            var hex = System.Text.RegularExpressions.Regex.Matches(outp, @"0x[0-9a-fA-F]{8}")
                .Select(m => Convert.ToInt32(m.Value, 16)).ToList();
            if (hex.Count >= 2) return (hex[^2], hex[^1]);
        }
        catch { }
        return (1, 1); // 读不到时按“睡眠”处理
    }

    // MARK: 提权执行（UAC）
    private static Task<bool> RunElevatedAsync(string command)
    {
        var tcs = new TaskCompletionSource<bool>();
        try
        {
            var psi = new ProcessStartInfo("cmd.exe", "/c " + command)
            { Verb = "runas", UseShellExecute = true, CreateNoWindow = true };
            using var p = Process.Start(psi);
            p!.EnableRaisingEvents = true;
            p.Exited += (_, _) => tcs.TrySetResult(p.ExitCode == 0);
            if (p.HasExited) tcs.TrySetResult(p.ExitCode == 0);
        }
        catch
        {
            // 用户取消 UAC 或提权失败
            tcs.TrySetResult(false);
        }
        return tcs.Task;
    }

    // MARK: 开机自启动
    private bool AutostartEnabled()
    {
        using var k = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        return k?.GetValue(AutostartValueName) != null;
    }

    private void ToggleAutostart()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKeyPath, true);
            if (AutostartEnabled())
            {
                k?.DeleteValue(AutostartValueName, false);
            }
            else
            {
                k?.SetValue(AutostartValueName, "\"" + Application.ExecutablePath + "\"");
            }
        }
        catch { }
        _autostartItem.Checked = AutostartEnabled();
    }

    // MARK: 状态显示
    private void UpdateStatus()
    {
        _autostartItem.Checked = AutostartEnabled();

        if (_isOn)
        {
            var dur = DateTime.Now - _onSince;
            _statusItem.Text = "● 不休眠中（合盖、闲置都不睡）";
            _timerItem.Text = $"已阻止休眠 {Fmt(dur)} · 合盖：{(LidIsDoNothing() ? "无操作 ✓" : "会睡眠（点上面设置）")}";
            _toggleItem.Text = "结束不休眠（恢复正常休眠）";
        }
        else
        {
            _statusItem.Text = "○ 正常休眠";
            _timerItem.Text = LidIsDoNothing() ? "合盖动作：无操作（点上面可恢复）" : "";
            _toggleItem.Text = "开启不休眠";
        }
        _lidItem.Text = _lidManaged ? "恢复合盖默认（需管理员）" : "设置合盖不休眠（需管理员）";
    }

    private bool LidIsDoNothing() => _lidManaged || ReadLidAction() == (0, 0);

    private static string Fmt(TimeSpan t)
    {
        if (t.TotalHours >= 1) return $"{(int)t.TotalHours} 时 {t.Minutes} 分";
        if (t.TotalMinutes >= 1) return $"{t.Minutes} 分 {t.Seconds} 秒";
        return $"{t.Seconds} 秒";
    }

    // MARK: 合盖状态持久化（重启后仍知道是否由本程序改过）
    private void SaveLidState()
    {
        try { File.WriteAllText(Path.Combine(_stateDir, "lid_state.txt"), "managed"); } catch { }
    }

    private void SaveLidBackup((int ac, int dc) v)
    {
        try { File.WriteAllText(_lidBackupFile, $"{v.ac} {v.dc}"); } catch { }
    }

    private void LoadLidState()
    {
        try
        {
            if (File.Exists(Path.Combine(_stateDir, "lid_state.txt")))
            {
                _lidManaged = true;
                if (File.Exists(_lidBackupFile))
                {
                    var parts = File.ReadAllText(_lidBackupFile).Split();
                    if (parts.Length == 2) _lidOriginal = (int.Parse(parts[0]), int.Parse(parts[1]));
                }
            }
        }
        catch { }
    }

    // MARK: 退出
    private void ExitApp()
    {
        if (_isOn)
        {
            var r = MessageBox.Show("当前处于不休眠状态，退出应用后会恢复正常休眠。是否退出？",
                "休眠助手", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (r != DialogResult.Yes) return;
        }
        // 若改过合盖设置，退出前恢复（避免一直不合盖睡）
        if (_lidManaged)
        {
            var r = MessageBox.Show("检测到已设置「合盖不休眠」。是否恢复系统默认的合盖动作？",
                "休眠助手", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (r == DialogResult.Yes) _ = RestoreLidAsync().Wait(TimeSpan.FromSeconds(60));
            if (r == DialogResult.Cancel) return;
        }
        Disable();
        _tray.Visible = false;
        _tray.Dispose();
        Application.Exit();
    }

    // MARK: 图标：弯月（空心=正常休眠 / 实心=不休眠），GDI+ 绘制
    // 返回 (Icon, 源 Bitmap)——调用方必须持有 Bitmap，否则 FromHandle 的句柄会失效。
    private static (Icon icon, Bitmap bmp) MakeIcon(bool on)
    {
        const int px = 32;
        var bmp = new Bitmap(px, px);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var path = BuildCrescent(px);
            var color = Color.FromArgb(0x22, 0x26, 0x2e); // 深色，浅色任务栏可见
            if (on)
            {
                using var b = new SolidBrush(color);
                g.FillPath(b, path);
            }
            else
            {
                using var pen = new Pen(color, 2.2f);
                g.DrawPath(pen, path);
            }
        }
        return (Icon.FromHandle(bmp.GetHicon()), bmp);
    }

    // 与 macOS 版同款：外弧(过最远点) + 内弧(过最近点)，折线采样成月牙轮廓
    private static GraphicsPath BuildCrescent(int size)
    {
        double Map(double v) => v / 18.0 * size; // 18 单位基准
        var O = new PointF((float)Map(9.0), (float)Map(9.0));
        var I = new PointF((float)Map(11.9), (float)Map(6.1));
        float R = (float)Map(7.0), r = (float)Map(6.2);
        double dx = I.X - O.X, dy = I.Y - O.Y, d = Math.Sqrt(dx * dx + dy * dy);
        double a = (R * R - r * r + d * d) / (2 * d);
        double h = Math.Sqrt(Math.Max(0, R * R - a * a));
        double ux = dx / d, uy = dy / d;
        var M = new PointF((float)(O.X + a * ux), (float)(O.Y + a * uy));
        var P1 = new PointF((float)(M.X + h * -uy), (float)(M.Y + h * ux));
        var P2 = new PointF((float)(M.X - h * -uy), (float)(M.Y - h * ux));
        double aO1 = Math.Atan2(P1.Y - O.Y, P1.X - O.X), aO2 = Math.Atan2(P2.Y - O.Y, P2.X - O.X);
        double aI1 = Math.Atan2(P1.Y - I.Y, P1.X - I.X), aI2 = Math.Atan2(P2.Y - I.Y, P2.X - I.X);
        double aF = Math.Atan2(-uy, -ux), aG = Math.Atan2(-uy, -ux); // 外弧过最远点 / 内弧过最近点
        var outer = ArcPoints(O, R, aO1, aO2, aF, 56);
        var inner = ArcPoints(I, r, aI2, aI1, aG, 56);
        var path = new GraphicsPath();
        path.AddLines(outer.Concat(inner).ToArray());
        path.CloseFigure();
        return path;
    }

    private static PointF[] ArcPoints(PointF c, float R, double a0, double a1, double aRef, int steps)
    {
        double Norm(double x) { double v = x % (2 * Math.PI); return v < 0 ? v + 2 * Math.PI : v; }
        double s = Norm(a0), e = Norm(a1), rf = Norm(aRef);
        bool ccw = s <= e ? (rf >= s && rf <= e) : (rf >= s || rf <= e);
        var pts = new PointF[steps + 1];
        for (int i = 0; i <= steps; i++)
        {
            double t = (double)i / steps;
            double delta = ccw ? (e - s) : (s - e);
            if (delta < 0) delta += 2 * Math.PI;
            double ang = ccw ? s + delta * t : s - delta * t;
            pts[i] = new PointF((float)(c.X + R * Math.Cos(ang)), (float)(c.Y + R * Math.Sin(ang)));
        }
        return pts;
    }
}
