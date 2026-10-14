// 悬浮球设计稿（7 版）渲染器 —— 只用于出设计稿，不影响 App
// 用法: swiftc -O -module-cache-path .modulecache -o build/ball-designs tools/ball-designs.swift && ./build/ball-designs out.png
import AppKit
import Foundation

// MARK: - 工具

private func hx(_ s: String) -> NSColor {
    var t = s
    if t.hasPrefix("#") { t.removeFirst() }
    let v = UInt32(t, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                   green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

private func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
                  color: NSColor, mono: Bool = false, align: Align = .left, box: CGFloat = 0) {
    let f = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                 : NSFont.systemFont(ofSize: size, weight: weight)
    let str = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color])
    let sz = str.size()
    var px = x
    switch align {
    case .left: break
    case .center: px = x + (box - sz.width) / 2
    case .right: px = x + box - sz.width
    }
    str.draw(at: NSPoint(x: px, y: y))
}

private enum Align { case left, center, right }

private func circlePath(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

/// 在裁剪区内做径向渐变（注意：NSGradient 的 fromCenter 版本填充的是当前裁剪区）
private func radialFill(_ path: NSBezierPath, from: NSPoint, fromR: CGFloat,
                        to: NSPoint, toR: CGFloat, colors: [NSColor]) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: colors)?.draw(fromCenter: from, radius: fromR, toCenter: to, radius: toR, options: [])
    NSGraphicsContext.restoreGraphicsState()
}

/// 柔和光斑：用多层同心椭圆叠加模拟高斯衰减（不会出现硬边或径向渐变奇点）
private func softBlob(center: NSPoint, radius: CGFloat, aspect: CGFloat = 1,
                      color: NSColor, steps: Int = 30, peak: CGFloat = 0.5) {
    for i in stride(from: steps, through: 1, by: -1) {
        let t = CGFloat(i) / CGFloat(steps)
        let a = peak * pow(1 - t, 2.0)
        if a < 0.004 { continue }
        let rr = radius * t
        color.withAlphaComponent(a).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - rr, y: center.y - rr * aspect,
                                    width: rr * 2, height: rr * 2 * aspect)).fill()
    }
}

// MARK: - 演示数据

private let DOWN = "8.4"
private let UP = "1.2"
private let TOTAL = "9.6"

// MARK: - 1. 灵动岛胶囊

private func drawIsland(rect: NSRect) {
    let h: CGFloat = 58
    let w: CGFloat = 186
    let r = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)

    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.45)
    sh.shadowBlurRadius = 14; sh.shadowOffset = NSSize(width: 0, height: 6); sh.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
    NSGraphicsContext.restoreGraphicsState()

    // 内侧高光边
    NSColor(white: 1, alpha: 0.10).setStroke()
    let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: h / 2, yRadius: h / 2)
    edge.lineWidth = 1; edge.stroke()

    text("↓", x: r.minX + 15, y: r.minY + 13, size: 14, weight: .semibold, color: hx("#4FC3F7"))
    text(DOWN, x: r.minX + 30, y: r.minY + 13, size: 17, weight: .semibold, color: .white, mono: true)

    NSColor(white: 1, alpha: 0.14).setFill()
    NSRect(x: r.midX - 4, y: r.minY + 16, width: 1, height: h - 32).fill()

    text("↑", x: r.midX + 6, y: r.minY + 13, size: 14, weight: .semibold, color: hx("#FFB74D"))
    text(UP, x: r.midX + 21, y: r.minY + 13, size: 17, weight: .semibold, color: .white, mono: true)

    // 右侧微型曲线
    let spark = NSRect(x: r.maxX - 40, y: r.midY - 9, width: 28, height: 18)
    let pts: [CGFloat] = [0.2, 0.5, 0.35, 0.8, 0.6, 1.0, 0.45, 0.7]
    let p = NSBezierPath(); p.lineWidth = 1.6; p.lineCapStyle = .round
    for (i, v) in pts.enumerated() {
        let pt = NSPoint(x: spark.minX + spark.width * CGFloat(i) / CGFloat(pts.count - 1),
                         y: spark.maxY - spark.height * v)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    hx("#4FC3F7").setStroke(); p.stroke()
}

