import Foundation

/// The apps that come with macOS, in /System/Applications. They're on the sealed system volume, which is the same on
/// every Mac and can't be changed while System Integrity Protection is on, so no app can delete them; deleting them
/// wouldn't free space either. What can be done is keeping one from opening and taking it out of the Dock.
///
/// macOS starts every app as a launchd job named `application.<identifier>.<app's file number>.<program's file
/// number>`; switching that job off keeps the app from opening until it's switched on again (RemoveMacAI found this
/// for Music). A macOS update replaces the apps, and with them the file numbers, so a block lasts until the next update.
public struct BuiltInApp: Identifiable, Sendable, Hashable {
    public let url: URL
    public let bundleID: String
    public let name: String
    /// The launchd job macOS opens it as, or nil when its file numbers can't be read.
    public let job: String?
    public var id: String { bundleID }

    public init(url: URL, bundleID: String, name: String, job: String?) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.job = job
    }

    /// The job's beginning, the same across updates.
    public var jobPrefix: String { "application.\(bundleID)." }
}

public enum BuiltInApps {
    /// Apps macOS can't do without, or that other parts of macOS open: never offered.
    static let essential: Set<String> = ["System Settings.app", "Apps.app", "Siri.app", "Siri AI.app", "Mission Control.app", "App Store.app"]

    public static func list(folder: URL = URL(fileURLWithPath: "/System/Applications")) -> [BuiltInApp] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "app" && !essential.contains($0.lastPathComponent) }.compactMap { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return BuiltInApp(url: url, bundleID: id, name: name, job: job(for: url, id: id, executable: bundle.executableURL))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `application.com.apple.Chess.1152921500311883988.1152921500311883993`.
    static func job(for url: URL, id: String, executable: URL?) -> String? {
        func number(_ url: URL) -> String? {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.stringValue
        }
        guard let executable, let app = number(url), let program = number(executable) else { return nil }
        return "application.\(id).\(app).\(program)"
    }

    public enum Block: Sendable, Equatable {
        case open
        case blocked
        /// Blocked before a macOS update replaced the app, so it opens again.
        case lapsed
    }

    public static func block(of app: BuiltInApp, disabled: Set<String>) -> Block {
        if let job = app.job, disabled.contains(job) { return .blocked }
        return disabled.contains { $0.hasPrefix(app.jobPrefix) } ? .lapsed : .open
    }

    /// Keeps an app from opening, and quits it if it's open. nil when that worked.
    public static func block(_ app: BuiltInApp) -> String? {
        guard let job = app.job else { return "macOS didn't say how it opens \(app.name)." }
        return Launchd.disable(job)
    }

    /// Lets an app open again, including blocks from before an update. nil when that worked.
    public static func unblock(_ app: BuiltInApp, disabled: Set<String>) -> String? {
        let jobs = disabled.filter { $0.hasPrefix(app.jobPrefix) }
        guard !jobs.isEmpty else { return "launchd has no block for \(app.name)." }
        let problems = jobs.compactMap { job -> String? in
            let result = Launchd.launchctl(["enable", "\(Launchd.session)/\(job)"])
            return result.status == 0 ? nil : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return problems.first
    }
}
