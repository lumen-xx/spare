import AppKit
import SwiftUI

/// How Spare feels, as chosen in Settings: the paper's grain, a soft tap on Force Touch trackpads when something
/// finishes, and an optional quiet sound. Motion follows Reduce Motion in the system's Accessibility settings.
enum Feel {
    static let paperKey = "paperTexture"
    static let hapticsKey = "softTaps"
    static let soundKey = "quietSound"

    static let themeKey = "theme"

    static var haptics: Bool { UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true }
    static var sound: Bool { UserDefaults.standard.bool(forKey: soundKey) }

    /// Light or dark, or as the Mac is set.
    enum Theme: String, CaseIterable {
        case automatic, light, dark
        var title: String { rawValue.capitalized }
        var appearance: NSAppearance? {
            switch self {
            case .automatic: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    static var theme: Theme { Theme(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .automatic }

    @MainActor static func applyTheme() { NSApp.appearance = theme.appearance }
}

/// Acknowledging what just happened, the same way everywhere.
@MainActor
enum Feedback {
    /// Something finished: a soft tap you feel only with a finger on a Force Touch trackpad, a quiet sound if chosen,
    /// and the same words for VoiceOver that the message on screen shows.
    static func finished(_ message: String? = nil, success: Bool = true) {
        if Feel.haptics { NSHapticFeedbackManager.defaultPerformer.perform(success ? .levelChange : .generic, performanceTime: .now) }
        if Feel.sound, success { quietSound() }
        if let message { announce(message) }
    }

    /// Says something to VoiceOver without moving its cursor.
    static func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    /// A single soft "Pop", well below the alert volume. It never loops.
    static func quietSound() {
        guard let sound = NSSound(named: "Pop")?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
    }
}
