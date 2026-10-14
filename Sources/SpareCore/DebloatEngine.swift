import Foundation

extension Debloat {
    /// Where a tweak stands.
    public enum State: Equatable, Sendable {
        case applied, notApplied, partial
        /// Another profile, usually a company's, sets it.
        case managed
        /// This macOS doesn't have the setting.
        case unsupported
    }

    /// What the Mac looks like now, read once.
    public struct Snapshot: Sendable {
        public var profile: Set<String>?
        public var disabled: Set<String>
        public var dock: Set<String>

        public static func now() -> Snapshot {
            Snapshot(profile: installedProfile(), disabled: Launchd.disabledInSession(), dock: Dock.apps())
        }

        public init(profile: Set<String>?, disabled: Set<String>, dock: Set<String>) {
            self.profile = profile
            self.disabled = disabled
            self.dock = dock
        }

        public func state(_ tweak: Tweak) -> State {
            guard tweak.supported else { return .unsupported }
            if tweak.changes.isEmpty { return profile?.contains(tweak.id) == true ? .applied : .notApplied }
            if tweak.changes.contains(where: { lockedElsewhere($0, tweak) }) { return .managed }
            let done = tweak.changes.filter(applied).count
            return done == tweak.changes.count ? .applied : done == 0 ? .notApplied : .partial
        }

        func applied(_ change: Change) -> Bool {
            switch change {
            case .restriction(let key):
                Prefs.isLocked("com.apple.applicationaccess", key) && Value.bool(false).matches(Prefs.read("com.apple.applicationaccess", key))
            case .forced(let domain, let key, let value):
                Prefs.isLocked(domain, key) && value.matches(Prefs.read(domain, key))
            case .pref(let domain, let key, let value):
                value.matches(Prefs.read(domain, key))
            case .service(let label):
                disabled.contains(label)
            case .quit(let id):
                QuitWatcher.apps.contains(id)
            }
        }

        /// Locked by something other than Spare's profile, so Spare can't change it.
        func lockedElsewhere(_ change: Change, _ tweak: Tweak) -> Bool {
            let ours = profile?.contains(tweak.id) == true
            switch change {
            case .restriction(let key): return !ours && Prefs.isLocked("com.apple.applicationaccess", key)
            case .forced(let domain, let key, _): return !ours && Prefs.isLocked(domain, key)
            case .pref(let domain, let key, _): return Prefs.isLocked(domain, key)
            case .service, .quit: return false
            }
        }
    }

    // MARK: - Journal

    /// What each setting was before Spare changed it, so undo puts back exactly that.
    public struct Journal: Codable, Sendable {
        public var entries: [String: Entry] = [:]

        public struct Entry: Codable, Sendable {
            public var previous: Previous
            public var date: Date

            public init(previous: Previous, date: Date) {
                self.previous = previous
                self.date = date
            }
        }

        public enum Previous: Codable, Sendable {
            case pref(Value?)
            case disabled(Bool)
            /// Whether Spare's helper quit the app already.
            case quits(Bool)
            /// Dock tiles taken out, as property lists, with where they were.
            case dock([DockTile])
        }

        public init() {}

        static func key(_ change: Change) -> String {
            switch change {
            case .restriction(let key): "restriction:\(key)"
            case .forced(let domain, let key, _): "forced:\(domain):\(key)"
            case .pref(let domain, let key, _): "pref:\(domain):\(key)"
            case .service(let label): "service:\(label)"
            case .quit(let id): "quit:\(id)"
            }
        }

        public static var url: URL {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Spare/Debloat.json")
        }

        public static func load() -> Journal {
            guard let data = try? Data(contentsOf: url) else { return Journal() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(Journal.self, from: data)) ?? Journal()
        }

        public func save() {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(self).write(to: Self.url, options: .atomic)
        }
    }

    public struct DockTile: Codable, Sendable {
        public let index: Int
        public let plist: Data
    }

    // MARK: - Changing

