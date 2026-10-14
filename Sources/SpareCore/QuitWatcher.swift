import Foundation

/// Apps Spare quits the moment they open, by a small helper that runs in the background while there are any. Music is
/// the one: the play key opens it when nothing else plays, and macOS has no setting against that, so it opens and
/// is quit at once, and the keys keep working for every other player. Blocking it instead would make macOS say it
/// "can't be opened" each time. A launch agent of the person's own starts the helper at login.
public enum QuitWatcher {
    public static let label = "com.opyuii.spare.helper"
    /// Spare's own preferences, which the helper reads each time an app opens.
    public static let domain = "com.opyuii.spare"
    public static let key = "quitWhenOpened"

    public static var apps: Set<String> { Set(Prefs.read(domain, key) as? [String] ?? []) }

    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The helper, next to Spare's own executable.
    static var helper: URL? { Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("SpareHelper") }

    /// Quits an app whenever it opens, or no longer, and starts or stops the helper to match. nil when that worked.
    public static func set(_ id: String, quits: Bool) -> String? {
        var apps = apps
        if quits { apps.insert(id) } else { apps.remove(id) }
        CFPreferencesSetAppValue(key as CFString, apps.isEmpty ? nil : apps.sorted() as CFArray, domain as CFString)
        guard CFPreferencesAppSynchronize(domain as CFString) else { return "macOS didn't save the change." }
        return apps.isEmpty ? stop() : start()
    }

    /// Runs when Spare opens: the helper runs exactly while there's something to quit, from where Spare is now.
    public static func check() {
        if !apps.isEmpty { _ = start() } else if FileManager.default.fileExists(atPath: plist.path) { _ = stop() }
    }

    static func start() -> String? {
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path) else { return "Spare's helper is missing; download Spare again." }
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helper.path],
            "RunAtLoad": true,
            // Started again if it ever stops, except when it ends by itself with nothing left to quit.
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        let target = "\(Launchd.session)/\(label)"
        let current = NSDictionary(contentsOf: plist)
        if current == job as NSDictionary, Launchd.launchctl(["print", target]).status == 0 { return nil }
        _ = Launchd.launchctl(["bootout", target])
        do {
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist, options: .atomic)
        } catch {
            return "Spare couldn't set up its helper: \(error.localizedDescription)"
        }
        let started = Launchd.launchctl(["bootstrap", Launchd.session, plist.path])
        return started.status == 0 ? nil : "Spare's helper didn't start: \(started.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Stops the helper and takes away its launch agent.
    @discardableResult
    public static func stop() -> String? {
        _ = Launchd.launchctl(["bootout", "\(Launchd.session)/\(label)"])
        guard FileManager.default.fileExists(atPath: plist.path) else { return nil }
        do { try FileManager.default.removeItem(at: plist) } catch { return error.localizedDescription }
        return nil
    }
}
