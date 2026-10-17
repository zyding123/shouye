//  LidGuard (守夜) — Mac 合盖不休眠开关
//  只做一件事：通过 macOS 自带的 pmset 开关，让合盖不进入休眠；
//  并保证任何情况下退出后都恢复成系统默认（合盖即休眠）。
//
//  三重保险：
//   1. 正常退出（Cmd+Q / 菜单退出 / 注销）→ 同步恢复默认
//   2. 看门狗进程：主进程被强杀或崩溃 → 1 秒内自动恢复默认
//   3. 电量低于阈值且未接电源 → 自动恢复默认

import Cocoa
import IOKit

// MARK: - 常量

let kGrantPath   = "/etc/sudoers.d/lidguard-disablesleep"
let kPmset       = "/usr/bin/pmset"
let kSudo        = "/usr/bin/sudo"
let kVisudo      = "/usr/sbin/visudo"
let kWatchTag    = "lidguard-watchdog"
let kWatchPidFile = NSHomeDirectory() + "/.lidguard/watchdog.pid"
let kLoginAgent  = NSHomeDirectory() + "/Library/LaunchAgents/com.aries.lidguard.plist"

// MARK: - 进程身份校验（用于精确识别自己的看门狗，绝不误伤别的进程）
// proc_pidpath 由系统 libproc 提供，可直接调用

func executablePath(of pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let size = buf.count
    let n = buf.withUnsafeMutableBufferPointer { base -> Int32 in
        guard let p = base.baseAddress else { return -1 }
        return proc_pidpath(pid, p, UInt32(size))
    }
    guard n > 0 else { return nil }
    return String(cString: buf)
}

func isAlive(_ pid: Int32) -> Bool {
    return kill(pid, 0) == 0
}

func selfExecutablePath() -> String {
    return Bundle.main.executablePath ?? CommandLine.arguments[0]
}

func isOneOfOurProcesses(_ pid: Int32) -> Bool {
    guard pid > 1, pid != getpid(), isAlive(pid) else { return false }
    return executablePath(of: pid) == selfExecutablePath()
}

let kPrefAutoEnable = "autoEnableOnLaunch"
let kPrefLogin      = "startAtLogin"
let kPrefFloor      = "batteryFloor"
let kPrefLockOnLid  = "lockOnLidClose"      // 合盖时自动锁屏
let kPrefOffDelay   = "displayOffDelay"     // 锁屏后多少秒息屏；-1 = 不自动息屏

let defaults = UserDefaults.standard

// MARK: - 进程执行helper

