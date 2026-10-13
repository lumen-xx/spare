import AppKit
// Draws Spare's 1024 px icon, then scales it into an iconset: an open ring, like a disk with room freed, and a spark
// where the gap is. Usage: swift scripts/icon.swift <outputDir>
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Spare.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func master() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); shape.fill()
    ctx.restoreGState()
    shape.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.38, alpha: 1),
                        NSColor(calibratedRed: 0.02, green: 0.12, blue: 0.16, alpha: 1)])!.draw(in: tile, angle: -60)
    // A soft light behind the ring.
    NSGradient(colors: [NSColor(calibratedRed: 0.35, green: 0.95, blue: 0.75, alpha: 0.35), .clear])!
        .draw(fromCenter: NSPoint(x: 512, y: 500), radius: 0, toCenter: NSPoint(x: 512, y: 500), radius: 400, options: [])

    let center = CGPoint(x: 512, y: 500), radius: CGFloat = 230
    // The ring: most of a circle, open at the upper right.
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 364, clockwise: false)
    ring.lineWidth = 86
    ring.lineCapStyle = .round
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.setStroke()
    ring.stroke()
    ctx.restoreGState()

    // A four-pointed spark in the gap.
    let spark = CGPoint(x: center.x + radius * cos(.pi * 47 / 180), y: center.y + radius * sin(.pi * 47 / 180))
    let star = NSBezierPath()
    let long: CGFloat = 96, short: CGFloat = 20
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 2
        let length = i % 2 == 0 ? long : short
        let point = NSPoint(x: spark.x + cos(angle) * length, y: spark.y + sin(angle) * length)
        if i == 0 { star.move(to: point) } else { star.line(to: point) }
    }
    star.close()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: NSColor(calibratedRed: 0.6, green: 1, blue: 0.85, alpha: 0.9).cgColor)
    NSColor(calibratedRed: 0.85, green: 1, blue: 0.93, alpha: 1).setFill()
    star.fill()
    ctx.restoreGState()

    // Top sheen.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), .clear])!.draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let source = master()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
try source.representation(using: .png, properties: [:])!.write(to: directory.deletingLastPathComponent().appendingPathComponent("master.png"))