    /// Applies what a tweak changes outside the profile. Returns problems in plain words.
    public static func apply(_ tweak: Tweak, journal: inout Journal) -> [String] {
        var problems: [String] = []
        for change in tweak.changes {
            let key = Journal.key(change)
            switch change {
            case .restriction, .forced:
                continue
            case .pref(let domain, let name, let value):
                // The value from before, recorded again when something other than Spare changed it since.
                if journal.entries[key] == nil || !value.matches(Prefs.read(domain, name)) {
                    journal.entries[key] = .init(previous: .pref(Value(Prefs.own(domain, name))), date: Date())
                    journal.save()
                }
                Prefs.write(domain, name, value)
                if !value.matches(Prefs.read(domain, name)) { problems.append("\(tweak.title): macOS didn't take the change.") }
            case .service(let label):
                let disabled = Launchd.disabledInSession().contains(label)
                if journal.entries[key] == nil || !disabled {
                    journal.entries[key] = .init(previous: .disabled(disabled), date: Date())
                    journal.save()
                }
                if let problem = Launchd.disable(label) { problems.append("\(tweak.title): \(problem)") }
            case .quit(let id):
                let quits = QuitWatcher.apps.contains(id)
                if journal.entries[key] == nil || !quits {
                    journal.entries[key] = .init(previous: .quits(quits), date: Date())
                    journal.save()
                }
                if let problem = QuitWatcher.set(id, quits: true) { problems.append("\(tweak.title): \(problem)") }
            }
        }
        return problems
    }

    /// Puts back what a tweak changed outside the profile: the value from before, or macOS's default when Spare
    /// didn't record one.
    public static func revert(_ tweak: Tweak, journal: inout Journal) -> [String] {
        var problems: [String] = []
        for change in tweak.changes {
            let key = Journal.key(change)
            switch change {
            case .restriction, .forced:
                continue
            case .pref(let domain, let name, _):
                var previous: Value?
                if case .pref(let value)? = journal.entries[key]?.previous { previous = value }
                // The entry stays when macOS didn't take the value, so undo can try again.
                if Prefs.write(domain, name, previous) { journal.entries[key] = nil } else { problems.append("\(tweak.title): macOS didn't take the change.") }
            case .service(let label):
                if case .disabled(true)? = journal.entries[key]?.previous {
                    // It was off before Spare came along, so it stays off.
                    journal.entries[key] = nil
                    continue
                }
                if let problem = Launchd.enable(label) { problems.append("\(tweak.title): \(problem)") } else { journal.entries[key] = nil }
            case .quit(let id):
                if case .quits(true)? = journal.entries[key]?.previous {
                    journal.entries[key] = nil
                    continue
                }
                if let problem = QuitWatcher.set(id, quits: false) { problems.append("\(tweak.title): \(problem)") } else { journal.entries[key] = nil }
            }
        }
        return problems
    }
}

// MARK: - launchd

/// The person's launchd session: which jobs are switched off, and switching one off or on.
extension Launchd {
    static var session: String { "gui/\(getuid())" }

    /// Labels switched off in the person's session.
    public static func disabledInSession() -> Set<String> {
        Set(disabled(domain: session).filter(\.value).map(\.key))
    }

    /// Switches a job off and stops it if it runs. nil when that worked.
    public static func disable(_ label: String) -> String? {
        let target = "\(session)/\(label)"
        let off = launchctl(["disable", target])
        guard off.status == 0 else { return "launchd didn't switch it off: \(off.output.trimmingCharacters(in: .whitespacesAndNewlines))" }
        if launchctl(["print", target]).status == 0 {
            let stop = launchctl(["bootout", target])
            if stop.status != 0 { return "Switched off, but still running until you log out." }
        }
        return nil
    }

    /// Switches a job on again, and starts a system agent that should be running. nil when that worked.
    public static func enable(_ label: String) -> String? {
        let target = "\(session)/\(label)"
        let on = launchctl(["enable", target])
        guard on.status == 0 else { return "launchd didn't switch it on: \(on.output.trimmingCharacters(in: .whitespacesAndNewlines))" }
        let plist = "/System/Library/LaunchAgents/\(label).plist"
        if FileManager.default.fileExists(atPath: plist), launchctl(["print", target]).status != 0 {
            _ = launchctl(["bootstrap", session, plist])
        }
        return nil
    }

    /// Runs launchctl and returns its status and what it printed.
    @discardableResult
    static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "launchctl didn't start.") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Dock

/// The apps kept in the Dock.
public enum Dock {
    static let domain = "com.apple.dock" as CFString

