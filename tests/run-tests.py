#!/usr/bin/env python3
"""Compile isolated copies of production methods; never launch the real App.

All pmset/sudo/launchctl/admin operations are mocked. Only harmless subprocess
capture/timeout tests and uniquely named test watchdogs run as real processes.
"""
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
SOURCE = (REPO / 'main.swift').read_text()
CLT = Path(os.environ.get('CLT_DIR', '/Library/Developer/CommandLineTools'))
SWIFTC = os.environ.get('SWIFTC', str(CLT / 'usr/bin/swiftc'))
SDK = os.environ.get('SDK_PATH', str(CLT / 'SDKs/MacOSX.sdk'))


def function(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        if text[end] == '{': depth += 1
        if text[end] == '}': depth -= 1
        end += 1
    return text[start:end]


def replace_body(text, signature, body):
    old = function(text, signature)
    return text.replace(old, old[:old.index('{') + 1] + '\n' + body + '\n}', 1)


with tempfile.TemporaryDirectory(prefix='lidguard-regression-') as tmp:
    root = Path(tmp)
    source = SOURCE[:SOURCE.index('// MARK: - 启动\n')]
    originals = []
    for name in ['runTask', 'lockScreenNow', 'startWatchdog', 'stopWatchdog']:
        f = function(source, 'func ' + name + '(')
        originals.append(f.replace('func ' + name + '(', 'func original' + name[0].upper() + name[1:] + '(', 1))
    source = source.replace('let defaults = UserDefaults.standard', 'let defaults = MemoryDefaults()')
    source = source.replace('"/etc/sudoers.d/lidguard-disablesleep"', 'testRoot + "/grant"')
    source = source.replace('NSHomeDirectory() + "/.lidguard/watchdog-owner"', 'testRoot + "/watchdog-owner"')
    source = source.replace('NSHomeDirectory() + "/.lidguard/power.lock"', 'testRoot + "/power.lock"')
    source = source.replace('NSHomeDirectory() + "/Library/LaunchAgents/com.aries.lidguard.plist"', 'testRoot + "/agents/login.plist"')
    source = source.replace('private let kLoginFwPath = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"', 'private let kLoginFwPath = testRoot + "/missing-framework"')
    for signature, replacement in [
        ('func runTask(', 'return mockTask(path, args, timeout: timeout)'),
        ('func logEvent(', 'probe.logs.append(msg)'),
        ('func isLidClosed(', 'probe.lidReads += 1; return probe.lidClosed'),
        ('func isScreenLocked(', 'return probe.screenLocked'),
        ('func lockScreenNow(', 'probe.lockRequests += 1; return probe.lockRequestAccepted'),
        ('func refreshUI(', 'probe.uiRefreshes += 1'),
        ('func alert(', 'probe.alerts.append(title)'),
        ('func askToInstallGrant(', 'return false'),
        ('func startWatchdog(', 'probe.watchStarts += 1; if probe.watchAllowed { probe.watchRunning = true }; return probe.watchAllowed'),
        ('func stopWatchdog(', 'probe.watchStops += 1; probe.watchRunning = false'),
        ('func watchdogExecutablePath(', 'return probe.helperPath'),
    ]:
        source = replace_body(source, signature, replacement)
    prefix = r'''
import Cocoa
setbuf(stdout, nil)
let testRoot = CommandLine.arguments[1]
final class MemoryDefaults {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func bool(forKey key: String, defaultValue: Bool) -> Bool { values[key] as? Bool ?? defaultValue }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
final class Probe {
    var sleepDisabled: Bool? = true
    var rawPowerOutput: String?
    var permissionOK = true
    var mutationFails = false
    var mutationHasEffect = true
    var watchAllowed = true
    var watchRunning = true
    var watchStarts = 0
    var watchStops = 0
    var helperPath = testRoot + "/missing-helper"
    var lidClosed: Bool? = false
    var lidReads = 0
    var screenLocked: Bool? = false
    var lockRequestAccepted = true
    var lockRequests = 0
    var displayOffCalls = 0
    var battery = "Now drawing from 'AC Power'\n -InternalBattery-0 85%; charging"
    var launchLoaded = false
    var bootstrapFails = false
    var bootoutFails = false
    var lastLoginPath: String?
    var uiRefreshes = 0
    var privilegedSource: String?
    var calls: [String] = []
    var logs: [String] = []
    var alerts: [String] = []
}
var probe = Probe()
func mockTask(_ path: String, _ args: [String], timeout: TimeInterval) -> (code: Int32, out: String) {
    probe.calls.append(path + " " + args.joined(separator: " "))
    if path == "/usr/bin/pmset" {
        if args == ["-g"] {
            let output = probe.rawPowerOutput ?? probe.sleepDisabled.map { "SleepDisabled\t\($0 ? 1 : 0)\n" } ?? "unknown\n"
            return (0, output)
        }
        if args == ["-g", "batt"] { return (0, probe.battery) }
        if args == ["displaysleepnow"] { probe.displayOffCalls += 1; return (0, "") }
    }
    if path == "/usr/bin/sudo" {
        if args.prefix(2) == ["-n", "-l"] { return (probe.permissionOK ? 0 : 1, "mock permissions") }
        if args.count == 5 && args[3] == "disablesleep" {
            if probe.mutationFails || !probe.permissionOK { return (1, "mock rejected command") }
            if probe.mutationHasEffect { probe.sleepDisabled = args[4] == "1" }
            return (0, "")
        }
    }
    if path == "/bin/launchctl" {
        if args[0] == "print" { return (probe.launchLoaded ? 0 : 113, "mock service") }
        if args[0] == "bootout" {
            if probe.bootoutFails { return (5, "mock failure") }
            probe.launchLoaded = false; return (0, "")
        }
        if args[0] == "bootstrap" {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: kLoginAgent)),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               let arguments = plist["ProgramArguments"] as? [String], arguments.count > 2 { probe.lastLoginPath = arguments[2] }
            if probe.bootstrapFails { return (5, "mock failure") }
            probe.launchLoaded = true; return (0, "")
        }
    }
    if path == "/usr/bin/osascript" { probe.privilegedSource = args.last; return (0, "mocked admin execution") }
    fatalError("Unmocked command blocked: \(path) \(args)")
}
var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: " + message) }
    passed += 1; print("PASS: " + message)
}
func reset() { probe = Probe(); defaults.values = [:]; try? FileManager.default.removeItem(atPath: kLoginAgent) }
'''
    tests = r'''
reset()
do {
    let c = LidGuard(); c.isOn = true; c.desiredOn = true; probe.mutationFails = true
    check(!c.disableMode(reason: "手动"), "failed restore returns failure")
    check(c.recoveryPending && c.isOn && !c.desiredOn, "failed restore preserves actual state and recovery intent")
    check(probe.watchStops == 0 && !probe.logs.contains(where: { $0.contains("已确认恢复") }), "failed restore retains watchdog without success log")
    check(!c.prepareForTermination(), "quit cancels when restore cannot be confirmed")
    probe.mutationFails = false; c.healthCheck()
    check(!c.isOn && !c.recoveryPending && probe.watchStops == 1, "health retry confirms restore before watchdog cleanup")
    c.healthTimer?.invalidate()
}
reset()
do {
    let c = LidGuard(); probe.sleepDisabled = false; probe.mutationHasEffect = false
    check(!c.enableMode(silent: true) && !c.isOn && c.statusError != nil, "no enable success without matching readback")
    probe.mutationHasEffect = true; c.healthCheck()
    check(c.isOn && c.desiredOn, "health retries desired mode even after startup failure")
    _ = c.disableMode(reason: "cleanup")
}
reset()
do {
    let c = LidGuard(); probe.sleepDisabled = false; probe.watchAllowed = false
    check(!c.enableMode(silent: true), "no enable before watchdog readiness")
    check(!probe.calls.contains("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1"), "watchdog failure prevents power mutation")
}
reset()
do {
    let c = LidGuard(); probe.sleepDisabled = false; probe.permissionOK = false; c.desiredOn = true
    c.enableAtLaunch(attemptsLeft: 0); probe.permissionOK = true; c.healthCheck()
    check(c.isOn, "startup retries exhausted still recover through health check")
    _ = c.disableMode(reason: "cleanup")
}
reset()
do {
    let c = LidGuard(); probe.sleepDisabled = false; probe.permissionOK = false; c.desiredOn = true
    c.enableAtLaunch(attemptsLeft: 1)
    let oldGeneration = c.retryGeneration
    c.onToggleAutoEnable(NSMenuItem()); probe.permissionOK = true
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 3.1))
    c.healthCheck()
    check(c.retryGeneration > oldGeneration && !c.isOn && !c.desiredOn, "cancelled auto-enable cannot be revived by queued work or health")
}
reset()
do {
    let c = LidGuard(); probe.permissionOK = false
    try "invalid grant".write(toFile: kGrantPath, atomically: true, encoding: .utf8)
    c.refreshAuthorized()
    check(!c.authorized, "grant file existence is insufficient for authorization")
    check(!originalLockScreenNow() && probe.displayOffCalls == 0, "missing lock API never falls back to display sleep")
}
reset()
do {
    let c = LidGuard(); c.isOn = true; c.desiredOn = true; probe.lidClosed = true
    c.handleLidClosed()
    check(c.pendingDisplayOff == nil && c.lockVerification != nil, "display waits for confirmed session lock")
    for _ in 0..<8 { c.lockVerification?.fire() }
    check(!c.desiredOn && !c.isOn && probe.displayOffCalls == 0, "unconfirmed lock fails safely to restored sleep")
}
reset()
do {
    let c = LidGuard(); c.isOn = true; c.desiredOn = true; probe.lidClosed = true
    c.handleLidClosed(); probe.screenLocked = true; c.lockVerification?.fire()
    check(c.pendingDisplayOff != nil, "confirmed lock schedules display sleep")
    probe.lidClosed = false; c.pendingDisplayOff?.fire()
    check(probe.displayOffCalls == 0, "opening lid before polling cancels display action at execution")
}
reset()
do {
    let c = LidGuard(); c.isOn = true; c.desiredOn = true; probe.lidClosed = true; probe.screenLocked = true
    c.handleLidClosed(); let item = NSMenuItem(); item.tag = -1; c.onSetOffDelay(item)
    check(c.pendingDisplayOff == nil && probe.displayOffCalls == 0, "disable display sleep cancels pending timer")
    item.tag = 60; c.onSetOffDelay(item)
    check(c.pendingDisplayOff != nil, "new display delay reschedules current closed lid")
    c.handleLidOpened()
}
reset()
do {
    let c = LidGuard(); probe.sleepDisabled = false; probe.lidClosed = true; c.checkLid()
    check(c.enableMode(silent: true) && probe.lockRequests == 1, "enable while already closed replays lock flow")
    c.handleLidOpened(); _ = c.disableMode(reason: "cleanup")
}
reset()
do {
    let c = LidGuard(); probe.sleepDisabled = false
    probe.battery = "Now drawing from 'Battery Power'\n -InternalBattery-0 10%; discharging"
    check(!c.enableMode(silent: true) && !c.desiredOn, "low battery blocks enabling before the first periodic check")
}
reset()
do {
    let c = LidGuard(); c.isOn = true; c.desiredOn = true
    // CFRunLoopMode imports as either a CFString or a transparent string enum across SDKs.
    CFRunLoopAddCommonMode(CFRunLoopGetMain(), unsafeBitCast(RunLoop.Mode.eventTracking.rawValue as CFString, to: CFRunLoopMode.self))
    CFRunLoopAddCommonMode(CFRunLoopGetMain(), unsafeBitCast(RunLoop.Mode.modalPanel.rawValue as CFString, to: CFRunLoopMode.self))
    c.startBatteryTimer(); c.startLidTimer(); c.startHealthTimer()
    for mode in [RunLoop.Mode.eventTracking, .modalPanel] {
        let before = probe.calls.count; let lids = probe.lidReads
        for t in [c.batteryTimer!, c.lidTimer!, c.healthTimer!] { t.fireDate = Date(timeIntervalSinceNow: 0.01) }
        let keeper = Port(); RunLoop.main.add(keeper, forMode: mode)
        let stop = Date(timeIntervalSinceNow: 0.1)
        while Date() < stop { _ = RunLoop.main.run(mode: mode, before: stop) }
        check(probe.calls.count > before && probe.lidReads > lids, "safety timers run in " + mode.rawValue)
        RunLoop.main.remove(keeper, forMode: mode)
    }
    c.batteryTimer?.invalidate(); c.lidTimer?.invalidate(); c.healthTimer?.invalidate()
}
reset()
do {
    let c = LidGuard(); probe.bootstrapFails = true
    check(!c.setLoginItem(true), "failed launchctl bootstrap is not reported successful")
    check(!FileManager.default.fileExists(atPath: kLoginAgent), "failed new login registration rolls back file")
    probe.bootstrapFails = false
    check(c.setLoginItem(true) && probe.lastLoginPath == Bundle.main.bundleURL.path, "login item uses the current app location")
    probe.bootoutFails = true
    check(!c.setLoginItem(false) && FileManager.default.fileExists(atPath: kLoginAgent), "failed login removal keeps truthful state")
    probe.bootoutFails = false
    check(c.setLoginItem(false), "successful login removal verifies unload")
}
reset()
do {
    let c = LidGuard()
    check(!c.originalStartWatchdog(), "actual process launch failure is reported")
    probe.helperPath = testRoot + "/ReadyHelper"
    check(c.originalStartWatchdog() && c.watchdog?.isRunning == true, "actual watchdog ready handshake and ownership write")
    let child = c.watchdog!
    c.originalStopWatchdog()
    let deadline = Date(timeIntervalSinceNow: 1)
    while child.isRunning && Date() < deadline { usleep(10_000) }
    check(!child.isRunning, "watchdog stop terminates only the held test child")
}
reset()
do {
    let payload = "a'b $HOME `uname` \\ \"\nline"
    check(originalRunTask("/bin/sh", ["-c", "printf %s " + shellQuote(payload)]).out == payload, "shell quoting preserves literal metacharacters")
    let returned = originalRunTask("/usr/bin/osascript", ["-e", "return " + appleScriptQuote(payload)])
    check(returned.code == 0 && returned.out == payload + "\n", "AppleScript quoting round trips without executing payload")
    check(grantInstallScript(user: "bad;name") == nil && grantInstallScript(user: "bad\nname") == nil && grantInstallScript(user: "name\n") == nil, "unsafe sudoers usernames rejected")
    let script = grantInstallScript(user: "test-user")!
    let scriptPath = testRoot + "/install-syntax-only.sh"
    try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
    check(originalRunTask("/bin/sh", ["-n", scriptPath]).code == 0, "inline privileged script shell syntax validated without execution")
    let c = LidGuard(); check(c.installGrant().ok, "mocked inline grant installation verifies authorization")
    check(!(probe.privilegedSource ?? "").contains("lidguard-install.sh") && script.contains("/private/etc/.lidguard."), "admin execution never reads user-writable installation files")
    let before = ProcessInfo.processInfo.systemUptime
    check(originalRunTask("/bin/sleep", ["2"], timeout: 0.1).code == -2, "hung child is bounded by timeout")
    check(ProcessInfo.processInfo.systemUptime - before < 1, "timeout does not wait for child normal completion")
    check(originalRunTask("/usr/bin/printf", ["hello"]).out == "hello", "subprocess output captured")
}
reset()
do {
    probe.rawPowerOutput = "SleepDisabled 10\n"
    check(currentSleepDisabled() == nil, "invalid system state is unknown rather than substring true")
}
print("\(passed) assertions passed; system power, admin execution and login operations were mocked.")
'''
    original_global = '\n'.join(originals[:2])
    original_methods = '\nextension LidGuard {\n' + '\n'.join(originals[2:]) + '\n}\n'
    generated = root / 'Regression.swift'
    generated.write_text(prefix + source + original_global + original_methods + tests)
    helper_source = root / 'ReadyHelper.swift'
    helper_source.write_text('import Foundation\nFileHandle.standardOutput.write(Data("ready\\n".utf8))\nwhile true { usleep(100_000) }\n')
    bundle = root / 'Regression.app'
    binary = bundle / 'Contents/MacOS/Regression'
    binary.parent.mkdir(parents=True)
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'invalid.lidguard.regression','CFBundleExecutable':'Regression','CFBundlePackageType':'APPL'}))
    subprocess.run([SWIFTC, '-O', '-sdk', SDK, '-o', str(root/'ReadyHelper'), str(helper_source)], check=True)
    subprocess.run([SWIFTC, '-O', '-sdk', SDK, '-framework', 'Cocoa', '-o', str(binary), str(generated)], check=True)
    subprocess.run([str(binary), str(root)], check=True, timeout=30)

subprocess.run([os.environ.get('PYTHON', __import__('sys').executable), str(REPO/'tests/watchdog-test.py')], check=True)
