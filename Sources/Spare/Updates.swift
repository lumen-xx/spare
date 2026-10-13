import AppKit
import Combine
import Sparkle

/// Sparkle, checking only when asked unless the person turns on automatic checks.
@MainActor final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updates()
    @Published var automatic = UserDefaults.standard.bool(forKey: "autoUpdates") {
        didSet { UserDefaults.standard.set(automatic, forKey: "autoUpdates"); controller.updater.automaticallyChecksForUpdates = automatic }
    }
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var started = false

    func start() {
        guard !started, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        started = true
        controller.startUpdater()
        controller.updater.automaticallyChecksForUpdates = automatic
    }

    var available: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    func check() {
        start()
        guard started else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> { ["preview"] }
}