// MARK: - 2. 毛玻璃球

private func drawGlass(center c: NSPoint, r: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.35)
    sh.shadowBlurRadius = 18; sh.shadowOffset = NSSize(width: 0, height: 8); sh.set()
    NSColor(white: 1, alpha: 0.16).setFill()
    circlePath(c, r).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor(white: 1, alpha: 0.42).setStroke()
    let edge = circlePath(c, r - 0.75); edge.lineWidth = 1.5; edge.stroke()

    // 顶部弧形高光
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r - 8, startAngle: 200, endAngle: 340, clockwise: false)
    arc.lineWidth = 2.5; arc.lineCapStyle = .round
    NSColor(white: 1, alpha: 0.35).setStroke(); arc.stroke()

    // 底部反弹光
    let arc2 = NSBezierPath()
    arc2.appendArc(withCenter: c, radius: r - 7, startAngle: 30, endAngle: 150, clockwise: false)
    arc2.lineWidth = 2; arc2.lineCapStyle = .round
    hx("#7BE0FF").withAlphaComponent(0.35).setStroke(); arc2.stroke()

    // 磨砂颗粒（固定种子，出图可复现）
    NSGraphicsContext.saveGraphicsState()
    circlePath(c, r - 2).addClip()
    var seed: UInt64 = 20261013
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 1000) / 1000 }
    for _ in 0..<420 {
        let a = rnd() * 2 * .pi
        let rr = pow(rnd(), 0.5) * (r - 4)
        let pt = NSPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
        NSColor(white: 1, alpha: 0.05 + rnd() * 0.07).setFill()
        NSRect(x: pt.x, y: pt.y, width: 1.4, height: 1.4).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    text(TOTAL, x: 0, y: c.y - 26, size: 30, weight: .semibold, color: .white, mono: true, align: .center, box: c.x * 2)
    text("M/s", x: c.x, y: c.y + 4, size: 11, weight: .medium, color: NSColor(white: 1, alpha: 0.7), align: .center, box: 0)
    text("↓\(DOWN)   ↑\(UP)", x: 0, y: c.y + 24, size: 11, weight: .medium,
         color: NSColor(white: 1, alpha: 0.85), mono: true, align: .center, box: c.x * 2)
}

// MARK: - 3. 健康三环

private func drawRings(center c: NSPoint, r: CGFloat) {
    NSColor(white: 0.07, alpha: 0.92).setFill()
    circlePath(c, r).fill()
    NSColor(white: 1, alpha: 0.10).setStroke()
    let edge = circlePath(c, r - 0.5); edge.lineWidth = 1; edge.stroke()

    let rings: [(CGFloat, String, CGFloat, NSColor)] = [
        (r - 10, "#4FC3F7", 0.78, hx("#4FC3F7")),
        (r - 22, "#FFB74D", 0.52, hx("#FFB74D")),
        (r - 34, "#81E06B", 0.30, hx("#81E06B")),
    ]
    for (radius, _, frac, color) in rings {
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 7
        color.withAlphaComponent(0.16).setStroke(); track.stroke()

        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: radius, startAngle: -90, endAngle: -90 + 360 * frac, clockwise: false)
        arc.lineWidth = 7; arc.lineCapStyle = .round
        color.setStroke(); arc.stroke()
    }

    text(TOTAL, x: 0, y: c.y - 22, size: 22, weight: .bold, color: .white, mono: true, align: .center, box: c.x * 2)
    text("M/s", x: 0, y: c.y + 2, size: 10, weight: .medium,
         color: NSColor(white: 0.6, alpha: 1), align: .center, box: c.x * 2)
}

// MARK: - 4. 极简弧线