func runTask(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch {
        return (-1, "无法执行 \(path)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func shellLine(_ s: String) -> String {
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - 事件日志（落盘，方便事后排查；系统统一日志在本机不方便查）

let kEventLog = NSHomeDirectory() + "/.lidguard/events.log"

func tsNow() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date())
}

func logEvent(_ msg: String) {
    NSLog("LidGuard: %@", msg)
    let line = "\(tsNow())  \(msg)\n"
    let dir = (kEventLog as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let h = FileHandle(forWritingAtPath: kEventLog) {
        h.seekToEndOfFile()
        if let d = line.data(using: .utf8) { h.write(d) }
        h.closeFile()
    } else {
        try? line.write(toFile: kEventLog, atomically: true, encoding: .utf8)
    }
}

// 回读系统真实状态：pmset -g 无需管理员权限即可读取 SleepDisabled
func currentSleepDisabled() -> Bool? {
    let (code, out) = runTask(kPmset, ["-g"])
    guard code == 0 else { return nil }
    for raw in out.split(separator: "\n") {
        let line = shellLine(String(raw))
        if line.hasPrefix("SleepDisabled") { return line.contains("1") }
    }
    return nil
}

// MARK: - 合盖状态、锁屏、息屏

/// 直接向 IOKit 读取「盖子是否合上」。不起子进程、不联网、只读。
func isLidClosed() -> Bool? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let prop = IORegistryEntryCreateCFProperty(service,
                                                     "AppleClamshellState" as CFString,
                                                     kCFAllocatorDefault, 0) else { return nil }
    let value = prop.takeRetainedValue()
    if let n = value as? NSNumber { return n.boolValue }
    if let b = value as? Bool { return b }
    return nil
}

/// 进入真正的锁屏（弹出密码输入界面），与按电源键锁屏效果一致。
///
/// 实现说明：调用系统 login.framework 的 SACLockScreenImmediate。
/// 关键坑：这个框架的二进制**只存在于 dyld 系统缓存里，磁盘上并没有文件**
/// （`ls` 会显示断链、`nm` 也读不到符号），所以**不能用"文件是否存在"来判断接口有没有**——
/// 必须直接 dlopen 让它走缓存解析。本机已实测：dlopen 成功、符号存在。
private let kLoginFwPath = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
private typealias SACLockScreenImmediateFn = @convention(c) () -> Int32
private var loginFrameworkHandle: UnsafeMutableRawPointer?

@discardableResult
func lockScreenNow() -> Bool {
    if loginFrameworkHandle == nil {
        loginFrameworkHandle = dlopen(kLoginFwPath, RTLD_LAZY)
    }
    if let h = loginFrameworkHandle, let sym = dlsym(h, "SACLockScreenImmediate") {
        let fn = unsafeBitCast(sym, to: SACLockScreenImmediateFn.self)
        let r = fn()
        NSLog("LidGuard: 已调用真锁屏接口，返回 %d", r)
        return true
    }
    // 极端情况下的兜底：直接息屏。唤醒后同样是登录界面，不会出现屏保。
    NSLog("LidGuard: 锁屏接口不可用，退回到「直接息屏」")
    return displayOffNow().ok
}

/// 查询系统当前是否处于锁屏状态（只读）
func isScreenLocked() -> Bool? {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
    if let b = dict["CGSSessionScreenIsLocked"] as? Bool { return b }
    return nil
}

/// 关闭显示器（真·息屏）。优先免密码执行，失败再尝试走已授权的 sudo。
@discardableResult
func displayOffNow() -> (ok: Bool, msg: String) {
    let a = runTask(kPmset, ["displaysleepnow"])
    if a.code == 0 { return (true, "") }
    let b = runTask(kSudo, ["-n", kPmset, "displaysleepnow"])
    if b.code == 0 { return (true, "") }
    let msg = (shellLine(a.out) + " | " + shellLine(b.out))
        .trimmingCharacters(in: CharacterSet(charactersIn: " |"))
    return (false, msg)
}

// MARK: - 主控制器

final class LidGuard: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var menu: NSMenu!

    var statusLine: NSMenuItem!
    var toggleItem: NSMenuItem!
    var autoEnableItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var batteryItem: NSMenuItem!
    var lockOnLidItem: NSMenuItem!
    var offDelayItem: NSMenuItem!
    var fixAuthItem: NSMenuItem!

    var isOn = false            // 当前系统实际状态：合盖不休眠是否开启
    var authorized = false      // 是否已安装权限授权
    var watchdog: Process?
    var batteryTimer: Timer?
    var lidTimer: Timer?
    var lastLidClosed: Bool?
    var pendingDisplayOff: Timer?
    var healthTimer: Timer?

    // ---------- 生命周期 ----------

    func applicationDidFinishLaunching(_ note: Notification) {
        buildStatusItem()
        buildMenu()

        refreshAuthorized()
        syncStateFromSystem()

        logEvent("—— 启动（参数: \(CommandLine.arguments.dropFirst().joined(separator: " "))，"
                 + "授权=\(authorized ? "有" : "无")，"
                 + "当前 SleepDisabled=\(currentSleepDisabled().map { $0 ? "1" : "0" } ?? "?")，"
                 + "盖子=\(isLidClosed().map { $0 ? "合" : "开" } ?? "?")）")

        if defaults.bool(forKey: kPrefAutoEnable, defaultValue: true) {
            if authorized {
                enableAtLaunch(attemptsLeft: 5)
            } else if askToInstallGrant() {
                _ = enableMode()
            }
        }

        startBatteryTimer()
        startLidTimer()
        startHealthTimer()
        refreshUI()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        restoreToDefault(reason: "退出")
        return .terminateNow
    }

    func applicationWillTerminate(_ note: Notification) {
        restoreToDefault(reason: "退出")
    }

    // ---------- 菜单栏 ----------

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
    }

    func makeStatusImage(on: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18))
        img.lockFocus()
        NSColor.black.set()

        // 合上的笔记本：机身
        let body = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 6.0, width: 11.0, height: 7.5),
                                xRadius: 1.6, yRadius: 1.6)
        body.lineWidth = 1.4
        body.stroke()

        // 底座边
        let lip = NSBezierPath()
        lip.move(to: NSPoint(x: 1.0, y: 4.2))
        lip.line(to: NSPoint(x: 15.0, y: 4.2))
        lip.lineWidth = 1.4
        lip.lineCapStyle = .round
        lip.stroke()

        // 状态徽标：实心 = 守夜中，空心 = 会休眠
        let badgeRect = NSRect(x: 13.4, y: 9.6, width: 4.6, height: 4.6)
        let badge = NSBezierPath(ovalIn: badgeRect)
        if on {
            badge.fill()
        } else {
            badge.lineWidth = 1.3
            badge.stroke()
        }

        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    func buildMenu() {
        menu = NSMenu()

        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(NSMenuItem.separator())

        toggleItem = NSMenuItem(title: "", action: #selector(onToggle), keyEquivalent: "t")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        autoEnableItem = NSMenuItem(title: "打开本工具时自动开启", action: #selector(onToggleAutoEnable), keyEquivalent: "")
        autoEnableItem.target = self
        menu.addItem(autoEnableItem)

        loginItem = NSMenuItem(title: "登录时自动启动", action: #selector(onToggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        batteryItem = NSMenuItem(title: "电量低时自动恢复", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [0, 10, 20, 30] {
            let t = v == 0 ? "关闭（不自动恢复）" : "低于 \(v)% 时自动恢复"
            let it = NSMenuItem(title: t, action: #selector(onSetFloor(_:)), keyEquivalent: "")
            it.target = self
            it.tag = v
            sub.addItem(it)
        }
        batteryItem.submenu = sub
        menu.addItem(batteryItem)

        menu.addItem(NSMenuItem.separator())

        lockOnLidItem = NSMenuItem(title: "合盖时自动锁屏", action: #selector(onToggleLockOnLid), keyEquivalent: "")
        lockOnLidItem.target = self
        menu.addItem(lockOnLidItem)

        offDelayItem = NSMenuItem(title: "锁屏后息屏", action: nil, keyEquivalent: "")
        let offSub = NSMenu()
        for (title, secs) in [("立即息屏", 0), ("15 秒后", 15), ("30 秒后", 30),
                              ("1 分钟后", 60), ("3 分钟后", 180), ("不自动息屏", -1)] {
            let it = NSMenuItem(title: title, action: #selector(onSetOffDelay(_:)), keyEquivalent: "")
            it.target = self
            it.tag = secs
            offSub.addItem(it)
        }
        offDelayItem.submenu = offSub
        menu.addItem(offDelayItem)

        let testItem = NSMenuItem(title: "立即测试：锁屏 + 息屏", action: #selector(onTestLockNow), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(NSMenuItem.separator())

        let about = NSMenuItem(title: "它是怎么做到安全的…", action: #selector(onAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        fixAuthItem = NSMenuItem(title: "重新安装权限授权…", action: #selector(onFixAuth), keyEquivalent: "")
        fixAuthItem.target = self
        menu.addItem(fixAuthItem)

        let logItem = NSMenuItem(title: "查看运行记录…", action: #selector(onShowLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出（并恢复合盖休眠）", action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // ---------- 状态 ----------

    func syncStateFromSystem() {
        isOn = currentSleepDisabled() ?? false
    }

    func refreshAuthorized() {
        authorized = FileManager.default.fileExists(atPath: kGrantPath)
    }

    func refreshUI() {
        if let b = statusItem.button {
            b.image = makeStatusImage(on: isOn)
            b.title = isOn ? " 守夜" : " 休眠"
            b.toolTip = isOn ? "合盖不休眠：已开启" : "已恢复系统默认：合盖会休眠"
        }

        if isOn {
            statusLine.title = "状态：守夜中 — 合盖不会休眠"
            toggleItem.title = "暂停（恢复合盖休眠）"
        } else {
            statusLine.title = "状态：系统默认 — 合盖会休眠"
            toggleItem.title = "开启合盖不休眠"
        }

        autoEnableItem.state = defaults.bool(forKey: kPrefAutoEnable, defaultValue: true) ? .on : .off
        loginItem.state = defaults.bool(forKey: kPrefLogin, defaultValue: false) ? .on : .off

        let floor = defaults.integer(forKey: kPrefFloor)
        let shown = (floor == 0 && !defaults.bool(forKey: "floorSet")) ? 20 : floor
        batteryItem.title = shown == 0 ? "电量低时自动恢复：关闭" : "电量低时自动恢复：低于 \(shown)%"
        if let sub = batteryItem.submenu {
            for it in sub.items { it.state = (it.tag == shown) ? .on : .off }
        }

        lockOnLidItem.state = defaults.bool(forKey: kPrefLockOnLid, defaultValue: true) ? .on : .off
        let offDelay = effectiveOffDelay()
        let offTitle: String
        switch offDelay {
        case -1:  offTitle = "不自动息屏"
        case 0:   offTitle = "立即息屏"
        case 60:  offTitle = "1 分钟后"
        case 180: offTitle = "3 分钟后"
        default:  offTitle = "\(offDelay) 秒后"
        }
        offDelayItem.title = "合盖后息屏：\(offTitle)"
        if let sub = offDelayItem.submenu {
            for it in sub.items { it.state = (it.tag == offDelay) ? .on : .off }
        }

        fixAuthItem.isHidden = authorized
    }

    // MARK: - 开启 / 恢复

    func applySleepDisabled(_ on: Bool) -> Bool {
        let (code, out) = runTask(kSudo, ["-n", kPmset, "-a", "disablesleep", on ? "1" : "0"])
        if code != 0 {
            logEvent("pmset 执行失败（退出码 \(code)）：\(shellLine(out))")
            return false
        }
        return true
    }

    @discardableResult
    func enableMode(silent: Bool = false) -> Bool {
        refreshAuthorized()
        if !authorized {
            if silent {
                logEvent("未安装权限授权，开机自动开启跳过（需要手动授权一次）")
                return false
            }
            if !askToInstallGrant() { return false }
        }
        guard applySleepDisabled(true) else {
            refreshAuthorized()
            if !silent {
                alert("开启失败",
                      authorized
                      ? "系统拒绝了这条命令，请稍后重试。"
                      : "权限授权似乎已被移除，请用菜单里的「重新安装权限授权…」修复。")
            }
            return false
        }
        // 回读确认；不对就再补一次
        if currentSleepDisabled() != true {
            usleep(300_000)
            _ = applySleepDisabled(true)
        }
        isOn = true
        startWatchdog()
        logEvent("已开启合盖不休眠（回读 SleepDisabled=\(currentSleepDisabled().map { $0 ? "1" : "0" } ?? "?")）")
        refreshUI()
        return true
    }

    /// 启动时的开启流程：失败会自己重试，不会像以前那样失败一次就永远不管
    func enableAtLaunch(attemptsLeft: Int) {
        logEvent("尝试开启（剩余重试 \(attemptsLeft) 次）")
        if enableMode(silent: true) { return }
        if attemptsLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.enableAtLaunch(attemptsLeft: attemptsLeft - 1)
            }
        } else {
            logEvent("多次重试仍未成功，转入自动巡检（每 15 秒会再试一次）")
        }
    }

    /// 健康巡检：发现系统状态和预期不一致就自动修回来
    func healthCheck() {
        guard isOn else { return }
        guard let actual = currentSleepDisabled() else { return }
        if actual != true {
            logEvent("⚠️ 巡检发现系统开关被改回关闭状态，正在自动恢复")
            if applySleepDisabled(true) {
                logEvent("已自动恢复（SleepDisabled=1）")
            } else {
                logEvent("自动恢复失败，下个周期继续重试")
            }
            refreshUI()
        } else if watchdog == nil || !(watchdog?.isRunning ?? false) {
            logEvent("⚠️ 巡检发现看门狗不在，正在重新拉起")
            startWatchdog()
        }
    }

    func startHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.healthCheck()
        }
    }

    func disableMode(reason: String) {
        cancelPendingDisplayOff()
        _ = applySleepDisabled(false)
        logEvent("已恢复系统默认（原因：\(reason)）")
        isOn = false
        stopWatchdog()
        refreshUI()
        if reason == "电量" {
            alert("已自动恢复合盖休眠",
                  "电量已低于你设定的阈值，且当前没有接电源。\n\n"
                  + "已把这个开关关掉，避免把电池跑干。接上电源后可以再从菜单开启。")
        }
    }

    func restoreToDefault(reason: String) {
        cancelPendingDisplayOff()
        if isOn || FileManager.default.fileExists(atPath: kGrantPath) {
            _ = applySleepDisabled(false)
            logEvent("退出时已恢复系统默认（\(reason)）")
        }
        isOn = false
        stopWatchdog()
    }

    // MARK: - 看门狗（强杀兜底）

    func startWatchdog() {
        stopWatchdog()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: selfExecutablePath())
        p.arguments = ["--watchdog", "\(getpid())"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            watchdog = p
            let dir = (kWatchPidFile as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? "\(p.processIdentifier)".write(toFile: kWatchPidFile, atomically: true, encoding: .utf8)
        } catch {
            watchdog = nil
        }
    }

    // 按进程号精确清除，并校验确实是我们自己的进程，不做任何模糊匹配
    func stopWatchdog() {
        if let w = watchdog, w.isRunning { w.terminate() }
        watchdog = nil
        if let txt = try? String(contentsOfFile: kWatchPidFile, encoding: .utf8),
           let pid = Int32(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
           isOneOfOurProcesses(pid) {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(atPath: kWatchPidFile)
    }

    // MARK: - 电量监控

    func startBatteryTimer() {
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkBattery()
        }
    }

    func checkBattery() {
        guard isOn else { return }
        let floor = effectiveFloor()
        guard floor > 0 else { return }

        let (code, out) = runTask(kPmset, ["-g", "batt"])
        guard code == 0 else { return }
        let onBattery = out.contains("Battery Power")
        guard onBattery else { return }

        var percent: Int?
        if let r = out.range(of: #"([0-9]{1,3})%"#, options: .regularExpression) {
            percent = Int(out[r].dropLast())
        }
        if let pct = percent, pct <= floor {
            disableMode(reason: "电量")
        }
    }

    func effectiveFloor() -> Int {
        if defaults.bool(forKey: "floorSet") { return defaults.integer(forKey: kPrefFloor) }
        return 20
    }

    // MARK: - 合盖检测 → 锁屏 → 延迟息屏

    func startLidTimer() {
        lidTimer?.invalidate()
        // 每 2 秒读一次合盖状态（纯内存读取，开销极小）
        lidTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkLid()
        }
    }

    func checkLid() {
        guard let closed = isLidClosed() else { return }
        let prev = lastLidClosed
        lastLidClosed = closed
        if prev == closed { return }
        if closed {
            // 首次读到时盖子就是合着的（例如工具是在合盖状态下被重启的）→ 也照常处理
            handleLidClosed()
        } else if prev != nil {
            handleLidOpened()
        }
    }

    func handleLidClosed() {
        guard isOn else {
            // 这一行以前是静默返回 —— 正是上次"合盖就睡"查不出原因的地方，现在必须留痕
            logEvent("检测到合盖，但守夜未开启（系统 SleepDisabled=\(currentSleepDisabled().map { $0 ? "1" : "0" } ?? "?")）→ 不处理")
            return
        }
        logEvent("检测到合盖（SleepDisabled=1，守夜中）")
        if defaults.bool(forKey: kPrefLockOnLid, defaultValue: true) {
            let ok = lockScreenNow()
            logEvent("合盖 → 锁屏\(ok ? "已触发" : "失败")")
        }
        let delay = effectiveOffDelay()
        guard delay >= 0 else {
            logEvent("合盖 → 按设置不自动息屏")
            return
        }
        pendingDisplayOff?.invalidate()
        pendingDisplayOff = nil
        if delay == 0 {
            fireDisplayOff(trigger: "合盖")
            return
        }
        pendingDisplayOff = Timer.scheduledTimer(withTimeInterval: Double(delay), repeats: false) { [weak self] _ in
            self?.fireDisplayOff(trigger: "合盖后 \(delay) 秒")
        }
        logEvent("合盖 → 将在 \(delay) 秒后息屏")
    }

    func handleLidOpened() {
        if pendingDisplayOff != nil {
            logEvent("盖子已打开 → 取消待执行的息屏")
        }
        pendingDisplayOff?.invalidate()
        pendingDisplayOff = nil
    }

    func fireDisplayOff(trigger: String) {
        pendingDisplayOff?.invalidate()
        pendingDisplayOff = nil
        guard isOn else { return }
        let (ok, msg) = displayOffNow()
        logEvent("\(trigger) → 息屏\(ok ? "成功" : "失败 \(msg)")")
    }

    func effectiveOffDelay() -> Int {
        if defaults.bool(forKey: "offDelaySet") { return defaults.integer(forKey: kPrefOffDelay) }
        return 30
    }

    func cancelPendingDisplayOff() {
        pendingDisplayOff?.invalidate()
        pendingDisplayOff = nil
    }

    // MARK: - 权限授权

    func askToInstallGrant() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "需要一次性授权（只做这一件事）"
        a.informativeText = """
        macOS 只提供了一个受系统保护的开关来实现「合盖不休眠」，这个小工具需要你授权一次，之后就能随时开关、不再反复打扰你。

        授权内容只有两条命令，别的什么都执行不了：
          sudo pmset -a disablesleep 1   ← 开启
          sudo pmset -a disablesleep 0   ← 恢复

        规则写入 /etc/sudoers.d/lidguard-disablesleep，只对当前这一个用户生效。
        想撤销随时说一声，或者删掉该文件即可。

        点「继续」后会弹出系统密码 / Touch ID 窗口。
        """
        a.addButton(withTitle: "继续")
        a.addButton(withTitle: "取消")
        a.alertStyle = .informational
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        return installGrant().ok
    }

    func installGrant() -> (ok: Bool, msg: String) {
        let user = NSUserName()
        let grant = "\(user) ALL=(root) NOPASSWD: \(kPmset) -a disablesleep 0, \(kPmset) -a disablesleep 1\n"
        let tmpSudoers = NSTemporaryDirectory() + "lidguard.sudoers"
        let tmpScript  = NSTemporaryDirectory() + "lidguard-install.sh"

        do { try grant.write(toFile: tmpSudoers, atomically: true, encoding: .utf8) }
        catch { return (false, "无法写入临时文件") }

        let sh = """
        #!/bin/bash
        set -e
        \(kVisudo) -cf "\(tmpSudoers)" >/dev/null
        /usr/bin/install -m 0440 -o root -g wheel "\(tmpSudoers)" "\(kGrantPath)"
        \(kVisudo) -c >/dev/null
        /bin/rm -f "\(tmpSudoers)"
        """
        do { try sh.write(toFile: tmpScript, atomically: true, encoding: .utf8) }
        catch { return (false, "无法写入临时脚本") }
        _ = runTask("/bin/chmod", ["+x", tmpScript])

        let src = "do shell script \"/bin/bash \(tmpScript)\" with administrator privileges"
        let (code, out) = runTask("/usr/bin/osascript", ["-e", src])
        _ = runTask("/bin/rm", ["-f", tmpScript])

        if code != 0 {
            return (false, shellLine(out).isEmpty ? "授权被取消" : shellLine(out))
        }
        refreshAuthorized()
        return (authorized, authorized ? "" : "写入后未找到授权文件")
    }

    // MARK: - 菜单动作

    @objc func onToggle() {
        if isOn { disableMode(reason: "手动") } else { _ = enableMode() }
    }

    @objc func onToggleAutoEnable(_ sender: NSMenuItem) {
        let v = !defaults.bool(forKey: kPrefAutoEnable, defaultValue: true)
        defaults.set(v, forKey: kPrefAutoEnable)
        refreshUI()
    }

    @objc func onToggleLogin(_ sender: NSMenuItem) {
        let v = !defaults.bool(forKey: kPrefLogin, defaultValue: false)
        if setLoginItem(v) {
            defaults.set(v, forKey: kPrefLogin)
        } else {
            alert("设置失败", "没能写入登录启动项，可以稍后再试。")
        }
        refreshUI()
    }

    @objc func onSetFloor(_ sender: NSMenuItem) {
        defaults.set(true, forKey: "floorSet")
        defaults.set(sender.tag, forKey: kPrefFloor)
        refreshUI()
    }

    @objc func onToggleLockOnLid(_ sender: NSMenuItem) {
        let v = !defaults.bool(forKey: kPrefLockOnLid, defaultValue: true)
        defaults.set(v, forKey: kPrefLockOnLid)
        refreshUI()
    }

    @objc func onSetOffDelay(_ sender: NSMenuItem) {
        defaults.set(true, forKey: "offDelaySet")
        defaults.set(sender.tag, forKey: kPrefOffDelay)
        refreshUI()
    }

    /// 手动测试：立刻锁屏 + 立刻息屏。
    /// 成功时故意不弹任何提示 —— 弹窗会把屏幕重新点亮，反而干扰观察。
    @objc func onTestLockNow() {
        cancelPendingDisplayOff()
        let locked = lockScreenNow()
        let (off, msg) = displayOffNow()
        NSLog("LidGuard 手动测试: 锁屏=%@ 息屏=%@ %@", locked ? "ok" : "FAILED", off ? "ok" : "FAILED", msg)
        if !off {
            alert("息屏命令没有成功",
                  "锁屏：\(locked ? "已触发" : "失败")\n息屏：\(msg.isEmpty ? "无返回信息" : msg)\n\n"
                  + "正因为屏幕现在没关掉，你才能看到这条提示。\n"
                  + "如果只是权限问题，告诉我一声，我把授权范围补上。")
        }
    }

    @objc func onFixAuth() {
        if askToInstallGrant() {
            alert("授权完成", "可以正常使用了。")
            _ = enableMode()
        }
        refreshUI()
    }

    @objc func onAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "它是怎么做到安全的"
        a.informativeText = """
        ① 没有第三方代码
        用的就是 macOS 自带的电源管理开关，没有内核扩展、没有常驻后台服务、不联网、不收集任何数据。

        ② 权限被卡死在一个动作上
        授权文件里只有「开启」和「关闭」这两条完整命令，没有通配符。就算被别的程序读到，也只能帮你切换这个睡眠开关，不能做任何别的事。

        ③ 退出一定恢复默认
        正常退出会立刻恢复；就算被强制结束（Force Quit）或崩溃，看门狗进程也会在 1 秒内把系统恢复成「合盖即休眠」。重启电脑同样会恢复默认。

        ④ 电量兜底
        没接电源且电量低于阈值时自动恢复，避免把电池跑干。

        ⑤ 合盖后的行为（只在「守夜」开启时生效）
        检测到合盖 → 立刻进入锁屏（弹出密码输入界面，和按电源键锁屏一样）→ 到设定时间后关掉屏幕。
        系统全程保持不休眠；打开盖子会取消还没来得及执行的关屏。

        ⚠️ 唯一要你自己注意的：合盖时键盘面散热是被挡住的，别把机器塞在包里跑重活。
        """
        a.addButton(withTitle: "知道了")
        a.runModal()
    }

    @objc func onShowLog() {
        guard FileManager.default.fileExists(atPath: kEventLog) else {
            alert("还没有运行记录", "程序还没有写下任何事件。")
            return
        }
        _ = runTask("/usr/bin/open", ["-t", kEventLog])
    }

    @objc func onQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - 登录启动项

    func setLoginItem(_ on: Bool) -> Bool {
        let uid = getuid()
        if !on {
            _ = runTask("/bin/launchctl", ["bootout", "gui/\(uid)/com.aries.lidguard"])
            try? FileManager.default.removeItem(atPath: kLoginAgent)
            return true
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.aries.lidguard</string>
            <key>ProgramArguments</key>
            <array><string>/usr/bin/open</string><string>-a</string><string>/Applications/守夜.app</string><string>--args</string><string>--login</string></array>
            <key>RunAtLoad</key><true/>
            <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
        do {
            try FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                                    withIntermediateDirectories: true)
            try plist.write(toFile: kLoginAgent, atomically: true, encoding: .utf8)
        } catch { return false }
        _ = runTask("/bin/launchctl", ["bootout", "gui/\(uid)/com.aries.lidguard"])
        let (code, _) = runTask("/bin/launchctl", ["bootstrap", "gui/\(uid)", kLoginAgent])
        return code == 0 || FileManager.default.fileExists(atPath: kLoginAgent)
    }

    func alert(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "知道了")
        a.runModal()
    }
}

