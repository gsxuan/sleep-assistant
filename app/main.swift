import AppKit

// 休眠助手.app —— 菜单栏常驻开关（单应用，点击切换）
//
// 菜单栏弯月图标：
//   实心琥珀月 = 不休眠中（合盖、闲置都不睡）
//   灰色月     = 正常休眠
// 点图标 → 菜单切换；菜单里还会列出「其他进程持有的防睡断言」。
//
// 实现：把 caffeinate 注册成 launchd 系统任务（system 域），由 launchd 直管，
//   终端关闭、SSH 断线、退出本应用都不影响，且支持「合盖不休眠」。
//
// 免密方案：本机 macOS（27.2）禁止普通用户往自己的 gui 域 bootstrap（报
//   "Bootstrap failed: 5: Input/output error"），gui 域免密路线在此机器不可用。
//   因此改为：首次运行弹一次系统密码框，安装固定辅助脚本
//   /usr/local/bin/caffeinate-toggle-helper 并写入 /etc/sudoers.d/caffeinate-toggle
//   授权本用户 NOPASSWD 调用它；之后所有开关都走 `sudo -n 辅助脚本`，**不再弹窗**。
//
// 踩过的坑：
//   1. pmset disablesleep 在 Apple Silicon / macOS 27 上已失效，别再试
//   2. nohup+disown 挡不住登录会话销毁，已弃用
//   3. gui 域 bootstrap 在本机被禁（I/O error），改为 system 域 + sudoers 免密
//   4. bootstrap 进 system 域要求 plist 归 root:wheel，否则 Bootstrap failed: 5