private func drawMinimalArc(center c: NSPoint, r: CGFloat) {
    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: r - 6, startAngle: -230, endAngle: 50)
    track.lineWidth = 3
    NSColor(white: 1, alpha: 0.12).setStroke(); track.stroke()

    let sweep: CGFloat = 280 * 0.62
    for (i, col) in [hx("#4FC3F7"), hx("#5FD8B0"), hx("#81E06B")].enumerated() {
        let seg = NSBezierPath()
        let a0 = -230 + sweep * CGFloat(i) / 3
        seg.appendArc(withCenter: c, radius: r - 6, startAngle: a0, endAngle: a0 + sweep / 3 + 0.5, clockwise: false)
        seg.lineWidth = 3.5; seg.lineCapStyle = .round
        col.setStroke(); seg.stroke()
    }

    text(TOTAL, x: 0, y: c.y - 24, size: 32, weight: .light, color: .white, mono: true, align: .center, box: c.x * 2)
    text("MB/s", x: 0, y: c.y + 8, size: 11, weight: .medium,
         color: NSColor(white: 0.65, alpha: 1), align: .center, box: c.x * 2)
    text("↓\(DOWN) ↑\(UP)", x: 0, y: c.y + 28, size: 10, weight: .medium,
         color: NSColor(white: 0.5, alpha: 1), mono: true, align: .center, box: c.x * 2)
}

// MARK: - 5. 精修玻璃球（360 语言现代化）

private func drawRefinedSphere(center c: NSPoint, r: CGFloat) {
    let sphere = circlePath(c, r)

    // 外发光
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow(); glow.shadowColor = hx("#3E9B0F").withAlphaComponent(0.5)
    glow.shadowBlurRadius = 16; glow.shadowOffset = .zero; glow.set()
    hx("#2E7D0C").setFill(); sphere.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 球体主渐变：对角线性（左上亮 → 右下暗），比径向渐变稳，不会有奇点
    NSGradient(colors: [hx("#C6F27A"), hx("#7FD334"), hx("#3E9B0F"), hx("#1B5E07")])?
        .draw(in: sphere, angle: 60)

    // 底部反弹光（玻璃球的灵魂）
    NSGraphicsContext.saveGraphicsState()
    sphere.addClip()
    softBlob(center: NSPoint(x: c.x, y: c.y + r * 0.68), radius: r * 0.78,
             aspect: 0.34, color: hx("#DCFAA8"), peak: 0.30)
    NSGraphicsContext.restoreGraphicsState()

    // 主高光：裁剪到椭圆内再填竖向渐变
    NSGraphicsContext.saveGraphicsState()
    sphere.addClip()
    softBlob(center: NSPoint(x: c.x - r * 0.34, y: c.y - r * 0.44), radius: r * 0.62,
             aspect: 0.72, color: .white, peak: 0.42)
    softBlob(center: NSPoint(x: c.x - r * 0.46, y: c.y - r * 0.60), radius: r * 0.22,
             aspect: 0.62, color: .white, peak: 0.75)
    NSGraphicsContext.restoreGraphicsState()

    // 边缘内阴影
    NSGraphicsContext.saveGraphicsState()
    sphere.addClip()
    NSColor(white: 0, alpha: 0.18).setStroke()
    let inner = circlePath(c, r - 1); inner.lineWidth = 2; inner.stroke()
    NSGraphicsContext.restoreGraphicsState()

    text(TOTAL, x: 0, y: c.y - 24, size: 28, weight: .bold, color: .white, mono: true, align: .center, box: c.x * 2)
    text("M/s", x: 0, y: c.y + 4, size: 10, weight: .medium,
         color: NSColor(white: 1, alpha: 0.8), align: .center, box: c.x * 2)
    text("↓\(DOWN) ↑\(UP)", x: 0, y: c.y + 22, size: 10.5, weight: .semibold,
         color: NSColor(white: 1, alpha: 0.92), mono: true, align: .center, box: c.x * 2)
}

// MARK: - 6. 霓虹球