// MARK: - UserDefaults 默认值

extension UserDefaults {
    func bool(forKey key: String, defaultValue: Bool) -> Bool {
        if object(forKey: key) == nil { return defaultValue }
        return bool(forKey: key)
    }
}

// MARK: - 启动

// 诊断开关：直接读一次合盖状态就退出（用于排查，不影响正常运行）
if CommandLine.arguments.contains("--lid") {
    if let c = isLidClosed() {
        print(c ? "closed" : "open")
    } else {
        print("unknown")
    }
    exit(0)
}

// 诊断开关：把系统开关强制改回 0（用来验证自愈能力，不影响正在运行的实例）
if CommandLine.arguments.contains("--force-off") {
    let (code, out) = runTask(kSudo, ["-n", kPmset, "-a", "disablesleep", "0"])
    print("code=\(code) \(shellLine(out))")
    exit(0)
}

// 诊断开关：打印事件日志（排查用）
if CommandLine.arguments.contains("--events") {
    if let txt = try? String(contentsOfFile: kEventLog, encoding: .utf8) {
        print(txt)
    } else {
        print("（还没有事件日志）")
    }
    exit(0)
}

// 诊断开关：查询当前是否已锁屏
if CommandLine.arguments.contains("--lockstate") {
    if let l = isScreenLocked() {
        print(l ? "locked" : "unlocked")
    } else {
        print("unknown")
    }
    exit(0)
}

