import Cocoa


var count: UInt32 = 0
let e1 = CGGetOnlineDisplayList(0, nil, &count)
print("CGGetOnlineDisplayList(count only) -> err=\(e1.rawValue) count=\(count)")

var ids = [CGDirectDisplayID](repeating: 0, count: max(Int(count), 1))
var n: UInt32 = 0
let e2 = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &n)
print("CGGetOnlineDisplayList(list) -> err=\(e2.rawValue) n=\(n)")
for i in 0..<Int(n) {
    let b = CGDisplayIsBuiltin(ids[i])
    print("  id=\(ids[i]) isBuiltin=\(b) main=\(CGDisplayIsMain(ids[i]))")
}

print("NSScreen count=\(NSScreen.screens.count)")
for s in NSScreen.screens {
    print("  screen=\(s.localizedName) size=\(s.frame.size)")
}

#if arch(x86_64)
print("ARCH=x86_64")
#else
print("ARCH=arm64")
#endif
