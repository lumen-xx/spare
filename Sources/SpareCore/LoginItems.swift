import Foundation

/// An entry in macOS's login and background items database: what System Settings › General › Login Items &
/// Extensions shows, including items apps register through the system rather than with a file of their own.
public struct LoginRecord: Identifiable, Sendable, Hashable {
    public let uuid: String
    public let name: String
    public let developer: String?
    public let teamID: String?
    /// "app", "login item", "agent", "daemon", "legacy agent", "legacy daemon", "background tasks", "quicklook", …
    public let type: String
    /// The app registered it and wants it to run.
    public let enabled: Bool
    /// The person allows it in Login Items settings.
    public let allowed: Bool
    public let identifier: String
    public let url: String?
    public let executable: String?
    public let bundleID: String?
    public let parent: String?
    public var id: String { uuid }

    /// Opens at login: an app added as a login item, or a login helper inside one.
    public var opensAtLogin: Bool { (type == "app" || type == "login item") && enabled }
    /// Runs in the background on the app's behalf.
    public var isBackground: Bool { ["agent", "daemon", "legacy agent", "legacy daemon", "background tasks"].contains(type) }
    /// Backed by a launchd file Spare lists separately.
    public var isLegacy: Bool { type.hasPrefix("legacy") }
}

public enum LoginItems {
    /// Reads `sfltool dumpbtm`, keeping the records of one user.
    public static func parse(_ text: String, uid: Int) -> [LoginRecord] {
        var records: [LoginRecord] = []
        var inside = false
        var fields: [String: String] = [:]
        func flush() {
            defer { fields = [:] }
            guard let uuid = fields["UUID"], let type = fields["Type"] else { return }
            let kind = type.components(separatedBy: " (").first ?? type
            let disposition = fields["Disposition"].flatMap { value -> [String]? in
                guard let open = value.firstIndex(of: "["), let close = value.firstIndex(of: "]") else { return nil }
                return value[value.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } ?? []
            func value(_ key: String) -> String? { fields[key].flatMap { $0 == "(null)" || $0.isEmpty ? nil : $0 } }
            records.append(LoginRecord(uuid: uuid, name: value("Name") ?? value("Identifier") ?? "Unknown", developer: value("Developer Name"),
                                       teamID: value("Team Identifier"), type: kind, enabled: disposition.contains("enabled"),
                                       allowed: disposition.contains("allowed"), identifier: value("Identifier") ?? uuid,
                                       url: value("URL"), executable: value("Executable Path"), bundleID: value("Bundle Identifier"),
                                       parent: value("Parent Identifier")))
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID ") {
                flush()
                let number = line.dropFirst("Records for UID ".count).split(separator: " ").first.flatMap { Int($0) }
                inside = number == uid
                continue
            }
            guard inside else { continue }
            if line.hasPrefix("#"), line.hasSuffix(":") { flush(); continue }
            guard let colon = line.range(of: ": ") else { continue }
            fields[String(line[..<colon.lowerBound])] = String(line[colon.upperBound...])
        }
        flush()
        return records
    }
}