// 诊断开关：只锁屏、不息屏（用来单独验证锁屏接口）
if CommandLine.arguments.contains("--lock-only") {
    print("lock=\(lockScreenNow() ? "called" : "failed")")
    exit(0)
}

// 诊断开关：立刻锁屏 + 息屏（与菜单里那个测试项等价）
if CommandLine.arguments.contains("--test-lock") {
    print("lock=\(lockScreenNow() ? "ok" : "failed")")
    let (ok, msg) = displayOffNow()
    print("displayoff=\(ok ? "ok" : "failed") \(msg)")
    exit(0)
}

// 看门狗模式：只做一件事 —— 盯住主进程，它一消失就恢复系统默认
if let i = CommandLine.arguments.firstIndex(of: "--watchdog"),
   i + 1 < CommandLine.arguments.count,
   let parent = Int32(CommandLine.arguments[i + 1]) {
    let myPath = selfExecutablePath()
    while true {
        var parentOK = isAlive(parent)
        if parentOK, let p = executablePath(of: parent), p != myPath { parentOK = false }
        if !parentOK {
            _ = runTask(kSudo, ["-n", kPmset, "-a", "disablesleep", "0"])
            exit(0)
        }
        usleep(500_000)
    }
}

let app = NSApplication.shared

// 单实例：已经有本 App 在跑就直接退出（看门狗不是 App，不会被算进来）
let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.aries.lidguard")
    .filter { $0.processIdentifier != getpid() }
if !others.isEmpty { exit(0) }

let delegate = LidGuard()
app.delegate = delegate

// 只驻留菜单栏，不在 Dock 出现（与"不占 Dock"的要求一致）
app.setActivationPolicy(.accessory)

// 被 kill / killall 时也要恢复
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { NSApp.terminate(nil) }
    s.resume()
    signalSources.append(s)
}

app.run()
