import AppKit

// 生成 休眠助手.app 的应用图标（1024x1024 PNG），随后用 sips + iconutil 转 .icns
// 主题：夜空渐变 + 柔光弯月（白）+ 点缀星，大厂风、精致。

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/appicon_1024.png"
let rect = NSRect(x: 0, y: 0, width: size, height: size)

let image = NSImage(size: rect.size, flipped: false) { _ in
    let s = rect.width

    // 背景：圆角方（macOS 图标规范圆角率 0.2237）
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2237, yRadius: s * 0.2237)
    bg.addClip()

    // 夜空渐变（上深、下略亮，垂直方向）
    let sky = NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.26, alpha: 1),
        NSColor(calibratedRed: 0.17, green: 0.21, blue: 0.45, alpha: 1)
    ])
    sky?.draw(in: rect, angle: 90)

    // 月亮周围的柔光（径向渐变）
    let moonC = NSPoint(x: s * 0.50, y: s * 0.52)
    let relX = (moonC.x - s / 2) / (s / 2)
    let relY = (moonC.y - s / 2) / (s / 2)
    let glow = NSGradient(colors: [
        NSColor(calibratedWhite: 1.0, alpha: 0.18),
        NSColor(calibratedWhite: 1.0, alpha: 0.0)
    ])
    glow?.draw(in: rect, relativeCenterPosition: NSPoint(x: relX, y: relY))

    // 弯月（白）：外圆 R，再用等半径、向「右上」偏移 d=0.85R 的内圆擦除，
    // 得到厚度约 0.85R 的弯月（非零规则/反向子路径会被 AppKit 归一化，故用 clear 擦除）。
    let k = s / 18.0
    let R: CGFloat = 5.0 * k
    let outerC = NSPoint(x: 9.0 * k, y: 9.0 * k)
    let d: CGFloat = 0.85 * R
    let innerC = NSPoint(x: outerC.x + d / sqrt(2), y: outerC.y + d / sqrt(2))
    func disk(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    if let ctx = NSGraphicsContext.current {
        // clip 到外圆，再以「矩形 − 内圆」(even-odd) 填充 → 外圆减内圆 = 弯月。
        // 比 clear 合成更稳定，且**不要预填外圆**（否则白色叠白色看不出切口）。
        ctx.saveGraphicsState()
        disk(outerC, R).addClip()
        let cut = NSBezierPath(rect: rect)
        cut.append(disk(innerC, R))
        cut.windingRule = .evenOdd
        NSColor.white.setFill()
        cut.fill()
        ctx.restoreGraphicsState()
    }

    // 点缀星（带柔光），放在月亮开口一侧的夜空里
    let stars: [(CGFloat, CGFloat, CGFloat)] = [
        (0.795, 0.760, 0.030),
        (0.880, 0.610, 0.021),
        (0.720, 0.185, 0.016),
        (0.170, 0.815, 0.014)
    ]
    for spec in stars {
        let c = NSPoint(x: spec.0 * s, y: spec.1 * s)
        let r = spec.2 * s
        let halo = NSBezierPath(ovalIn: NSRect(x: c.x - r * 3, y: c.y - r * 3, width: r * 6, height: r * 6))
        NSColor.white.withAlphaComponent(0.12).setFill()
        halo.fill()
        let star = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        NSColor.white.setFill()
        star.fill()
    }

    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else {
    print("FAILED to render")
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: outPath))
    print("written \(outPath)")
} catch {
    print("write error: \(error)")
    exit(1)
}
