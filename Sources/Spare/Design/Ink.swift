import AppKit
import SwiftUI

/// Spare's colours. Text and controls keep macOS's own colours and the person's accent colour; these are for what's
/// around them: the paper, the cards lying on it and the pencil marks. Each has a light and a dark shade, and a
/// stronger one when Increase Contrast is on.
enum Ink {
    /// The page: warm paper instead of flat grey.
    static let paper = tone(light: 0xF7F5F0, dark: 0x1D1C1A, lightContrast: 0xFFFFFF, darkContrast: 0x121110)
    /// An index card lying on the paper.
    static let card = tone(light: 0xFFFEFB, dark: 0x292724, lightContrast: 0xFFFFFF, darkContrast: 0x1F1E1C)
    /// A card that's been lifted off the desk: banners and the action tray.
    static let lifted = tone(light: 0xFFFFFD, dark: 0x32302C, lightContrast: 0xFFFFFF, darkContrast: 0x262523)
    /// Hairlines: dividers and card edges, barely there.
    static let line = tone(light: 0x2B2722, dark: 0xF2EDE4, alpha: 0.08, darkAlpha: 0.1, contrastAlpha: 0.45)
    /// The edge of a control, a little firmer than a card's.
    static let edge = tone(light: 0x2B2722, dark: 0xF2EDE4, alpha: 0.24, darkAlpha: 0.26, contrastAlpha: 0.7)
    /// The faint wash behind a row the pointer is over.
    static let wash = tone(light: 0x2B2722, dark: 0xF2EDE4, alpha: 0.05, darkAlpha: 0.065, contrastAlpha: 0.12)
    /// A pressed button, and the empty part of a bar or switch.
    static let press = tone(light: 0x2B2722, dark: 0xF2EDE4, alpha: 0.09, darkAlpha: 0.12, contrastAlpha: 0.2)
    /// Line drawings in empty states.
    static let pencil = tone(light: 0x3A352E, dark: 0xE9E3D8, alpha: 0.5, darkAlpha: 0.55, contrastAlpha: 0.9)
    /// The mint of the sparkle in Spare's icon, for the little stars in drawings.
    static let sparkle = tone(light: 0x2E9C86, dark: 0x8EE3CF, lightContrast: 0x16705F, darkContrast: 0xB4F0E2)
    /// The teal of Spare's icon, for fills: deep enough in both modes for white text on a filled button (5.5:1 and 4.7:1).
    static let brand = tone(light: 0x1E7568, dark: 0x1F8272, lightContrast: 0x125A4F, darkContrast: 0x17695D)
    /// The same teal as text, such as a quiet button: lighter in dark mode so small text stays readable on the paper.
    static let brandText = tone(light: 0x1E7568, dark: 0x4CC3AD, lightContrast: 0x125A4F, darkContrast: 0x8FE3D2)
    /// Warm highlights: things that want a look, never alarms.
    static let warm = tone(light: 0x9A5916, dark: 0xF2A65A, lightContrast: 0x7A4106, darkContrast: 0xFFC48A)
    /// What a desk shadow is made of: brown-black rather than pure black, like shade on paper.
    static let shade = tone(light: 0x2A1F14, dark: 0x000000)

    // Colours for symbols, tags and small text. Each reads at 4.5:1 or more on the paper, a card, a grey button and
    // its own tag in both modes, and stronger with Increase Contrast.
    static let sage = tone(light: 0x36754D, dark: 0x7CC796, lightContrast: 0x22663A, darkContrast: 0xA6E3B9)
    static let ink = tone(light: 0x3768B4, dark: 0x86AEEA, lightContrast: 0x1D4E96, darkContrast: 0xAFCBF5)
    static let sea = tone(light: 0x257470, dark: 0x6FD0C8, lightContrast: 0x0F6560, darkContrast: 0x9BE5DF)
    static let brick = tone(light: 0xAC4B34, dark: 0xF09480, lightContrast: 0x9A3420, darkContrast: 0xFFA48F)

    private static func tone(light: UInt32, dark: UInt32, lightContrast: UInt32? = nil, darkContrast: UInt32? = nil,
                             alpha: CGFloat = 1, darkAlpha: CGFloat? = nil, contrastAlpha: CGFloat? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: color(dark, darkAlpha ?? alpha)
            case .accessibilityHighContrastAqua: color(lightContrast ?? light, contrastAlpha ?? alpha)
            case .accessibilityHighContrastDarkAqua: color(darkContrast ?? dark, contrastAlpha ?? darkAlpha ?? alpha)
            default: color(light, alpha)
            }
        })
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Spare's teal as the accent colour when the person's accent is Multicolour, as macOS intends for apps with a colour
/// of their own; otherwise the accent they chose. Follows changes while Spare is open.
@MainActor
final class AppTint: ObservableObject {
    static let shared = AppTint()
    @Published private(set) var color: Color?
    /// The accent for text, such as a quiet button. Spare's teal has a lighter shade for that; a chosen accent doesn't need one.
    var text: Color? { color == nil ? nil : Ink.brandText }
    private var observer: NSObjectProtocol?

    init() {
        color = Self.current()
        observer = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppTint.shared.color = AppTint.current() }
        }
    }

    private static func current() -> Color? {
        UserDefaults.standard.object(forKey: "AppleAccentColor") == nil ? Ink.brand : nil
    }
}

private struct TintTextKey: EnvironmentKey { static let defaultValue: Color? = nil }

extension EnvironmentValues {
    /// The accent colour for text where it differs from the one for fills; nil means `.tint`.
    var tintText: Color? {
        get { self[TintTextKey.self] }
        set { self[TintTextKey.self] = newValue }
    }
}