private func drawNeon(center c: NSPoint, r: CGFloat) {
    NSColor(white: 0.05, alpha: 0.96).setFill()
    circlePath(c, r).fill()

    // 发光描边（多层叠加模拟 glow）
    let ring = circlePath(c, r - 3)
    for (w, a) in [(CGFloat(10), CGFloat(0.06)), (7, 0.10), (4.5, 0.22), (2.2, 0.95)] {
        ring.lineWidth = w
        hx("#31E1F7").withAlphaComponent(a).setStroke()
        ring.stroke()
    }
    let ring2 = circlePath(c, r - 13)
    ring2.lineWidth = 1.5
    hx("#B14EFF").withAlphaComponent(0.7).setStroke()
    ring2.stroke()

    text(TOTAL, x: 0, y: c.y - 24, size: 29, weight: .bold, color: .white, mono: true, align: .center, box: c.x * 2)
    text("M/s", x: 0, y: c.y + 4, size: 10, weight: .medium, color: hx("#31E1F7"), align: .center, box: c.x * 2)
    text("↓\(DOWN) ↑\(UP)", x: 0, y: c.y + 22, size: 10.5, weight: .medium,
         color: NSColor(white: 0.7, alpha: 1), mono: true, align: .center, box: c.x * 2)
}

// MARK: - 7. 迷你曲线胶囊

private func drawSparkPill(rect: NSRect) {
    let h: CGFloat = 52
    let w: CGFloat = 176
    let r = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)

    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.3)
    sh.shadowBlurRadius = 12; sh.shadowOffset = NSSize(width: 0, height: 5); sh.set()
    NSColor(white: 1, alpha: 0.14).setFill()
    NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.30).setStroke()
    let e = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: h / 2, yRadius: h / 2)
    e.lineWidth = 1.5; e.stroke()

    text("↓", x: r.minX + 14, y: r.minY + 10, size: 12, weight: .semibold, color: hx("#4FC3F7"))
    text(DOWN, x: r.minX + 27, y: r.minY + 10, size: 16, weight: .semibold, color: .white, mono: true)
    text("↑", x: r.minX + 14, y: r.minY + 29, size: 12, weight: .semibold, color: hx("#FFB74D"))
    text(UP, x: r.minX + 27, y: r.minY + 29, size: 16, weight: .semibold, color: .white, mono: true)

    // 面积曲线
    let chart = NSRect(x: r.minX + 78, y: r.minY + 10, width: r.width - 96, height: r.height - 20)
    let vals: [CGFloat] = [0.25, 0.45, 0.3, 0.75, 0.55, 0.9, 0.4, 0.65, 0.5, 0.8]
    let area = NSBezierPath()
    area.move(to: NSPoint(x: chart.minX, y: chart.maxY))
    for (i, v) in vals.enumerated() {
        area.line(to: NSPoint(x: chart.minX + chart.width * CGFloat(i) / CGFloat(vals.count - 1),
                              y: chart.maxY - chart.height * v))
    }
    area.line(to: NSPoint(x: chart.maxX, y: chart.maxY))
    area.close()
    hx("#4FC3F7").withAlphaComponent(0.35).setFill(); area.fill()
    let line = NSBezierPath()
    for (i, v) in vals.enumerated() {
        let pt = NSPoint(x: chart.minX + chart.width * CGFloat(i) / CGFloat(vals.count - 1),
                         y: chart.maxY - chart.height * v)
        i == 0 ? line.move(to: pt) : line.line(to: pt)
    }
    line.lineWidth = 1.6; line.lineCapStyle = .round
    hx("#7BE0FF").setStroke(); line.stroke()
}

// MARK: - 出图

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ball-designs.png"

let cols = 3, rows = 3
let cellW: CGFloat = 400, cellH: CGFloat = 320
let W = cellW * CGFloat(cols), H = cellH * CGFloat(rows) + 70
let scale: CGFloat = CGFloat(Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "2") ?? 2)