let LABEL = "com.think.caffeinate"
let PLIST_RESOURCE = "com.think.caffeinate"
let HELPER = "/usr/local/bin/caffeinate-toggle-helper"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var powerLine: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var lastSleepItem: NSMenuItem!
    private var lastWakeItem: NSMenuItem!
    private var recentItem: NSMenuItem!
    private var sleepInfoItem: NSMenuItem!
    private var othersItem: NSMenuItem!
    private var autostartItem: NSMenuItem!
    private var isOn = false
    private var child: Process?

    // 休眠信息缓存：pmset -g log 约 6 秒，绝不能在主线程跑（会卡住菜单）。
    private var cachedSleep: SleepInfo = .empty
    private var lastSleepFetch: Date = .distantPast
    private var sleepFetchInProgress = false
    // 最近一次探测到的「其他进程防睡持有者」，供「一键结束」用
    private var currentHolders: [Holder] = []

    private var guiDomain: String { "gui/\(getuid())/\(LABEL)" }
    private var systemDomain: String { "system/\(LABEL)" }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ note: Notification) {
        // 单实例：重复双击只唤醒已有实例
        let bid = Bundle.main.bundleIdentifier ?? ""
        if !bid.isEmpty,
           NSRunningApplication.runningApplications(withBundleIdentifier: bid).count > 1 {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = makeIcon(on: false)
            button.imagePosition = .imageOnly
            button.toolTip = "休眠助手（点击切换）"
        }

        buildMenu()
        refresh()
        // 休眠信息较重（pmset -g log 约 6s），放后台拉取 + 定时刷新，绝不阻塞 UI
        fetchSleepInBackground()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchSleepInBackground()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        statusLine = NSMenuItem(title: "状态：检测中…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        powerLine = NSMenuItem(title: "电源：检测中…", action: nil, keyEquivalent: "")
        powerLine.isEnabled = false
        menu.addItem(powerLine)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "开启不休眠", action: #selector(toggle), keyEquivalent: "o")
        toggleItem.target = self
        menu.addItem(toggleItem)

        autostartItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleAutostart), keyEquivalent: "")
        autostartItem.target = self
        menu.addItem(autostartItem)

        menu.addItem(.separator())

        // 休眠信息收进子菜单，避免长文本把主菜单撑宽
        lastSleepItem = NSMenuItem(title: "上次休眠：…", action: nil, keyEquivalent: "")
        lastSleepItem.isEnabled = false
        lastWakeItem = NSMenuItem(title: "上次唤醒：…", action: nil, keyEquivalent: "")
        lastWakeItem.isEnabled = false
        recentItem = NSMenuItem(title: "最近休眠记录", action: nil, keyEquivalent: "")
        recentItem.submenu = NSMenu()
        sleepInfoItem = NSMenuItem(title: "最近休眠信息", action: nil, keyEquivalent: "")
        sleepInfoItem.submenu = NSMenu()
        let sleepSub = sleepInfoItem.submenu!
        sleepSub.addItem(lastSleepItem)
        sleepSub.addItem(lastWakeItem)
        sleepSub.addItem(.separator())
        sleepSub.addItem(recentItem)
        menu.addItem(sleepInfoItem)

        othersItem = NSMenuItem(title: "其他进程防睡 (0)", action: nil, keyEquivalent: "")
        othersItem.submenu = NSMenu()
        menu.addItem(othersItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // 每次打开菜单都重新探测：自己的状态 + 别人的断言
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - 切换

    @objc private func toggle() {
        if isOn { disable() } else { enable() }
    }

    @objc private func quitApp() {
        // 由 launchd 持有的任务，退出应用不会自动结束它；若为应用内进程则会随退出结束。
        // 不区分清楚，用户会误以为「关了应用就恢复休眠了」——必须显式确认。
        guard isOn else {
            NSApp.terminate(nil)
            return
        }

        let heldByLaunchd = jobRunningIn(systemDomain) || jobRunningIn(guiDomain)
        let alert = NSAlert()
        alert.messageText = "退出休眠助手"
        alert.informativeText = heldByLaunchd
            ? "当前处于不休眠状态，任务由系统 launchd 持有，退出应用后仍会继续。是否同时结束不休眠？"
            : "当前处于不休眠状态（由本应用内的进程维持），退出应用即会结束。是否直接退出？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "结束不休眠并退出")
        alert.addButton(withTitle: "保留不休眠，仅退出")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            disable()
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private func enable() {
        if jobRunning() { refresh(); return }
        // 首选：launchd system 域（免密 sudo，退出 app 后仍生效、合盖也有效）
        if enableViaSudo() { refresh(); return }
        // 兜底：直接把 caffeinate 作为子进程拉起（同样免密，随本 app 生命周期）
        startChildCaffeinate()
        refresh()
    }

    private func disable() {
        stopChildCaffeinate()
        _ = disableViaSudo()
        // 清理可能存在的历史 launchd 任务
        _ = run("/bin/launchctl", ["bootout", systemDomain])
        _ = run("/bin/launchctl", ["bootout", guiDomain])
        _ = run("/usr/bin/pkill", ["-x", "caffeinate"])
        refresh()
    }

    // MARK: - 免密 sudo（system 域 + sudoers 授权）

    private func enableViaSudo() -> Bool {
        guard let src = Bundle.main.path(forResource: PLIST_RESOURCE, ofType: "plist") else { return false }
        let (status, _) = run("/usr/bin/sudo", ["-n", HELPER, "enable", src])
        return status == 0
    }

    private func disableViaSudo() -> Bool {
        let (status, _) = run("/usr/bin/sudo", ["-n", HELPER, "disable"])
        return status == 0
    }

    // MARK: - 兜底：应用内子进程 caffeinate（无需任何授权）

    private func startChildCaffeinate() {
        stopChildCaffeinate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-i", "-m", "-s"]
        do {
            try p.run()
            child = p
        } catch {
            child = nil
            showError("开启失败：\(error.localizedDescription)")
        }
    }

    private func stopChildCaffeinate() {
        if let c = child, c.isRunning { c.terminate() }
        child = nil
    }

    // MARK: - 状态探测

    private func jobRunningIn(_ domain: String) -> Bool {
        let (status, _) = run("/bin/launchctl", ["print", domain])
        return status == 0
    }

    private func jobRunning() -> Bool {
        if let c = child, c.isRunning { return true }
        return jobRunningIn(guiDomain) || jobRunningIn(systemDomain)
    }

    // MARK: - 读取其他进程的防睡断言

    private struct Holder {
        let pid: String
        let name: String
        var types: [String] = []
        var detail: String = ""
    }

    private func readOtherHolders() -> [Holder] {
        let (_, text) = run("/usr/bin/pmset", ["-g", "assertions"])
        guard !text.isEmpty else { return [] }

        // 形如： pid 20617(UURemote): [0x...] 38:13:13 PreventUserIdleSystemSleep named: "..."
        let pattern = "pid\\s+([0-9]+)\\(([^)]+)\\).*?\\b(Prevent[A-Za-z]+|NoIdleSleepAssertion)\\s+named:\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        var byPid: [String: Holder] = [:]
        for m in regex.matches(in: text, range: range) {
            let pid = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2))
            let type = ns.substring(with: m.range(at: 3))
            let detail = ns.substring(with: m.range(at: 4))
            if name == "caffeinate" { continue }   // 本应用自己，不算「其他」
            if var h = byPid[pid] {
                if !h.types.contains(type) { h.types.append(type) }
                if h.detail.isEmpty { h.detail = detail }
                byPid[pid] = h
            } else {
                byPid[pid] = Holder(pid: pid, name: name, types: [type], detail: detail)
            }
        }
        return byPid.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func friendlyType(_ t: String) -> String {
        switch t {
        case "PreventSystemSleep": return "阻止系统休眠"
        case "PreventUserIdleSystemSleep": return "阻止闲置休眠"
        case "PreventDiskIdle": return "阻止磁盘休眠"
        case "PreventUserIdleDisplaySleep": return "阻止显示器休眠"
        default: return t
        }
    }

    // MARK: - 刷新

    private func refresh() {
        isOn = jobRunning()
        let holders = readOtherHolders()
        currentHolders = holders

        // 状态行：即使本应用关闭，若仍有其他进程持有防睡断言，
        // 机器实际并不会休眠（闲置不会睡），需如实说明。
        if isOn {
            statusLine.title = "● 不休眠中"
            toggleItem.title = "结束不休眠（恢复正常休眠）"
        } else if holders.isEmpty {
            statusLine.title = "○ 正常休眠"
            toggleItem.title = "开启不休眠"
        } else {
            statusLine.title = "○ 正常休眠 · \(holders.count) 进程阻止休眠"
            toggleItem.title = "开启不休眠"
        }
        statusItem.button?.image = makeIcon(on: isOn)
        powerLine.title = readPowerStatus()

        autostartItem.state = autostartEnabled() ? .on : .off

        othersItem.title = "其他进程防睡 (\(holders.count))"
        let sub = NSMenu()
        if holders.isEmpty {
            let none = NSMenuItem(title: "无", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for h in holders {
                let item = NSMenuItem(
                    title: "\(h.name) · \(h.types.map { friendlyType($0) }.joined(separator: "、"))",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                item.toolTip = "pid \(h.pid) — \(h.detail)"
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let release = NSMenuItem(
                title: "⚠️ 结束这些进程以释放防睡",
                action: #selector(releaseOtherAssertions),
                keyEquivalent: ""
            )
            release.target = self
            sub.addItem(release)
        }
        othersItem.submenu = sub

        // 休眠信息用缓存即时渲染；真正的 pmset -g log 在后台拉取（避免卡住菜单）
        applySleepInfo(cachedSleep)
        fetchSleepInBackground()
    }

    // MARK: - 一键结束其他进程的防睡断言

    @objc private func releaseOtherAssertions() {
        let holders = currentHolders
        guard !holders.isEmpty else { return }
        let names = Set(holders.map { $0.name }).sorted().joined(separator: "、")

        let alert = NSAlert()
        alert.messageText = "结束其他进程的防睡"
        alert.informativeText = "将结束：\(names)。\n\n防睡断言只能由持有它的进程释放——结束进程即释放。⚠️ 结束远程控制类进程（如 UURemote）会导致远程连接中断。确定继续？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "结束并释放")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for h in holders {
            if let pid = Int32(h.pid) { kill(pid, SIGTERM) }
        }
        // 稍等再补一刀，确保断言释放
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            for h in holders {
                if let pid = Int32(h.pid) { kill(pid, SIGKILL) }
            }
            self?.refresh()
        }
    }

    // MARK: - 电源 / 电量 / 合盖状态

    private func readPowerStatus() -> String {
        // 电源与电量
        var parts: [String] = []
        let (_, batt) = run("/usr/bin/pmset", ["-g", "batt"])
        if batt.contains("AC Power") {
            parts.append("AC")
        } else if batt.contains("Battery Power") {
            parts.append("电池")
        }
        if let r = batt.range(of: "(\\d+)%", options: .regularExpression) {
            let pct = batt[r].replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "(", with: "")
            parts.append("电量 \(pct)%")
        }
        // 合盖状态（Yes=合盖, No=开盖）
        let (_, ioreg) = run("/usr/sbin/ioreg", ["-r", "-d", "1", "-n", "IOPMrootDomain"])
        if ioreg.contains("\"AppleClamshellState\" = Yes") {
            parts.append("已合盖")
        } else if ioreg.contains("AppleClamshellState") {
            parts.append("已开盖")
        }
        return parts.isEmpty ? "电源：未知" : parts.joined(separator: " · ")
    }

    // MARK: - 开机自动启动（登录项）

    private var autostartPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.think.caffeinate.autostart.plist")
    }

    private func autostartEnabled() -> Bool {
        FileManager.default.fileExists(atPath: autostartPlistURL.path)
    }

    @objc private func toggleAutostart() {
        if autostartEnabled() {
            do {
                try FileManager.default.removeItem(at: autostartPlistURL)
            } catch {
                showError("关闭自启动失败：\(error.localizedDescription)")
            }
            // 让 launchd 忘记该 agent
            _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/com.think.caffeinate.autostart"])
        } else {
            let exe = Bundle.main.executablePath ?? ""
            guard !exe.isEmpty else {
                showError("无法定位应用可执行文件，设置失败")
                return
            }
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>com.think.caffeinate.autostart</string>
              <key>ProgramArguments</key><array><string>\(exe)</string></array>
              <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            do {
                try plist.write(to: autostartPlistURL, atomically: true, encoding: .utf8)
                _ = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", autostartPlistURL.path])
            } catch {
                showError("开启自启动失败：\(error.localizedDescription)")
            }
        }
        refresh()
    }

    // MARK: - 休眠信息：缓存渲染 + 后台拉取

    /// 后台拉取 pmset 休眠/唤醒信息（约 6s），完成后回主线程更新菜单。
    private func fetchSleepInBackground(minInterval: TimeInterval = 15) {
        guard !sleepFetchInProgress else { return }
        guard Date().timeIntervalSince(lastSleepFetch) >= minInterval else { return }
        sleepFetchInProgress = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let info = self.readSleepWake()
            DispatchQueue.main.async {
                self.sleepFetchInProgress = false
                self.lastSleepFetch = Date()
                self.cachedSleep = info
                self.applySleepInfo(info)
            }
        }
    }

    private func applySleepInfo(_ sw: SleepInfo) {
        if let ls = sw.lastSleep {
            var s = "上次休眠：\(relative(ls.date))（\(shortTime(ls.date)) · \(friendlySleepReason(ls.reason, dark: ls.isDarkWake))"
            if let c = ls.charge { s += " · 电量 \(c)%" }
            if let d = ls.durationSecs, d > 0 { s += " · 睡 \(formatDuration(d))" }
            s += "）"
            lastSleepItem.title = s
        } else {
            lastSleepItem.title = "上次休眠：无记录"
        }
        if let lw = sw.lastWake {
            lastWakeItem.title = "上次唤醒：\(relative(lw))（\(shortTime(lw))）"
        } else {
            lastWakeItem.title = "上次唤醒：无记录"
        }
        let sub2 = NSMenu()
        if sw.recent.isEmpty {
            let none = NSMenuItem(title: "无", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub2.addItem(none)
        } else {
            for ev in sw.recent {
                var t = "\(shortDateTime(ev.date)) · \(friendlySleepReason(ev.reason, dark: ev.isDarkWake))"
                if let c = ev.charge { t += " · 电量 \(c)%" }
                if let d = ev.durationSecs, d > 0 { t += " · 睡 \(formatDuration(d))" }
                let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                it.isEnabled = false
                sub2.addItem(it)
            }
        }
        recentItem.title = "最近休眠记录 (\(sw.recent.count))"
        recentItem.submenu = sub2
    }

    // MARK: - 读最近休眠 / 唤醒记录

    private struct SleepEvent {
        let date: Date
        let reason: String
        let isDarkWake: Bool
        let charge: Int?
        let durationSecs: Int?
    }

    private struct SleepInfo {
        let lastSleep: SleepEvent?
        let lastWake: Date?
        let recent: [SleepEvent]
        static let empty = SleepInfo(lastSleep: nil, lastWake: nil, recent: [])
    }

    /// 返回：上次休眠、上次唤醒、最近若干次休眠（新→旧）
    private func readSleepWake() -> SleepInfo {
        // 只取含休眠/唤醒关键字的行，并截尾以控制体量
        let cmd = "pmset -g log | grep -E 'Entering (Sleep|DarkWake) state due to|WakeTime:' | tail -4000"
        let (_, text) = run("/bin/sh", ["-c", cmd])
        guard !text.isEmpty else { return .empty }

        let df = makePMDateFormatter()
        var sleeps: [SleepEvent] = []
        var lastWake: Date?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.contains("WakeTime:") {
                if let d = parsePMDate(line, df: df) { lastWake = d }
                continue
            }
            if let ev = parseSleepLine(line, df: df) {
                sleeps.append(ev)
            }
        }

        let recent = sleeps.suffix(8).reversed()
        return SleepInfo(lastSleep: sleeps.last, lastWake: lastWake, recent: Array(recent))
    }

    private func parseSleepLine(_ line: String, df: DateFormatter) -> SleepEvent? {
        let pat = #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \+\d{4})\s+Sleep\s+Entering (Sleep|DarkWake) state due to '([^']+)'"#
        guard let r = try? NSRegularExpression(pattern: pat),
              let m = r.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        let ns = line as NSString
        let ts = ns.substring(with: m.range(at: 1))
        let state = ns.substring(with: m.range(at: 2))
        let reason = ns.substring(with: m.range(at: 3))
        guard let date = df.date(from: ts) else { return nil }

        var charge: Int?
        if let cm = try? NSRegularExpression(pattern: #"\(Charge:(\d+)%\)"#)
            .firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            charge = Int(ns.substring(with: cm.range(at: 1)))
        }
        var dur: Int?
        if let dm = try? NSRegularExpression(pattern: #"(\d+) secs"#)
            .firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            dur = Int(ns.substring(with: dm.range(at: 1)))
        }
        return SleepEvent(date: date, reason: reason,
                          isDarkWake: state == "DarkWake",
                          charge: charge, durationSecs: dur)
    }

    private func parsePMDate(_ line: String, df: DateFormatter) -> Date? {
        let pat = #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \+\d{4})"#
        guard let r = try? NSRegularExpression(pattern: pat),
              let m = r.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return df.date(from: (line as NSString).substring(with: m.range(at: 1)))
    }

    private func makePMDateFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return df
    }

    private func friendlySleepReason(_ r: String, dark: Bool) -> String {
        let base: String
        switch r {
        case "Clamshell Sleep": base = "合盖"
        case "Maintenance Sleep": base = "维护"
        case "Idle Sleep": base = "闲置"
        case "Sleep": base = "休眠"
        default: base = r
        }
        return dark ? "\(base)·暗唤醒" : base
    }

    private func relative(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 0 { return "刚刚" }
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(Int(secs / 60)) 分钟前" }
        if secs < 86400 { return "\(Int(secs / 3600)) 小时前" }
        return "\(Int(secs / 86400)) 天前"
    }

    private func formatDuration(_ s: Int) -> String {
        if s < 60 { return "\(s) 秒" }
        let m = s / 60, r = s % 60
        return r == 0 ? "\(m) 分" : "\(m) 分 \(r) 秒"
    }

    private func shortTime(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "HH:mm"
        return df.string(from: d)
    }

    private func shortDateTime(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: d)
    }

    // MARK: - 工具

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "休眠助手"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 图标

    private func makeIcon(on: Bool) -> NSImage {
        // 休眠助手：弯月图标。flipped:true 贴合菜单栏翻转上下文，
        // 避免被上下镜像（旧版咖啡杯倒置后热气和杯把交叉形成「叉号」伪影）。
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.clear.set()
            rect.fill()
            self.drawMoon(on: on)
            return true
        }
        return image
    }

    private func drawMoon(on: Bool) {
        // 弯月 = 外圆 − 偏移内圆。先填外圆，再用 clear 合成把内圆擦成透明，
        // 得到干净月牙（even-odd / 反向路径在 AppKit 里会被归一化，不可靠）。
        let R: CGFloat = 7.0      // 外圆半径
        let rIn: CGFloat = 6.2    // 内圆略小，才会切出细月牙
        let outerC = NSPoint(x: 9.0, y: 9.0)
        let innerC = NSPoint(x: 11.9, y: 6.1)   // 右上偏移 → 左下弯月

        func disk(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        let fill: NSColor = on
            ? NSColor(calibratedRed: 1.00, green: 0.70, blue: 0.16, alpha: 1)
            : NSColor(calibratedWhite: 0.45, alpha: 1)
        fill.setFill()
        disk(outerC, R).fill()

        if let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            ctx.compositingOperation = .clear
            NSColor.black.setFill()
            disk(innerC, rIn).fill()
            ctx.restoreGraphicsState()
        }
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
