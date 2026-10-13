import CoreText
import SwiftUI

/// Spare's typeface: Bricolage Grotesque, the one nano uses. It's a variable font, drawn at the weight asked for and at
/// the optical size of the text, so small labels get its open, sturdy cut and large numbers its tight display cut.
/// Characters outside Latin come from its Latin Extended half, then from the system font.
enum Typeface {
    private static let latin = descriptor("BricolageGrotesque-Latin")
    private static let extended = descriptor("BricolageGrotesque-LatinExt")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [Key: Font] = [:]

    private struct Key: Hashable {
        let size: CGFloat
        let weight: Double
    }

    /// `size` points at `weight`, or the system font if the typeface couldn't be loaded.
    static func font(size: CGFloat, weight: Font.Weight) -> Font {
        guard let latin else { return .system(size: size, weight: weight) }
        let key = Key(size: size, weight: axis(weight))
        lock.lock()
        defer { lock.unlock() }
        if let font = made[key] { return font }
        // The font's own default is its 96 pt ExtraBold, so every axis is set.
        let variation = [tag("wght"): key.weight, tag("opsz"): min(96, max(12, Double(size))), tag("wdth"): 100] as [NSNumber: Double]
        var attributes: [CFString: Any] = [kCTFontVariationAttribute: variation]
        if let extended {
            attributes[kCTFontCascadeListAttribute] = [CTFontDescriptorCreateCopyWithAttributes(extended, [kCTFontVariationAttribute: variation] as CFDictionary)]
        }
        let font = Font(CTFontCreateWithFontDescriptor(CTFontDescriptorCreateCopyWithAttributes(latin, attributes as CFDictionary), size, nil))
        made[key] = font
        return font
    }

    private static func axis(_ weight: Font.Weight) -> Double {
        switch weight {
        case .ultraLight, .thin: 200
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy, .black: 800
        default: 400
        }
    }

    /// An axis's four-letter name as the number Core Text keys variations by.
    private static func tag(_ name: String) -> NSNumber {
        NSNumber(value: name.unicodeScalars.reduce(UInt32(0)) { $0 << 8 | $1.value })
    }

    private static func descriptor(_ name: String) -> CTFontDescriptor? {
        guard let url = url(name) else { return nil }
        return (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
    }

    private static func url(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "woff2", subdirectory: "Fonts") { return url }
        #if DEBUG
        // A development build runs outside the app bundle; the font sits beside the sources.
        let beside = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/\(name).woff2")
        if FileManager.default.fileExists(atPath: beside.path) { return beside }
        #endif
        return nil
    }
}

extension Font {
    /// Spare's typeface at `size` points; see `Typeface`.
    static func spare(size: CGFloat, weight: Font.Weight = .regular) -> Font { Typeface.font(size: size, weight: weight) }
}
