#!/usr/bin/env python3
"""Exercise the production watchdog loop with file-backed, mocked power commands."""
from pathlib import Path
import json
import fcntl
import os
import shutil
import signal
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
SOURCE = (REPO / 'main.swift').read_text()
CLT = Path(os.environ.get('CLT_DIR', '/Library/Developer/CommandLineTools'))


def function(signature):
    start = SOURCE.index(signature)
    opening = SOURCE.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        if SOURCE[end] == '{': depth += 1
        if SOURCE[end] == '}': depth -= 1
        end += 1
    return SOURCE[start:end]


with tempfile.TemporaryDirectory(prefix='lidguard-watchdog-test-') as temp:
    root = Path(temp)
    prefix = r'''
import Cocoa
let testRoot = ProcessInfo.processInfo.environment["LIDGUARD_TEST_ROOT"]!
let kWatchOwnerFile = testRoot + "/owner"
let kPowerLockFile = testRoot + "/power.lock"
let kSudo = "/usr/bin/sudo"
let kPmset = "/usr/bin/pmset"
func logEvent(_ message: String) {}
func runTask(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
    if path == kPmset && args == ["-g"] {
        let state = try! String(contentsOfFile: testRoot + "/state", encoding: .utf8)
        return (0, "SleepDisabled " + state + "\n")
    }
    guard path == kSudo && args.last == "0" else { fatalError("Unmocked command blocked") }
    let log = testRoot + "/attempts"
    let h = FileHandle(forWritingAtPath: log)!
    h.seekToEndOfFile(); h.write(Data("mock restore\n".utf8)); h.closeFile()
    if let delay = try? String(contentsOfFile: testRoot + "/delay", encoding: .utf8), delay == "yes" { usleep(300_000) }
    let remaining = Int(try! String(contentsOfFile: testRoot + "/failures", encoding: .utf8))!
    if remaining > 0 {
        try! String(remaining-1).write(toFile: testRoot + "/failures", atomically: true, encoding: .utf8)
        return (1, "mock permission failure")
    }
    try! "0".write(toFile: testRoot + "/state", atomically: true, encoding: .utf8)
    return (0, "mock success")
}
'''
    prefix += '\n'.join(function(s) for s in ['func executablePath(', 'func isAlive(', 'func selfExecutablePath(', 'func shellLine(', 'func currentSleepDisabled(', 'func withPowerLock(', 'func restoreSleepOnce('])
    prefix += r'''
if CommandLine.arguments.contains("--test-parent") {
    // Reproduce the main App's SIG_IGN inheritance, then let the watchdog reset it.
    signal(SIGTERM, SIG_IGN)
    let owner = UUID().uuidString
    let child = Process(); let ready = Pipe()
    child.executableURL = URL(fileURLWithPath: selfExecutablePath() + ".Watchdog")
    child.arguments = ["--watchdog", "\(getpid())", selfExecutablePath(), owner]
    child.standardOutput = ready
    child.standardError = FileHandle.nullDevice
    try! child.run()
    ready.fileHandleForWriting.closeFile()
    guard String(data: ready.fileHandleForReading.availableData, encoding: .utf8) == "ready\n" else { exit(3) }
    try! owner.write(toFile: kWatchOwnerFile, atomically: true, encoding: .utf8)
    print(child.processIdentifier); fflush(stdout)
    while true { usleep(100_000) }
}
'''
    start = SOURCE.index('if let i = CommandLine.arguments.firstIndex(of: "--watchdog")')
    end = SOURCE.index('let app = NSApplication.shared', start)
    prefix += SOURCE[start:end]
    code = root / 'Watchdog.swift'
    code.write_text(prefix)
    executable = root / ('LGTest' + str(os.getpid()))
    subprocess.run([os.environ.get('SWIFTC', str(CLT/'usr/bin/swiftc')), '-O', '-sdk', os.environ.get('SDK_PATH', str(CLT/'SDKs/MacOSX.sdk')), '-framework', 'Cocoa', '-o', str(executable), str(code)], check=True)
    shutil.copy2(executable, str(executable) + '.Watchdog')

    def gone(pid):
        try: os.kill(pid, 0); return False
        except ProcessLookupError: return True

    results = []
    for case, failures in [('retry_after_main_name_kill', 2), ('replacement_owner_stops_old_restore', 100), ('owner_handoff_waits_for_inflight_restore', 0), ('normal_watchdog_stop', 0)]:
        case_dir = root / case
        case_dir.mkdir()
        for filename, value in [('state', '1'), ('failures', str(failures)), ('attempts', '')]:
            (case_dir / filename).write_text(value)
        if case == 'owner_handoff_waits_for_inflight_restore': (case_dir/'delay').write_text('yes')
        parent = subprocess.Popen([str(executable), '--test-parent'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, env={**os.environ, 'LIDGUARD_TEST_ROOT':str(case_dir)})
        line = parent.stdout.readline()
        if not line:
            error = parent.stderr.read()
            raise AssertionError('test parent could not start watchdog: ' + error)
        child = int(line)
        try:
            if case == 'normal_watchdog_stop':
                os.kill(child, signal.SIGTERM)
            else:
                # Unique test name, different from both installed App executables.
                subprocess.run(['/usr/bin/killall', '-KILL', executable.name], check=True)
                parent.wait(timeout=2)
                if case in ('replacement_owner_stops_old_restore', 'owner_handoff_waits_for_inflight_restore'):
                    deadline = time.monotonic() + 2
                    while not (case_dir/'attempts').read_text() and time.monotonic() < deadline: time.sleep(0.02)
                    with (case_dir/'power.lock').open('a') as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX)
                        (case_dir/'owner').write_text('new-owner')
                        if case == 'owner_handoff_waits_for_inflight_restore': (case_dir/'state').write_text('1')
            deadline = time.monotonic() + 4
            while not gone(child) and time.monotonic() < deadline: time.sleep(0.02)
            assert gone(child), case + ': child failed to exit'
            attempts = len((case_dir/'attempts').read_text().splitlines())
            state = (case_dir/'state').read_text()
            if case == 'retry_after_main_name_kill': assert attempts == 3 and state == '0', (attempts, state)
            if case == 'replacement_owner_stops_old_restore': assert attempts >= 1 and state == '1', (attempts, state)
            if case == 'owner_handoff_waits_for_inflight_restore': assert attempts == 1 and state == '1', (attempts, state)
            if case == 'normal_watchdog_stop': assert attempts == 0, attempts
            results.append({'scenario':case, 'restoreAttempts':attempts, 'mockSleepDisabled':state})
        finally:
            if parent.poll() is None: parent.kill(); parent.wait(timeout=2)
            if not gone(child): os.kill(child, signal.SIGKILL)
    print(json.dumps(results, indent=2))
    print('4 watchdog process scenarios passed; no sudo or pmset was executed.')