    static func tiles() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]] ?? []
    }

    static func bundleID(_ tile: [String: Any]) -> String? {
        (tile["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
    }

    public static func apps() -> Set<String> { Set(tiles().compactMap(bundleID)) }

    /// Takes an app out of the Dock and returns its tile to put back, or nil when it wasn't there.
    public static func remove(_ id: String) -> Debloat.DockTile? {
        var tiles = tiles()
        guard let index = tiles.firstIndex(where: { bundleID($0) == id }),
              let data = try? PropertyListSerialization.data(fromPropertyList: tiles[index], format: .binary, options: 0) else { return nil }
        tiles.remove(at: index)
        save(tiles)
        return Debloat.DockTile(index: index, plist: data)
    }

    /// Puts a tile back where it was, or adds the app at the end when there's no tile.
    public static func add(_ id: String, tile: Debloat.DockTile?, url: URL) {
        var tiles = tiles()
        guard !tiles.contains(where: { bundleID($0) == id }) else { return }
        if let tile, let saved = try? PropertyListSerialization.propertyList(from: tile.plist, format: nil) as? [String: Any] {
            tiles.insert(saved, at: min(tile.index, tiles.count))
        } else {
            tiles.append(["tile-type": "file-tile",
                          "tile-data": ["bundle-identifier": id,
                                        "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15]]])
        }
        save(tiles)
    }

    static func save(_ tiles: [[String: Any]]) {
        CFPreferencesSetAppValue("persistent-apps" as CFString, tiles as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        _ = Launchd.launchctl(["kickstart", "-k", "\(Launchd.session)/com.apple.Dock.agent"])
    }
}

// MARK: - Undoing everything

extension Debloat {
    /// Whether Spare recorded changing something of this tweak outside the profile and that change is still in place:
    /// only that is Spare's to undo, never a setting the person chose themselves in System Settings, before or since.
    /// `read` gives a setting's value now and `disabled` the jobs switched off; nil doesn't check jobs.
    public static func changedBySpare(_ tweak: Tweak, journal: Journal, read: (String, String) -> Any? = Prefs.read,
                                      disabled: Set<String>? = nil) -> Bool {
        tweak.changes.contains { change in
            guard !change.inProfile, journal.entries[Journal.key(change)] != nil else { return false }
            switch change {
            case .pref(let domain, let name, let value): return value.matches(read(domain, name))
            case .service(let label): return disabled?.contains(label) ?? true
            case .quit(let id): return (read(QuitWatcher.domain, QuitWatcher.key) as? [String])?.contains(id) == true
            case .restriction, .forced: return false
            }
        }
    }

    /// What Spare changed outside its profile, as read now. The Dock isn't part of it: icons taken out stay out.
    public struct Undoable: Sendable, Equatable {
        public var tweaks: [String] = []
        public var blocked: [String] = []
        public var isEmpty: Bool { tweaks.isEmpty && blocked.isEmpty }

        public init(tweaks: [String] = [], blocked: [String] = []) {
            self.tweaks = tweaks
            self.blocked = blocked
        }
    }

    public static func undoable(apps: [BuiltInApp], disabled: Set<String>, journal: Journal = .load(),
                                read: (String, String) -> Any? = Prefs.read) -> Undoable {
        Undoable(tweaks: all.filter { changedBySpare($0, journal: journal, read: read, disabled: disabled) }.map(\.id),
                 blocked: apps.filter { BuiltInApps.block(of: $0, disabled: disabled) != .open }.map(\.bundleID))
    }

    /// Puts back everything Spare changed outside its profile: settings to their values from before, and Apple's apps
    /// allowed to open. Dock icons taken out stay out; each can be put back on Apple Apps. The profile is removed separately, as it needs a password.
    /// Returns problems, and the apps to restart so they notice.
    /// `tweaks` and `unblock` pick what to undo, by tweak id and app bundle identifier; nil undoes all of it.
    /// Spare 0.5 switched the play keys off altogether to keep Music from opening. Now Music is quit instead, so the
    /// keys work again: the service goes back on and the newer way takes its place.
    public static func moveOnFromPlayKeysService() {
        var journal = Journal.load()
        let old = "service:com.apple.rcd"
        guard let entry = journal.entries[old] else { return }
        if case .disabled(true) = entry.previous {} else { _ = Launchd.enable("com.apple.rcd") }
        journal.entries[old] = nil
        journal.save()
        if let tweak = all.first(where: { $0.id == "media-keys" }) { _ = apply(tweak, journal: &journal) }
        journal.save()
    }

    public static func undoLocal(apps: [BuiltInApp], tweaks chosen: Set<String>? = nil, unblock: Set<String>? = nil) -> (problems: [String], restart: Set<String>) {
        var journal = Journal.load()
        var problems: [String] = []
        var restart = Set<String>()
        let jobs = Launchd.disabledInSession()
        for tweak in all where changedBySpare(tweak, journal: journal, disabled: jobs) && chosen?.contains(tweak.id) != false {
            problems += revert(tweak, journal: &journal)
            restart.formUnion(tweak.restart)
        }
        journal.save()
        let disabled = Launchd.disabledInSession()
        for app in apps where BuiltInApps.block(of: app, disabled: disabled) != .open && unblock?.contains(app.bundleID) != false {
            if let problem = BuiltInApps.unblock(app, disabled: disabled) { problems.append("\(app.name): \(problem)") }
        }
        return (problems, restart)
    }
}
