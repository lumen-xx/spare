import SwiftUI
import SpareCore

/// Finder's small settings, as Settings shows them. Finder reads its preferences when it starts, so a change
/// restarts it a moment after the last switch; its windows come back.
@MainActor
final class FinderSettings: ObservableObject {
    static let shared = FinderSettings()

    @Published private(set) var states: [String: Bool] = [:]
    @Published private(set) var view: FinderOptions.View = .icons
    @Published private(set) var libraryShown = false
    private var restart: Task<Void, Never>?

    func load() {
        #if DEBUG
        if Demo.isOn { states = Dictionary(uniqueKeysWithValues: FinderOptions.all.map { ($0.id, $0.standard) }); return }
        #endif
        states = FinderOptions.states()
        view = FinderOptions.view()
        libraryShown = FinderOptions.libraryShown()
    }

    func isOn(_ option: FinderOptions.Option) -> Bool { states[option.id] ?? option.standard }

    func set(_ option: FinderOptions.Option, on: Bool) {
        states[option.id] = on
        #if DEBUG
        if Demo.isOn { return }
        #endif
        FinderOptions.set(option, on: on)
        // What Finder will actually read: a value set elsewhere, for the whole Mac or by a profile, can still win.
        states = FinderOptions.states()
        restartFinderSoon()
    }

    func setView(_ view: FinderOptions.View) {
        self.view = view
        #if DEBUG
        if Demo.isOn { return }
        #endif
        FinderOptions.setView(view)
        restartFinderSoon()
    }

    func showLibrary(_ shown: Bool) {
        #if DEBUG
        if Demo.isOn { libraryShown = shown; return }
        #endif
        if let problem = FinderOptions.showLibrary(shown) {
            Shared.shared.banner = .init(title: shown ? "Library is still hidden" : "Library is still shown", detail: problem, failed: true)
        }
        libraryShown = FinderOptions.libraryShown()
    }

    /// Restarts Finder once switching stops for a moment, so several changes need one restart.
    private func restartFinderSoon() {
        restart?.cancel()
        restart = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            _ = await background { Shell.run("/usr/bin/killall", ["Finder"]) }
        }
    }
}
