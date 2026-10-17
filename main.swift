//  LidGuard (守夜) — Mac 合盖不休眠开关
//  只做一件事：通过 macOS 自带的 pmset 开关，让合盖不进入休眠；
//  关闭时回读确认；恢复失败保留重试，不把失败报告为成功。
//
//  三重保险：
//   1. 正常退出（Cmd+Q / 菜单退出 / 注销）→ 同步恢复默认
//   2. 独立名称的看门狗：主进程消失后尝试恢复，失败继续重试
//   3. 电量低于阈值且未接电源 → 自动恢复默认

import Cocoa
import IOKit

// MARK: - 常量

let kGrantPath   = "/etc/sudoers.d/lidguard-disablesleep"
let kPmset       = "/usr/bin/pmset"
let kSudo        = "/usr/bin/sudo"
let kVisudo      = "/usr/sbin/visudo"
let kWatchOwnerFile = NSHomeDirectory() + "/.lidguard/watchdog-owner"
let kPowerLockFile = NSHomeDirectory() + "/.lidguard/power.lock"
let kLoginAgent  = NSHomeDirectory() + "/Library/LaunchAgents/com.aries.lidguard.plist"

// MARK: - 进程身份校验（看门狗只监控指定路径的父进程）
// proc_pidpath 由系统 libproc 提供，可直接调用

func executablePath(of pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let size = buf.count
    let n = buf.withUnsafeMutableBufferPointer { base -> Int32 in
        guard let p = base.baseAddress else { return -1 }
        return proc_pidpath(pid, p, UInt32(size))
    }
    guard n > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}

func isAlive(_ pid: Int32) -> Bool {
    return kill(pid, 0) == 0
}

func selfExecutablePath() -> String {
    return URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
}

func watchdogExecutablePath() -> String {
    return (selfExecutablePath() as NSString).deletingLastPathComponent + "/LidGuardWatchdog"
}

let kPrefAutoEnable = "autoEnableOnLaunch"
let kPrefLogin      = "startAtLogin"
let kPrefFloor      = "batteryFloor"
let kPrefLockOnLid  = "lockOnLidClose"      // 合盖时自动锁屏
let kPrefOffDelay   = "displayOffDelay"     // 锁屏后多少秒息屏；-1 = 不自动息屏

let defaults = UserDefaults.standard

// MARK: - 进程执行helper

