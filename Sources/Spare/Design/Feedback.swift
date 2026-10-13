import AppKit
import SwiftUI

/// How Spare feels, as chosen in Settings: the paper's grain, a soft tap on Force Touch trackpads when something
/// finishes, and an optional quiet sound. Motion follows Reduce Motion in the system's Accessibility settings.
enum Feel {
    static let paperKey = "paperTexture"
    static let hapticsKey = "softTaps"
    static let soundKey = "quietSound"

    static var haptics: Bool { UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true }
    static var sound: Bool { UserDefaults.standard.bool(forKey: soundKey) }
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
