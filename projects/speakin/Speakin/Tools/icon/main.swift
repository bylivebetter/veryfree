// Generates the AppIcon set: a dark squircle with a white microphone and a red "recording" dot.
// Run: Tools/make-icon.sh

import AppKit

@MainActor
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = size
    // macOS icon grid: the squircle sits inside a ~10% margin.
    let inset = s * 0.0976
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
    path.fill()
    NSShadow().set()

    let gradient = NSGradient(colors: [NSColor(calibratedWhite: 0.22, alpha: 1), NSColor(calibratedWhite: 0.09, alpha: 1)])!
    gradient.draw(in: path, angle: -90)

    // Microphone glyph.
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .medium)
    if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: mic.size, flipped: false) { r in
            mic.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2 + s * 0.01, width: w, height: h))
    }

    // Recording dot, bottom-right.
    let d = s * 0.17
    let dot = NSRect(x: rect.maxX - d * 1.35, y: rect.minY + d * 0.4, width: d, height: d)
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot.insetBy(dx: -d * 0.12, dy: -d * 0.12)).fill()
    NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()

    image.unlockFocus()
    return image
}

@MainActor
func run() throws {
    let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let entries: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
    var images: [[String: Any]] = []
    for (pt, scale) in entries {
        let px = pt * scale
        let icon = drawIcon(size: CGFloat(px))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(pt)x\(pt)@\(scale)x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
    }
    let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outDir.appendingPathComponent("Contents.json"))
    print("wrote \(entries.count) icons to \(outDir.path)")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
try MainActor.assumeIsolated { try run() }
