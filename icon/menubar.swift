import AppKit

// 渲染菜单栏弯月图标两种状态，放大 8 倍便于肉眼检查
// 用法：menubaron / menubaroff

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "on"
let on = (mode == "on")
let scale: CGFloat = 8
let base: CGFloat = 18
let size = base * scale
let out = mode == "on" ? "/tmp/menubar_on.png" : "/tmp/menubar_off.png"

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
    let s = rect.width

    NSColor.clear.set()
    rect.fill()

    let k = s / 18.0
    let R: CGFloat = 7.0 * k
    let rIn: CGFloat = 6.2 * k
    let outerC = NSPoint(x: 9.0 * k, y: 9.0 * k)
    let innerC = NSPoint(x: 11.9 * k, y: 6.1 * k)

    func disk(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    if on {
        NSColor(calibratedRed: 1.00, green: 0.70, blue: 0.16, alpha: 1).setFill()
    } else {
        NSColor(calibratedWhite: 0.45, alpha: 1).setFill()
    }
    disk(outerC, R).fill()

    if let ctx = NSGraphicsContext.current {
        ctx.saveGraphicsState()
        ctx.compositingOperation = .clear
        NSColor.black.setFill()
        disk(innerC, rIn).fill()
        ctx.restoreGraphicsState()
    }
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? data.write(to: URL(fileURLWithPath: out))
print("written \(out)")
