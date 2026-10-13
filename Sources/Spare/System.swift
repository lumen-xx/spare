import AppKit
import SpareCore

/// Spare's view of what macOS lets it see.
enum Permissions {
    /// Full Disk Access, checked by opening a file macOS protects. A failed open never shows a prompt.
    static func fullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let database = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let handle = open(database, O_RDONLY)
        if handle >= 0 { close(handle); return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/Safari").path)) != nil
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    static func openLoginItemsSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    /// Folders macOS guards. Without Full Disk Access, opening some of them asks for permission one folder at a
    /// time, so Spare doesn't go in at all and says so instead.
    static let guardedFolders = ["Desktop", "Documents", "Downloads", ".Trash", "Library/Mobile Documents", "Library/CloudStorage",
                                 "Library/Containers", "Library/Group Containers", "Library/Daemon Containers", "Library/Mail", "Library/Messages",
                                 "Library/Safari", "Library/Cookies", "Library/Calendars", "Library/HomeKit", "Library/Photos", "Library/Biome",
                                 "Library/Suggestions", "Library/PersonalizationPortrait", "Library/IdentityServices", "Library/Accounts",
                                 "Library/Sharing", "Library/Metadata/CoreSpotlight", "Library/DuetExpertCenter", "Library/Trial",
                                 "Library/StatusKit", "Library/Weather", "Library/Shortcuts", "Library/Autosave Information",
                                 "Library/Application Support/MobileSync", "Library/Application Support/AddressBook",
                                 "Library/Application Support/CallHistoryDB", "Library/Application Support/com.apple.TCC",
                                 "Library/Application Support/FileProvider", "Library/Application Support/Knowledge",
                                 "Library/Application Support/CloudDocs", "Pictures/Photos Library.photoslibrary"]

    static func guardedPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        Set(guardedFolders.map { home.appendingPathComponent($0).path })
    }
}

/// Things only an administrator, or Finder, can do. Both go through macOS's own prompts; Spare never sees a password.
enum Privileged {
    /// Runs a shell command as root after macOS asks for an administrator password. Returns nil on success, or why not.
    @MainActor
    static func run(_ command: String, prompt: String) -> String? {
        let escape = { (text: String) in text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let source = "do shell script \"\(escape(command))\" with administrator privileges with prompt \"\(escape(prompt))\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        // -128: the person cancelled.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
        return error[NSAppleScript.errorMessage] as? String ?? "Unknown error."
    }

    /// Asks Finder to move an item to the Trash. Finder asks for a password when the item needs one, as when
    /// dragging it there. Returns where it ended up.
    @MainActor
    static func finderTrash(_ url: URL) -> Result<String, Error> {
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            tell application "Finder"
                set moved to delete (POSIX file "\(path)" as alias)
                return POSIX path of (moved as alias)
            end tell
            """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            return .failure(NSError(domain: "Spare", code: error[NSAppleScript.errorNumber] as? Int ?? 1,
                                    userInfo: [NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? "Finder couldn't move it."]))
        }
        return .success(result?.stringValue ?? url.path)
    }

    @MainActor
    static func emptyTrash() -> String? {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
            return "Spare isn't allowed to control Finder. Allow it in System Settings › Privacy & Security › Automation, or empty the Trash in Finder."
        }
        return error[NSAppleScript.errorMessage] as? String ?? "Finder couldn't empty the Trash."
    }

    static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Moves things to the Trash and writes them into History. Items Spare isn't allowed to move are handed to
/// Finder, which asks for a password when needed.
@MainActor
enum Trasher {
    struct Outcome {
        var session: TrashSession?
        var failures: [Trash.Failure]
        var bytes: Int64 { session?.bytes ?? 0 }
    }

    static func move(_ entries: [(url: URL, bytes: Int64?)], title: String) async -> Outcome {
        let result = await Task.detached(priority: .userInitiated) { Trash.move(entries) }.value
        var records = result.records
        var failures: [Trash.Failure] = []
        for failure in result.failures {
            guard failure.needsPermission else { failures.append(failure); continue }
            switch Privileged.finderTrash(failure.url) {
            case .success(let trashed):
                let bytes = entries.first { $0.url == failure.url }?.bytes ?? nil
                records.append(TrashRecord(original: failure.url.path, trashed: trashed, bytes: bytes))
            case .failure(let error):
                failures.append(Trash.Failure(url: failure.url, reason: error.localizedDescription, needsPermission: true))
            }
        }
        guard !records.isEmpty else { return Outcome(session: nil, failures: failures) }
        let moved = Set(records.map(\.original))
        let bytes = entries.filter { moved.contains($0.url.path) }.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let session = TrashSession(title: title, records: records, bytes: bytes)
        HistoryModel.shared.add(session)
        Shared.shared.refreshSpace()
        return Outcome(session: session, failures: failures)
    }
}

/// Names and icons of apps, and which are open.
enum AppLookup {
    static func url(for bundleID: String) -> URL? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), !url.path.contains("/.Trash/") else { return nil }
        return url
    }

    static func name(for bundleID: String) -> String? {
        url(for: bundleID).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    /// Cache folders named after a company rather than an app.
    static let vendorFolders: [String: [String]] = [
        "google": ["com.google.Chrome"], "bravesoftware": ["com.brave.Browser"], "mozilla": ["org.mozilla.firefox"],
        "firefox": ["org.mozilla.firefox"], "microsoft edge": ["com.microsoft.edgemac"], "jetbrains": ["com.jetbrains."],
        "arc": ["company.thebrowser.Browser"], "vivaldi": ["com.vivaldi.Vivaldi"], "opera": ["com.operasoftware.Opera"]
    ]

    /// A check for whether the app a ~/Library/Caches folder belongs to is open right now, safe to use off the main thread.
    static func openCheck() -> @Sendable (String) -> Bool {
        let running = NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier ?? "", ($0.localizedName ?? "").lowercased()) }
        return { folder in
            let lower = folder.lowercased()
            let vendors = vendorFolders[lower] ?? []
            return running.contains { id, name in
                !id.isEmpty && (folder == id || folder.hasPrefix(id + ".") || name == lower
                                || vendors.contains { id == $0 || ($0.hasSuffix(".") && id.hasPrefix($0)) })
            }
        }
    }

    static func icon(for url: URL, size: CGFloat = 32) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: size, height: size)
        return image
    }
}
