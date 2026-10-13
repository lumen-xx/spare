import AppKit
// Puts a window screenshot on Spare's background with a headline, for the README and announcements.
// Usage: swift scripts/marketing.swift <window.png> <out.png> <headline> <subtitle> [icon.png]
let arguments = CommandLine.arguments
let window = NSImage(contentsOf: URL(fileURLWithPath: arguments[1]))!
let output = URL(fileURLWithPath: arguments[2])
let headline = arguments[3], subtitle = arguments[4]
let icon = arguments.count > 5 ? NSImage(contentsOf: URL(fileURLWithPath: arguments[5])) : nil

let windowSize = window.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? window.size
let width = max(1600, windowSize.width + 240), top: CGFloat = 230
let height = top + windowSize.height + 40
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: width, height: height)
// The icon's colours: deep teal into near-black, with a soft light where the window sits.
NSGradient(colors: [NSColor(calibratedRed: 0.07, green: 0.36, blue: 0.33, alpha: 1), NSColor(calibratedRed: 0.02, green: 0.09, blue: 0.13, alpha: 1)])!
    .draw(in: canvas, angle: -70)
NSGradient(colors: [NSColor(calibratedRed: 0.35, green: 0.95, blue: 0.75, alpha: 0.20), .clear])!
    .draw(fromCenter: NSPoint(x: width / 2, y: height * 0.45), radius: 0, toCenter: NSPoint(x: width / 2, y: height * 0.45), radius: width * 0.55, options: [])

let center = NSMutableParagraphStyle()
center.alignment = .center
let title = NSAttributedString(string: headline, attributes: [.font: NSFont.systemFont(ofSize: 54, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: center])
let titleSize = title.size()
let iconSide: CGFloat = 64, gap: CGFloat = 18
let lineWidth = titleSize.width + (icon == nil ? 0 : iconSide + gap)
let lineX = (width - lineWidth) / 2, titleY = height - 70 - titleSize.height
if let icon {
    icon.draw(in: NSRect(x: lineX, y: titleY + (titleSize.height - iconSide) / 2 - 2, width: iconSide, height: iconSide))
}
title.draw(at: NSPoint(x: lineX + (icon == nil ? 0 : iconSide + gap), y: titleY))
let sub = NSAttributedString(string: subtitle, attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .regular),
                                                             .foregroundColor: NSColor.white.withAlphaComponent(0.72), .paragraphStyle: center])
sub.draw(in: NSRect(x: 60, y: titleY - 52, width: width - 120, height: 40))

// The screenshot at its own size, so it stays sharp.
window.draw(in: NSRect(x: (width - windowSize.width) / 2, y: 30, width: windowSize.width, height: windowSize.height))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path) (\(Int(width))×\(Int(height)))")
