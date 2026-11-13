// Draws the app icon and writes Resources/Limitbar.icns. Run: swift scripts/make-icon.swift (from the repo root).
// Two white gauges on Claude orange: the session and weekly limits, one nearly full.
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: an 824 pt rounded square centred on 1024, corner radius about 185.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s); shadow.shadowBlurRadius = 20 * s
    NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.black.setFill(); shape.fill(); NSGraphicsContext.restoreGraphicsState()
    let rgb = { (r: Int, g: Int, b: Int) in NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    NSGradient(starting: rgb(0xE5, 0x8C, 0x6E), ending: rgb(0xC9, 0x63, 0x42))!.draw(in: shape, angle: -90)
    // Two gauges: a track and a fill, thick enough to read at 16 px.
    let barH: CGFloat = 150 * s, left: CGFloat = 230 * s, width: CGFloat = 564 * s
    for (y, frac) in [(CGFloat(574), CGFloat(0.82)), (CGFloat(300), CGFloat(0.45))] {
        let track = NSRect(x: left, y: y * s, width: width, height: barH)
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: left, y: y * s, width: width * frac, height: barH), xRadius: barH / 2, yRadius: barH / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let set = FileManager.default.temporaryDirectory.appendingPathComponent("Limitbar-\(getpid()).iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(base * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("Resources/Limitbar.icns")
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(out.path)")
