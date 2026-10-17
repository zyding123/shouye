// make-icon.swift — 生成 LidGuard（守夜）的 App 图标
// 按苹果的图标网格绘制：1024 画布内留 100px 边距，圆角比例 0.2237
// 图形语义：一台合上的笔记本，缝里透出光 —— 盖子合着，但它还在工作

import AppKit

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func drawIcon(_ S: CGFloat) {
    let k = S / 1024.0

    // 1. 背景：夜间蓝的圆角方形
    let inset = 100.0 * k
    let bgRect = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let r = bgRect.width * 0.2237
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: r, yRadius: r)

    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.404, green: 0.478, blue: 0.965, alpha: 1.0),
        NSColor(srgbRed: 0.098, green: 0.129, blue: 0.376, alpha: 1.0),
    ])
    grad?.draw(in: bg, angle: -90)

    // 顶部极淡的柔光：用渐变而不是椭圆，避免出现生硬的边缘
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    if let top = NSGradient(colors: [NSColor.white.withAlphaComponent(0.13),
                                     NSColor.white.withAlphaComponent(0.0)]) {
        top.draw(in: bgRect, angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()

    // 2. 线描笔记本 —— 与菜单栏图标完全同一套语言
    NSColor.white.setStroke()

    // 机身（合上的盖子）
    let body = NSBezierPath(roundedRect: NSRect(x: 236 * k, y: 367 * k, width: 430 * k, height: 310 * k),
                            xRadius: 56 * k, yRadius: 56 * k)
    body.lineWidth = 44 * k
    body.stroke()

    // 底座前沿
    let lip = NSBezierPath()
    lip.move(to: NSPoint(x: 176 * k, y: 311 * k))
    lip.line(to: NSPoint(x: 726 * k, y: 311 * k))
    lip.lineWidth = 44 * k
    lip.lineCapStyle = .round
    lip.stroke()

    // 3. 青色圆点 —— 醒着的信号
    let badge = NSBezierPath(ovalIn: NSRect(x: 698 * k, y: 638 * k, width: 124 * k, height: 124 * k))
    NSColor(srgbRed: 0.478, green: 0.890, blue: 1.0, alpha: 1.0).setFill()
    badge.fill()
}

func render(_ px: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.shouldAntialias = true
    drawIcon(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (name, px) in sizes {
    guard let rep = render(px), let data = rep.representation(using: .png, properties: [:]) else {
        print("渲染失败：\(name)")
        continue
    }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

if let rep = render(1024), let d = rep.representation(using: .png, properties: [:]) {
    try? d.write(to: URL(fileURLWithPath: "\(outDir)/preview-1024.png"))
}

print("已输出到 \(outDir)")