let designs: [(String, String, (NSRect) -> Void)] = [
    ("灵动岛胶囊", "深色药丸 + 上下行 + 迷你曲线，最现代", { r in drawIsland(rect: r) }),
    ("毛玻璃球", "半透明磨砂 + 描边高光，通透", { r in drawGlass(center: NSPoint(x: r.midX, y: r.midY), r: 62) }),
    ("健康三环", "三圈进度环，信息密度最高", { r in drawRings(center: NSPoint(x: r.midX, y: r.midY), r: 62) }),
    ("极简弧线", "只有一段弧 + 数字，几乎隐形", { r in drawMinimalArc(center: NSPoint(x: r.midX, y: r.midY), r: 62) }),
    ("精修玻璃球", "360 球体语言的现代化版本", { r in drawRefinedSphere(center: NSPoint(x: r.midX, y: r.midY), r: 62) }),
    ("霓虹球", "暗底 + 霓虹描边发光，赛博风", { r in drawNeon(center: NSPoint(x: r.midX, y: r.midY), r: 62) }),
    ("曲线胶囊", "药丸 + 面积曲线，兼顾趋势", { r in drawSparkPill(rect: r) }),
]

let img = NSImage(size: NSSize(width: W, height: H), flipped: true) { _ in
    // 模拟桌面：一张有明暗层次的渐变，便于看透明/发光效果
    NSGradient(colors: [hx("#20303F"), hx("#2C4257"), hx("#16222E")])?
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -55)
    for (col, alpha, rect) in [(hx("#31E1F7"), CGFloat(0.05), NSRect(x: W * 0.58, y: H * 0.30, width: 520, height: 520)),
                               (hx("#FF7AB6"), 0.045, NSRect(x: -120, y: H * 0.55, width: 460, height: 460)),
                               (hx("#3E9B0F"), 0.05, NSRect(x: W * 0.30, y: -140, width: 520, height: 520))] {
        col.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    text("悬浮球设计稿 · 7 版（\(scale == 1 ? "实际尺寸" : "放大 \(Int(scale)) 倍")）", x: 24, y: 18, size: 17, weight: .semibold, color: .white)
    text("数据统一用 ↓8.4M/s ↑1.2M/s；背景模拟桌面明暗，方便判断透明与发光效果",
         x: 24, y: 42, size: 12, weight: .regular, color: NSColor(white: 0.65, alpha: 1))

    for (i, d) in designs.enumerated() {
        let col = i % cols, row = i / cols
        let cell = NSRect(x: CGFloat(col) * cellW, y: 70 + CGFloat(row) * cellH, width: cellW, height: cellH)

        // 画布
        NSColor(white: 1, alpha: 0.045).setFill()
        NSBezierPath(roundedRect: cell.insetBy(dx: 10, dy: 10), xRadius: 14, yRadius: 14).fill()
        NSColor(white: 1, alpha: 0.08).setStroke()
        let b = NSBezierPath(roundedRect: cell.insetBy(dx: 10, dy: 10), xRadius: 14, yRadius: 14)
        b.lineWidth = 1; b.stroke()

        // 设计稿本体（2x）
        let inner = NSRect(x: cell.midX, y: cell.minY + 84, width: 0, height: 0)
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: inner.minX, yBy: inner.minY)
        t.scale(by: scale)
        t.concat()
        d.2(NSRect(x: -cellW / 2 / scale, y: -84 / scale, width: cellW / scale, height: cellH / scale))
        NSGraphicsContext.restoreGraphicsState()

        text("\(i + 1). \(d.0)", x: cell.minX + 26, y: cell.maxY - 56, size: 14, weight: .semibold, color: .white)
        text(d.1, x: cell.minX + 26, y: cell.maxY - 36, size: 11, weight: .regular,
             color: NSColor(white: 0.62, alpha: 1))
    }
    return true
}

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("渲染失败\n".data(using: .utf8)!)
    exit(1)
}
try? png.write(to: URL(fileURLWithPath: outPath))
print("designs -> \(outPath)  \(Int(W))x\(Int(H))")