func runTask(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "无法执行 \(path)：\(error.localizedDescription)") }
    pipe.fileHandleForWriting.closeFile()
    let fd = pipe.fileHandleForReading.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var output = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    func drain() {
        // 每轮有上限，持续输出的子进程也不能饿死超时检查。
        for _ in 0..<64 {
            let n = read(fd, &bytes, bytes.count)
            if n <= 0 { break }
            if output.count < 1_048_576 { output.append(contentsOf: bytes.prefix(n)) }
        }
    }
    let deadline = ProcessInfo.processInfo.systemUptime + max(timeout, 0.1)
    while p.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        drain()
        usleep(10_000)
    }
    let timedOut = p.isRunning
    if timedOut {
        p.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.3
        while p.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
    drain()
    pipe.fileHandleForReading.closeFile()
    if timedOut { return (-2, "命令超时：\(path)") }
    p.waitUntilExit()
    return (p.terminationStatus, String(data: output, encoding: .utf8) ?? "")
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
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        if fields.first == "SleepDisabled", fields.count == 2 {
            if fields[1] == "1" { return true }
            if fields[1] == "0" { return false }
        }
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
    // 返回值只表示锁屏请求被接口接受；真正锁定由控制器随后回读确认。
    if loginFrameworkHandle == nil { loginFrameworkHandle = dlopen(kLoginFwPath, RTLD_LAZY) }
    guard let h = loginFrameworkHandle, let sym = dlsym(h, "SACLockScreenImmediate") else {
        logEvent("锁屏接口不可用；不会把息屏当作锁屏成功")
        return false
    }
    let fn = unsafeBitCast(sym, to: SACLockScreenImmediateFn.self)
    let code = fn()
    logEvent("已发送锁屏请求，返回 \(code)")
    return code == 0
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


func commonTimer(interval: TimeInterval, repeats: Bool, action: @escaping (Timer) -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: repeats, block: action)
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

func shellQuote(_ value: String) -> String {
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func appleScriptQuote(_ value: String) -> String {
    return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r") + "\""
}

func grantInstallScript(user: String) -> String? {
    guard user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) == user.startIndex..<user.endIndex,
          !user.isEmpty else { return nil }
    let grant = "\(user) ALL=(root) NOPASSWD: \(kPmset) -a disablesleep 0, \(kPmset) -a disablesleep 1"
    // 此脚本直接传入授权执行器，不读取任何当前用户可写的安装脚本或规则。
    // staging 目录由管理员在 root 所有的 /private/etc 下创建。
    return """
    set -eu
    /usr/bin/install -d -m 0755 -o root -g wheel /etc/sudoers.d
    work=$(/usr/bin/mktemp -d /private/etc/.lidguard.XXXXXXXX)
    trap '/bin/rm -rf "$work"' EXIT
    /usr/bin/printf '%s\\n' \(shellQuote(grant)) > "$work/rule"
    \(kVisudo) -cf "$work/rule" >/dev/null
    /usr/sbin/chown root:wheel "$work/rule"
    /bin/chmod 0440 "$work/rule"
    previous=0
    if [ -e \(shellQuote(kGrantPath)) ] || [ -L \(shellQuote(kGrantPath)) ]; then
        /bin/cp -p \(shellQuote(kGrantPath)) "$work/previous"
        previous=1
    fi
    /bin/mv -f "$work/rule" \(shellQuote(kGrantPath))
    if ! \(kVisudo) -c >/dev/null; then
        if [ "$previous" = 1 ]; then
            /bin/mv -f "$work/previous" \(shellQuote(kGrantPath))
        else
            /bin/rm -f \(shellQuote(kGrantPath))
        fi
        exit 1
    fi
    """
}

func withPowerLock(_ action: () -> Bool) -> Bool {
    do {
        try FileManager.default.createDirectory(atPath: (kPowerLockFile as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
    } catch { logEvent("无法创建电源操作锁目录"); return false }
    let fd = open(kPowerLockFile, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { logEvent("无法打开电源操作锁"); return false }
    defer { close(fd) }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        if ProcessInfo.processInfo.systemUptime >= deadline { logEvent("电源操作忙，将稍后重试"); return false }
        usleep(10_000)
    }
    defer { _ = flock(fd, LOCK_UN) }
    return action()
}

func restoreSleepOnce(expectedOwner: String? = nil) -> Bool {
    return withPowerLock {
        if let owner = expectedOwner,
           (try? String(contentsOfFile: kWatchOwnerFile, encoding: .utf8)) != owner { return false }
        if currentSleepDisabled() == false { return true }
        let result = runTask(kSudo, ["-n", kPmset, "-a", "disablesleep", "0"])
        if currentSleepDisabled() == false { return true }
        logEvent("恢复休眠尚未确认（退出码 \(result.code)）：\(shellLine(result.out))")
        return false
    }
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

    var isOn = false            // 最近一次回读确认的实际状态
    var desiredOn = false      // 用户当前意图，与实际状态分开
    var recoveryPending = false
    var statusError: String?
    var launchRetry: DispatchWorkItem?
    var retryGeneration = 0
    var watchdogOwner: String?
    var lockVerification: Timer?
    var lidClosedAt: Date?
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
        logEvent("—— 启动，授权=\(authorized)，SleepDisabled=\(currentSleepDisabled().map(String.init) ?? "?")")
        startBatteryTimer()
        startLidTimer()
        startHealthTimer()
        if defaults.bool(forKey: kPrefAutoEnable, defaultValue: true) {
            desiredOn = true
            if authorized { enableAtLaunch(attemptsLeft: 5) }
            else if askToInstallGrant() { _ = enableMode() }
            else { desiredOn = false }
        } else if isOn {
            // 接管已开启的系统状态，也必须先具备有效的恢复保护。
            desiredOn = true
            if !startWatchdog() { _ = disableMode(reason: "看门狗启动失败") }
        }
        if isOn && !desiredOn { _ = disableMode(reason: "未建立恢复保护") }
        checkBattery()
        refreshUI()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return prepareForTermination() ? .terminateNow : .terminateCancel
    }

    func prepareForTermination() -> Bool {
        if restoreToDefault(reason: "退出") { return true }
        alert("暂时无法安全退出", "尚未确认合盖休眠已恢复，程序会继续重试。\n\n请用「安装或修复权限授权…」修复权限后再退出。")
        return false
    }

    func applicationWillTerminate(_ note: Notification) {
        // 系统强制结束或注销时可能无法取消退出；恢复责任交给仍存活的看门狗。
        if recoveryPending { logEvent("终止时恢复尚未完成，保留看门狗继续重试") }
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
        if let actual = currentSleepDisabled() {
            isOn = actual
            if !desiredOn && !recoveryPending { statusError = nil }
        }
        else { statusError = "无法读取系统休眠状态" }
    }

    func refreshAuthorized() {
        authorized = ["0", "1"].allSatisfy {
            runTask(kSudo, ["-n", "-l", kPmset, "-a", "disablesleep", $0]).code == 0
        }
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

        fixAuthItem.isHidden = false
        fixAuthItem.title = authorized ? "重新安装权限授权…" : "安装或修复权限授权…"
        if let error = statusError {
            statusLine.title = "状态：\(error)"
            statusItem.button?.title = " 待处理"
            statusItem.button?.toolTip = error
        }
        if recoveryPending || desiredOn { toggleItem.title = "暂停 / 重试恢复合盖休眠" }
    }

    // MARK: - 开启 / 恢复

    func applySleepDisabled(_ on: Bool) -> Bool {
        if !on { return restoreSleepOnce() }
        return withPowerLock {
            let result = runTask(kSudo, ["-n", kPmset, "-a", "disablesleep", "1"])
            if result.code == 0 && currentSleepDisabled() == true { return true }
            logEvent("未确认合盖不休眠已开启（退出码 \(result.code)）：\(shellLine(result.out))")
            return false
        }
    }

    @discardableResult
    func enableMode(silent: Bool = false) -> Bool {
        desiredOn = true
        if recoveryPending {
            if !silent { alert("请先完成恢复", "上一次恢复休眠尚未成功，请先修复权限并重试恢复。") }
            return false
        }
        refreshAuthorized()
        if !authorized && (silent || !askToInstallGrant()) {
            statusError = "权限不可用，请安装或修复授权"
            if !silent { desiredOn = false }
            refreshUI()
            return false
        }
        if batteryIsLow() {
            _ = disableMode(reason: "电量")
            return false
        }
        guard startWatchdog() else {
            desiredOn = false
            statusError = "看门狗未就绪，未开启守夜"
            // 原系统状态可能已经开启；必要时仍要尝试恢复。
            if currentSleepDisabled() != false { _ = disableMode(reason: "看门狗启动失败") }
            if !silent { alert("开启失败", statusError ?? "无法建立恢复保护") }
            refreshUI()
            return false
        }
        guard applySleepDisabled(true) else {
            // 命令失败也可能已部分生效：先明确恢复，不能假定它没有修改系统。
            recoveryPending = true
            if restoreSleepOnce() { recoveryPending = false; isOn = false }
            else { syncStateFromSystem() }
            statusError = recoveryPending ? "开启失败，恢复休眠仍待重试" : "开启未成功，等待重试或修复权限"
            refreshUI()
            if !silent { alert("开启未成功", statusError!) }
            return false
        }
        isOn = true
        statusError = nil
        logEvent("已回读确认合盖不休眠开启")
        if isLidClosed() == true {
            lastLidClosed = true
            handleLidClosed()
        }
        refreshUI()
        return isOn && desiredOn
    }

    /// 启动时的开启流程：失败会自己重试，不会像以前那样失败一次就永远不管
    func enableAtLaunch(attemptsLeft: Int) {
        guard desiredOn, defaults.bool(forKey: kPrefAutoEnable, defaultValue: true) else { return }
        let generation = retryGeneration
        logEvent("尝试开启（剩余重试 \(attemptsLeft) 次）")
        if enableMode(silent: true) || !desiredOn { return }
        if attemptsLeft > 0 {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.retryGeneration == generation, self.desiredOn else { return }
                self.enableAtLaunch(attemptsLeft: attemptsLeft - 1)
            }
            launchRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        } else { logEvent("启动重试耗尽，后续由巡检按用户意图继续重试") }
    }

    func cancelLaunchRetry() {
        retryGeneration += 1
        launchRetry?.cancel()
        launchRetry = nil
    }

    /// 健康巡检：发现系统状态和预期不一致就自动修回来
    func healthCheck() {
        if recoveryPending {
            if restoreSleepOnce() {
                recoveryPending = false
                isOn = false
                statusError = nil
                if !desiredOn { stopWatchdog() }
                logEvent("重试已确认合盖休眠恢复")
            }
            refreshUI()
            return
        }
        guard desiredOn else {
            syncStateFromSystem()
            refreshUI()
            return
        }
        if batteryIsLow() { _ = disableMode(reason: "电量"); return }
        guard let actual = currentSleepDisabled() else {
            statusError = "系统休眠状态未知，等待重新确认"
            refreshUI()
            return
        }
        isOn = actual
        if !actual || watchdog == nil || !(watchdog?.isRunning ?? false) {
            _ = enableMode(silent: true)
        } else { statusError = nil; refreshUI() }
    }

    func startHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = commonTimer(interval: 15, repeats: true) { [weak self] _ in self?.healthCheck() }
    }

    @discardableResult
    func disableMode(reason: String) -> Bool {
        desiredOn = false
        cancelLaunchRetry()
        cancelPendingDisplayOff()
        lockVerification?.invalidate()
        lockVerification = nil
        let restored = restoreSleepOnce()
        recoveryPending = !restored
        if restored {
            isOn = false
            statusError = nil
            stopWatchdog()
            logEvent("已确认恢复合盖休眠（原因：\(reason)）")
        } else {
            syncStateFromSystem()
            statusError = "恢复休眠失败，将继续重试；请检查权限"
            logEvent(statusError! + "（原因：\(reason)）")
            // 只有仍在保护的看门狗才有资格保留；不基于残留 PID 文件结束任何进程。
            if watchdog == nil || !(watchdog?.isRunning ?? false) { _ = startWatchdog() }
        }
        refreshUI()
        if reason == "电量" {
            alert(restored ? "已自动恢复合盖休眠" : "低电量，恢复休眠尚未成功",
                  restored ? "电量已达到保护阈值且未接电源，已确认关闭守夜。" : "请接上电源，并用菜单修复权限；程序会继续重试恢复休眠。")
        }
        return restored
    }

    @discardableResult
    func restoreToDefault(reason: String) -> Bool {
        return disableMode(reason: reason)
    }

    // MARK: - 看门狗（强杀兜底）

    @discardableResult
    func startWatchdog() -> Bool {
        if watchdog?.isRunning == true { return true }
        watchdog = nil
        let owner = UUID().uuidString
        let p = Process()
        let ready = Pipe()
        p.executableURL = URL(fileURLWithPath: watchdogExecutablePath())
        p.arguments = ["--watchdog", "\(getpid())", selfExecutablePath(), owner]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = ready
        p.standardError = FileHandle.nullDevice
        do { try p.run() }
        catch { logEvent("看门狗启动失败：\(error.localizedDescription)"); return false }
        ready.fileHandleForWriting.closeFile()
        var poller = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let signaled = poll(&poller, 1, 2000) > 0
        var bytes = [UInt8](repeating: 0, count: 16)
        let count = signaled ? read(poller.fd, &bytes, bytes.count) : 0
        ready.fileHandleForReading.closeFile()
        guard count > 0, String(bytes: bytes.prefix(count), encoding: .utf8) == "ready\n", p.isRunning else {
            if p.isRunning { p.terminate() }
            logEvent("看门狗未通过就绪确认")
            return false
        }
        let recorded = withPowerLock {
            do {
                try owner.write(toFile: kWatchOwnerFile, atomically: true, encoding: .utf8)
                return true
            } catch { logEvent("看门狗恢复责任记录失败：\(error.localizedDescription)"); return false }
        }
        if !recorded {
            p.terminate()
            return false
        }
        watchdogOwner = owner
        watchdog = p
        return true
    }

    // 按进程号精确清除，并校验确实是我们自己的进程，不做任何模糊匹配
    func stopWatchdog() {
        // 调用方只能在已经回读确认恢复之后调用。只终止自己持有的子进程。
        if let w = watchdog, w.isRunning { w.terminate() }
        watchdog = nil
        if let owner = watchdogOwner,
           (try? String(contentsOfFile: kWatchOwnerFile, encoding: .utf8)) == owner {
            try? FileManager.default.removeItem(atPath: kWatchOwnerFile)
        }
        watchdogOwner = nil
    }

    // MARK: - 电量监控

    func startBatteryTimer() {
        batteryTimer?.invalidate()
        batteryTimer = commonTimer(interval: 30, repeats: true) { [weak self] _ in self?.checkBattery() }
    }

    func checkBattery() {
        if (isOn || desiredOn) && batteryIsLow() { _ = disableMode(reason: "电量") }
    }

    func batteryIsLow() -> Bool {
        let floor = effectiveFloor()
        guard floor > 0 else { return false }
        let result = runTask(kPmset, ["-g", "batt"])
        guard result.code == 0, result.out.contains("Battery Power"),
              let r = result.out.range(of: #"([0-9]{1,3})%"#, options: .regularExpression),
              let percent = Int(result.out[r].dropLast()) else { return false }
        return percent <= floor
    }

    func effectiveFloor() -> Int {
        if defaults.bool(forKey: "floorSet") { return defaults.integer(forKey: kPrefFloor) }
        return 20
    }

    // MARK: - 合盖检测 → 锁屏 → 延迟息屏

    func startLidTimer() {
        lidTimer?.invalidate()
        lidTimer = commonTimer(interval: 2, repeats: true) { [weak self] _ in self?.checkLid() }
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
        guard isOn, desiredOn, !recoveryPending else { return }
        lidClosedAt = Date()
        lockVerification?.invalidate()
        lockVerification = nil
        cancelPendingDisplayOff()
        if defaults.bool(forKey: kPrefLockOnLid, defaultValue: true) {
            if isScreenLocked() == true { scheduleDisplayOff(); return }
            guard lockScreenNow() else { handleLockFailure(); return }
            logEvent("合盖 → 已请求锁屏，等待会话状态确认")
            var remaining = 8
            lockVerification = commonTimer(interval: 0.25, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                guard self.isOn, self.desiredOn, isLidClosed() == true else {
                    timer.invalidate(); self.lockVerification = nil; return
                }
                if isScreenLocked() == true {
                    timer.invalidate(); self.lockVerification = nil
                    logEvent("合盖 → 已确认会话锁定")
                    self.scheduleDisplayOff()
                } else {
                    remaining -= 1
                    if remaining == 0 {
                        timer.invalidate(); self.lockVerification = nil
                        self.handleLockFailure()
                    }
                }
            }
        } else { scheduleDisplayOff() }
    }

    func handleLockFailure() {
        let restored = disableMode(reason: "锁屏未确认")
        alert("未能确认锁屏", restored
              ? "已恢复合盖休眠。系统锁屏接口不可用或未能确认，请先手动锁屏。"
              : "锁屏未确认，恢复休眠也尚未成功。请手动锁屏并检查权限，程序将继续重试恢复。")
    }

    func scheduleDisplayOff() {
        cancelPendingDisplayOff()
        let delay = effectiveOffDelay()
        guard delay >= 0, isOn, desiredOn, isLidClosed() == true else { return }
        let elapsed = lidClosedAt.map { Date().timeIntervalSince($0) } ?? 0
        let remaining = max(0, Double(delay) - elapsed)
        if remaining == 0 { fireDisplayOff(trigger: "合盖"); return }
        pendingDisplayOff = commonTimer(interval: remaining, repeats: false) { [weak self] _ in
            self?.fireDisplayOff(trigger: "合盖后 \(delay) 秒")
        }
        logEvent("合盖 → 安排延迟息屏，剩余 \(Int(remaining.rounded(.up))) 秒")
    }

    func handleLidOpened() {
        cancelPendingDisplayOff()
        lockVerification?.invalidate()
        lockVerification = nil
        lidClosedAt = nil
    }

    func fireDisplayOff(trigger: String) {
        cancelPendingDisplayOff()
        guard isOn, desiredOn, !recoveryPending, isLidClosed() == true else { return }
        if defaults.bool(forKey: kPrefLockOnLid, defaultValue: true) && isScreenLocked() != true {
            handleLockFailure()
            return
        }
        let result = displayOffNow()
        logEvent("\(trigger) → 息屏\(result.ok ? "成功" : "失败 " + result.msg)")
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
        let result = installGrant()
        if !result.ok { alert("授权未完成", result.msg) }
        return result.ok
    }

    func installGrant() -> (ok: Bool, msg: String) {
        guard let script = grantInstallScript(user: NSUserName()) else {
            return (false, "当前账户短名称不受支持，无法安全生成授权规则")
        }
        let source = "do shell script \(appleScriptQuote(script)) with administrator privileges"
        let result = runTask("/usr/bin/osascript", ["-e", source], timeout: 120)
        guard result.code == 0 else {
            return (false, shellLine(result.out).isEmpty ? "授权未完成" : shellLine(result.out))
        }
        refreshAuthorized()
        return (authorized, authorized ? "" : "授权规则尚未生效，请检查 sudo 配置")
    }

    // MARK: - 菜单动作

    @objc func onToggle() {
        cancelLaunchRetry()
        if isOn || desiredOn || recoveryPending { _ = disableMode(reason: "手动") }
        else { _ = enableMode() }
    }

    @objc func onToggleAutoEnable(_ sender: NSMenuItem) {
        let v = !defaults.bool(forKey: kPrefAutoEnable, defaultValue: true)
        defaults.set(v, forKey: kPrefAutoEnable)
        if !v {
            cancelLaunchRetry()
            if !isOn {
                desiredOn = false
                if !recoveryPending && currentSleepDisabled() == false {
                    stopWatchdog()
                    statusError = nil
                }
            }
        }
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
        checkBattery()
        refreshUI()
    }

    @objc func onToggleLockOnLid(_ sender: NSMenuItem) {
        let v = !defaults.bool(forKey: kPrefLockOnLid, defaultValue: true)
        defaults.set(v, forKey: kPrefLockOnLid)
        lockVerification?.invalidate()
        lockVerification = nil
        if isOn && isLidClosed() == true { handleLidClosed() }
        refreshUI()
    }

    @objc func onSetOffDelay(_ sender: NSMenuItem) {
        defaults.set(true, forKey: "offDelaySet")
        defaults.set(sender.tag, forKey: kPrefOffDelay)
        cancelPendingDisplayOff()
        if lockVerification == nil { scheduleDisplayOff() }
        refreshUI()
    }

    /// 手动测试：立刻锁屏 + 立刻息屏。
    /// 成功时故意不弹任何提示 —— 弹窗会把屏幕重新点亮，反而干扰观察。
    @objc func onTestLockNow() {
        cancelPendingDisplayOff()
        guard lockScreenNow() else {
            alert("锁屏请求失败", "未调用息屏，也未把息屏当作锁屏成功。请手动锁屏。")
            return
        }
        var remaining = 8
        lockVerification?.invalidate()
        lockVerification = commonTimer(interval: 0.25, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if isScreenLocked() == true {
                timer.invalidate(); self.lockVerification = nil
                let result = displayOffNow()
                logEvent("手动测试：已确认锁屏，息屏\(result.ok ? "成功" : "失败 " + result.msg)")
                if !result.ok { self.alert("息屏失败", result.msg) }
            } else {
                remaining -= 1
                if remaining == 0 {
                    timer.invalidate(); self.lockVerification = nil
                    if self.isOn && isLidClosed() == true { self.handleLockFailure() }
                    else { self.alert("未能确认锁屏", "未执行息屏。请手动锁屏并检查运行记录。") }
                }
            }
        }
    }

    @objc func onFixAuth() {
        if askToInstallGrant() {
            if recoveryPending { _ = disableMode(reason: "权限修复") }
            alert("授权完成", "权限已验证。可以从菜单开启守夜，或重试退出。")
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

        ③ 退出先确认恢复
        正常退出会回读系统状态；失败时保留程序与恢复重试。主进程消失后，独立名称的看门狗会尝试恢复，失败则继续重试。恢复仍依赖系统命令可执行及看门狗存活。

        ④ 电量兜底
        没接电源且电量低于阈值时自动恢复，避免把电池跑干。

        ⑤ 合盖后的行为（只在「守夜」开启时生效）
        检测到合盖 → 请求并确认会话锁定 → 到设定时间后关掉屏幕；无法确认锁屏时尝试恢复合盖休眠。
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
        let domain = "gui/\(getuid())"
        let service = domain + "/com.aries.lidguard"
        let loaded = runTask("/bin/launchctl", ["print", service]).code == 0
        if !on {
            if loaded && runTask("/bin/launchctl", ["bootout", service]).code != 0 { return false }
            do {
                if FileManager.default.fileExists(atPath: kLoginAgent) { try FileManager.default.removeItem(atPath: kLoginAgent) }
                return runTask("/bin/launchctl", ["print", service]).code != 0
            } catch {
                if loaded { _ = runTask("/bin/launchctl", ["bootstrap", domain, kLoginAgent]) }
                return false
            }
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let plist: [String: Any] = [
            "Label": "com.aries.lidguard",
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundleURL.path, "--args", "--login"],
            "RunAtLoad": true, "ProcessType": "Interactive"
        ]
        let previous = try? Data(contentsOf: URL(fileURLWithPath: kLoginAgent))
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(atPath: (kLoginAgent as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: kLoginAgent), options: .atomic)
        } catch { return false }
        if loaded && runTask("/bin/launchctl", ["bootout", service]).code != 0 {
            if let previous = previous { try? previous.write(to: URL(fileURLWithPath: kLoginAgent), options: .atomic) }
            else { try? FileManager.default.removeItem(atPath: kLoginAgent) }
            return false
        }
        let code = runTask("/bin/launchctl", ["bootstrap", domain, kLoginAgent]).code
        if code == 0 && runTask("/bin/launchctl", ["print", service]).code == 0 { return true }
        // 注册失败还原之前的文件/服务，不能只因为文件存在就打勾。
        if let previous = previous {
            try? previous.write(to: URL(fileURLWithPath: kLoginAgent), options: .atomic)
            if loaded { _ = runTask("/bin/launchctl", ["bootstrap", domain, kLoginAgent]) }
        } else { try? FileManager.default.removeItem(atPath: kLoginAgent) }
        return false
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
    print("lock-request=\(lockScreenNow() ? "accepted" : "failed")")
    exit(0)
}

// 诊断开关：立刻锁屏 + 息屏（与菜单里那个测试项等价）
if CommandLine.arguments.contains("--test-lock") {
    guard lockScreenNow() else { print("lock-request=failed"); exit(1) }
    var confirmed = false
    for _ in 0..<8 {
        if isScreenLocked() == true { confirmed = true; break }
        usleep(250_000)
    }
    guard confirmed else { print("lock=unconfirmed; displayoff=skipped"); exit(1) }
    let (ok, msg) = displayOffNow()
    print("lock=confirmed displayoff=\(ok ? "ok" : "failed") \(msg)")
    exit(ok ? 0 : 1)
}

// 看门狗模式：独立可执行文件名；只有当前恢复责任的持有者可以恢复系统状态。
if let i = CommandLine.arguments.firstIndex(of: "--watchdog") {
    // 主程序忽略这些信号后交给 DispatchSource；exec 会继承 SIG_IGN。
    // 看门狗必须恢复默认处理，正常关闭后父进程才能终止自己的子进程。
    for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig, SIG_DFL) }
    guard i + 3 < CommandLine.arguments.count, let parent = Int32(CommandLine.arguments[i + 1]), parent > 1 else { exit(2) }
    let expectedParent = CommandLine.arguments[i + 2]
    let owner = CommandLine.arguments[i + 3]
    guard isAlive(parent), executablePath(of: parent) == expectedParent else { exit(2) }
    FileHandle.standardOutput.write(Data("ready\n".utf8))
    // 父进程收到 ready 后才提交恢复责任记录，随后才允许开启电源开关。
    let leaseDeadline = ProcessInfo.processInfo.systemUptime + 3
    while (try? String(contentsOfFile: kWatchOwnerFile, encoding: .utf8)) != owner {
        if ProcessInfo.processInfo.systemUptime >= leaseDeadline { exit(2) }
        usleep(50_000)
    }
    while true {
        if (try? String(contentsOfFile: kWatchOwnerFile, encoding: .utf8)) != owner { exit(0) }
        let parentOK = isAlive(parent) && executablePath(of: parent) == expectedParent
        if !parentOK {
            var failures = 0
            while (try? String(contentsOfFile: kWatchOwnerFile, encoding: .utf8)) == owner {
                if restoreSleepOnce(expectedOwner: owner) { logEvent("看门狗已确认恢复合盖休眠"); exit(0) }
                if (try? String(contentsOfFile: kWatchOwnerFile, encoding: .utf8)) != owner { exit(0) }
                failures += 1
                logEvent("看门狗恢复未成功，将继续重试（第 \(failures) 次）")
                usleep(failures < 5 ? 500_000 : 15_000_000)
            }
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
