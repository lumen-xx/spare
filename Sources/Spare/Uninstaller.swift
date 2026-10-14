import AppKit
import SpareCore

/// Takes Spare off the Mac: Spare itself and its own files go to the Trash, so all of it can be put back from there.
/// Undoing what Spare changed is separate and comes first, see `DebloatModel.undo` and `UndoSheet`.
@MainActor
enum Uninstaller {
    static var identifier: String { Bundle.main.bundleIdentifier ?? "com.opyuii.spare" }

    /// Spare's own files in the person's Library that are there now.
    static var files: [URL] {
        let library = home.appendingPathComponent("Library")
        return ["Application Support/Spare", "Caches/\(identifier)", "HTTPStorages/\(identifier)",
                "Saved Application State/\(identifier).savedState", "WebKit/\(identifier)", "Preferences/\(identifier).plist"]
            .map { library.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves Spare and its files to the Trash, then quits. Returns why not when Spare itself couldn't be moved, and
    /// then nothing else has moved either.
    static func run() -> String? {
        #if DEBUG
        if Demo.isOn { Demo.pretend("Spare would have moved itself to the Trash."); return nil }
        #endif
        let app = Bundle.main.bundleURL
        // Only ever an app: run from a build folder, the bundle URL is the folder itself.
        guard app.pathExtension == "app" else { return "Spare isn't running as an app, so there's nothing to move." }
        do {
            try FileManager.default.trashItem(at: app, resultingItemURL: nil)
        } catch {
            // In /Applications Spare may need a password to move itself; Finder asks for one as when dragging it.
            if case .failure(let error) = Privileged.finderTrash(app) { return error.localizedDescription }
        }
        // Its helper, which would otherwise go on quitting apps without Spare.
        QuitWatcher.stop()
        // Its own entries in Privacy & Security, so they don't stay behind for an app that's gone.
        _ = Shell.run("/usr/bin/tccutil", ["reset", "All", identifier], timeout: 10)
        UserDefaults.standard.removePersistentDomain(forName: identifier)
        for file in files { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
        NSApp.terminate(nil)
        return nil
    }
}
