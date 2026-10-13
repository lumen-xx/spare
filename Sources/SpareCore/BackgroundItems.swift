import Foundation

/// A launchd job: something that starts on its own, at login, at startup or on a schedule.
public struct LaunchItem: Identifiable, Sendable {
    public enum Scope: String, CaseIterable, Sendable {
        /// ~/Library/LaunchAgents: runs as you, can be removed without a password.
        case user = "Your Account"
        /// /Library/LaunchAgents: runs as each person who logs in.
        case allUsers = "Every Account"
        /// /Library/LaunchDaemons: runs as root, before anyone logs in.
        case system = "System"
        /// Inside an app, registered with macOS through the app itself.
        case app = "Inside Apps"
    }

    public let url: URL
    public let scope: Scope
    public let label: String
    public let program: String?
    public let arguments: [String]
    public let associatedBundleIDs: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let interval: Int?
    public let calendar: Bool
    public let watchesFiles: Bool
    public let disabled: Bool
    /// The app bundle it lives in, for items inside apps.
    public var container: URL?
    public var id: String { url.path }

    /// The program it runs exists. A job whose program is gone was left behind by an app that was removed.
    public var programExists: Bool {
        guard let program, program.hasPrefix("/") else { return true }
        return FileManager.default.fileExists(atPath: program)
    }

    /// When it runs, in a few words.
    public var schedule: String {
        if keepAlive { return "Always running" }
        if let interval {
            if interval % 86_400 == 0 { return interval == 86_400 ? "Every day" : "Every \(interval / 86_400) days" }
            if interval % 3_600 == 0 { return interval == 3_600 ? "Every hour" : "Every \(interval / 3_600) hours" }
            if interval % 60 == 0 { return interval == 60 ? "Every minute" : "Every \(interval / 60) minutes" }
            return "Every \(interval) seconds"
        }
        if calendar { return "On a schedule" }
        if watchesFiles { return "When files change" }
        if runAtLoad { return scope == .system ? "At startup" : "At login" }
        return "When needed"
    }

    /// The program's file name, or the label.
    public var programName: String {
        guard let program else { return label }
        return URL(fileURLWithPath: program).lastPathComponent
    }

    /// The app the program sits in, if it's inside an app bundle.
    public var programApp: URL? {
        guard let program, let range = program.range(of: ".app/") else { return container }
        return URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app")
    }

    public init?(plist url: URL, scope: Scope, container: URL? = nil) {
        guard let plist = NSDictionary(contentsOf: url) as? [String: Any], let label = plist["Label"] as? String else { return nil }
        self.url = url
        self.scope = scope
        self.label = label
        self.container = container
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        var program = plist["Program"] as? String ?? arguments.first
        if program == nil, let bundled = plist["BundleProgram"] as? String, let container {
            program = container.appendingPathComponent(bundled).path
        }
        self.program = program
        self.arguments = arguments
        switch plist["AssociatedBundleIdentifiers"] {
        case let one as String: associatedBundleIDs = [one]
        case let many as [String]: associatedBundleIDs = many
        default: associatedBundleIDs = []
        }
        runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        // KeepAlive can be a dictionary of conditions; any of them means it is restarted when it quits.
        keepAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
        interval = plist["StartInterval"] as? Int
        calendar = plist["StartCalendarInterval"] != nil
        watchesFiles = plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil
        disabled = plist["Disabled"] as? Bool ?? false
    }

    public static func load(_ folder: URL, scope: Scope, container: URL? = nil) -> [LaunchItem] {
        Catalog.list(folder).filter { $0.pathExtension == "plist" }.compactMap { LaunchItem(plist: $0, scope: scope, container: container) }
    }

    /// Every job outside macOS itself: the three launchd folders, and the ones apps carry inside them.
    public static func all(home: URL, apps: [URL]) -> [LaunchItem] {
        var items = load(home.appendingPathComponent("Library/LaunchAgents"), scope: .user)
            + load(URL(fileURLWithPath: "/Library/LaunchAgents"), scope: .allUsers)
            + load(URL(fileURLWithPath: "/Library/LaunchDaemons"), scope: .system)
        for app in apps {
            for folder in ["Contents/Library/LaunchAgents", "Contents/Library/LaunchDaemons"] {
                items += load(app.appendingPathComponent(folder), scope: .app, container: app)
            }
        }
        return items
    }

    /// Plain words for jobs many Macs have.
    public static let notes: [(prefix: String, note: String)] = [
        ("com.google.keystone", "Google's updater for Chrome and its other apps. Without it they stop updating themselves, and Chrome may put it back."),
        ("com.google.GoogleUpdater", "Google's updater for Chrome and its other apps. Without it they stop updating themselves, and Chrome may put it back."),
        ("com.microsoft.update", "Microsoft AutoUpdate, which keeps Office, Teams and Edge up to date."),
        ("com.microsoft.autoupdate", "Microsoft AutoUpdate, which keeps Office, Teams and Edge up to date."),
        ("com.adobe.", "Part of Adobe Creative Cloud: its updater, sync or licensing."),
        ("homebrew.mxcl.", "A Homebrew service. Stop it with “brew services stop” rather than removing the file."),
        ("com.docker.", "A helper of Docker Desktop."),
        ("us.zoom.", "Zoom's updater or helper."),
        ("com.logitech.", "Logitech's device software."),
        ("com.logi.", "Logitech's device software."),
        ("com.steelseries.", "SteelSeries GG, for its headsets and mice."),
        ("com.razer.", "Razer Synapse, for its devices."),
        ("com.valvesoftware.", "Part of Steam."),
        ("com.riot.", "Part of Riot's game client."),
        ("com.gog.", "Part of GOG Galaxy."),
        ("com.dropbox.", "Part of Dropbox."),
        ("com.spotify.", "Spotify's helper."),
        ("com.teamviewer.", "Part of TeamViewer, which allows remote access to this Mac."),
        ("com.github.facebook.watchman", "Watchman, a file watcher used by React Native and other developer tools."),
        ("net.mullvad.", "Mullvad VPN's background service."),
        ("org.virtualbox.", "Part of VirtualBox."),
        ("com.oracle.java.", "Java's updater.")
    ]

    public var note: String? { Self.notes.first { label.hasPrefix($0.prefix) }?.note }
}

public enum Launchd {
    public struct Status: Sendable, Equatable {
        /// Known to launchd right now.
        public var loaded: Bool
        /// Its process, if running.
        public var pid: Int?
        public init(loaded: Bool, pid: Int?) { self.loaded = loaded; self.pid = pid }
    }

    /// Jobs launchd knows in a domain ("system" or "gui/501"), with their process if running.
    public static func services(domain: String) -> [String: Status] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", domain]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Reads the "services = { pid status label }" block of `launchctl print`.
    public static func parse(_ output: String) -> [String: Status] {
        var result: [String: Status] = [:]
        var inside = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" { inside = true; continue }
            if inside && trimmed == "}" { break }
            guard inside else { continue }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3 else { continue }
            let pid = Int(fields[0]) ?? 0
            result[String(fields[2...].joined(separator: " "))] = Status(loaded: true, pid: pid > 0 ? pid : nil)
        }
        return result
    }
}
