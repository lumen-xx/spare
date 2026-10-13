import Foundation

/// Xcode's simulators and the system versions they run, as `xcrun simctl` lists them. Each simulator keeps its own
/// disk, and each runtime is a disk image of several gigabytes, so unused ones are worth removing with simctl.
public enum Simulators {
    public struct Device: Identifiable, Sendable, Equatable {
        public var udid: String
        public var name: String
        /// "iOS 18.2".
        public var runtime: String
        public var state: String
        public var isAvailable: Bool
        /// Why it can't run, as simctl says it, such as a runtime that's gone.
        public var problem: String?
        public var lastBooted: Date?
        public var dataURL: URL?
        public var bytes: Int64?
        public var id: String { udid }

        public init(udid: String, name: String, runtime: String, state: String, isAvailable: Bool, problem: String? = nil,
                    lastBooted: Date? = nil, dataURL: URL? = nil, bytes: Int64? = nil) {
            self.udid = udid; self.name = name; self.runtime = runtime; self.state = state; self.isAvailable = isAvailable
            self.problem = problem; self.lastBooted = lastBooted; self.dataURL = dataURL; self.bytes = bytes
        }
    }

    public struct Runtime: Identifiable, Sendable, Equatable {
        /// What `simctl runtime delete` takes.
        public var identifier: String
        /// "iOS 18.2".
        public var name: String
        public var build: String?
        public var bytes: Int64?
        public var deletable: Bool
        public var lastUsed: Date?
        /// "Disk Image", "Bundled with Xcode".
        public var kind: String?
        public var id: String { identifier }

        public init(identifier: String, name: String, build: String? = nil, bytes: Int64? = nil, deletable: Bool, lastUsed: Date? = nil, kind: String? = nil) {
            self.identifier = identifier; self.name = name; self.build = build; self.bytes = bytes; self.deletable = deletable
            self.lastUsed = lastUsed; self.kind = kind
        }
    }

    /// `xcrun simctl list devices --json`, sorted by runtime and name.
    public static func devices(json: Data) -> [Device] {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let groups = object["devices"] as? [String: Any] else { return [] }
        var devices: [Device] = []
        for (runtime, list) in groups {
            for case let entry as [String: Any] in (list as? [Any]) ?? [] {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { continue }
                // Older Xcodes said "(available)" or "(unavailable, …)" instead of isAvailable.
                let available = (entry["isAvailable"] as? Bool) ?? (entry["availability"] as? String).map { $0 == "(available)" } ?? true
                let problem = (entry["availabilityError"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                devices.append(Device(udid: udid, name: name, runtime: runtimeName(runtime), state: entry["state"] as? String ?? "Unknown",
                                      isAvailable: available, problem: problem, lastBooted: date(entry["lastBootedAt"]),
                                      dataURL: (entry["dataPath"] as? String).map { URL(fileURLWithPath: $0) }, bytes: number(entry["dataPathSize"])))
            }
        }
        return devices.sorted { a, b in
            for (x, y) in [(a.runtime, b.runtime), (a.name, b.name), (a.udid, b.udid)] where x != y {
                return x.localizedStandardCompare(y) == .orderedAscending
            }
            return false
        }
    }

    /// `xcrun simctl runtime list --json`, sorted by name. Also reads `simctl list runtimes --json`, which knows less.
    public static func runtimes(json: Data) -> [Runtime] {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return [] }
        var runtimes: [Runtime] = []
        if let listed = object["runtimes"] as? [[String: Any]] {
            for entry in listed {
                guard let identifier = entry["identifier"] as? String else { continue }
                runtimes.append(Runtime(identifier: identifier, name: entry["name"] as? String ?? runtimeName(identifier),
                                        build: entry["buildversion"] as? String, deletable: false))
            }
        } else {
            for (key, value) in object {
                guard let entry = value as? [String: Any] else { continue }
                let identifier = entry["identifier"] as? String ?? key
                let name: String
                if let runtime = entry["runtimeIdentifier"] as? String { name = runtimeName(runtime) }
                else { name = [platform(entry["platformIdentifier"] as? String), entry["version"] as? String].compactMap { $0 }.joined(separator: " ") }
                runtimes.append(Runtime(identifier: identifier, name: name.isEmpty ? identifier : name, build: entry["build"] as? String,
                                        bytes: number(entry["sizeBytes"]), deletable: entry["deletable"] as? Bool ?? false,
                                        lastUsed: date(entry["lastUsedAt"]), kind: entry["kind"] as? String))
            }
        }
        return runtimes.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.identifier < $1.identifier : order == .orderedAscending
        }
    }

    /// "iOS 18.2" for com.apple.CoreSimulator.SimRuntime.iOS-18-2; visionOS for xrOS.
    public static func runtimeName(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = last.split(separator: "-").map(String.init)
        guard parts.count >= 2, let first = parts.first, parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return last }
        let system = first == "xrOS" ? "visionOS" : first
        return "\(system) \(parts.dropFirst().joined(separator: "."))"
    }

    static func platform(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        let known = ["iphonesimulator": "iOS", "appletvsimulator": "tvOS", "watchsimulator": "watchOS", "xrsimulator": "visionOS"]
        return known[identifier.split(separator: ".").last.map(String.init) ?? ""]
    }

    static func number(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: number.int64Value
        case let text as String: Int64(text)
        default: nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
