// probe-lock2.swift —— 强制尝试加载框架并查找锁屏符号；只探测，绝不调用
import Foundation

let paths = [
    "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
    "/System/Library/PrivateFrameworks/login.framework/login",
    "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
    "/System/Library/PrivateFrameworks/LoginUIKit.framework/Versions/A/LoginUIKit",
    "/System/Library/PrivateFrameworks/LoginUIKit.framework/LoginUIKit",
    "/System/Library/PrivateFrameworks/ScreenSaver.framework/Versions/A/ScreenSaver",
]

let names = ["login", "LoginUIKit", "ScreenSaver"]

print("=== 方案一：按路径 dlopen ===")
for p in paths {
    let onDisk = FileManager.default.fileExists(atPath: p)
    if let h = dlopen(p, RTLD_LAZY) {
        let sym = dlsym(h, "SACLockScreenImmediate")
        print("  ✅ dlopen 成功 (磁盘上\(onDisk ? "有" : "没有")文件): \(p)")
        print("       SACLockScreenImmediate = \(sym == nil ? "无此符号" : "✅ 找到了！")")
        dlclose(h)
    } else {
        let err = String(cString: dlerror()!)
        print("  ❌ dlopen 失败 (磁盘上\(onDisk ? "有" : "没有")文件): \(p)")
        print("       \(err.split(separator: "\n").last ?? "")")
    }
}

print()
print("=== 方案二：按框架名 dlopen（走系统缓存解析）===")
for n in names {
    if let h = dlopen(n, RTLD_LAZY) {
        let sym = dlsym(h, "SACLockScreenImmediate")
        print("  ✅ \(n): 加载成功；SACLockScreenImmediate = \(sym == nil ? "无此符号" : "✅ 找到了！")")
        dlclose(h)
    } else {
        print("  ❌ \(n): 加载失败")
    }
}

print()
print("=== 方案三：dlopen 主可执行文件符号空间（RTLD_DEFAULT）===")
if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SACLockScreenImmediate") {
    print("  ✅ 在全局符号空间里找到: \(sym)")
} else {
    print("  ❌ 全局符号空间里没有")
}
