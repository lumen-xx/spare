import AppKit
import SwiftUI
import SpareCore

let home = FileManager.default.homeDirectoryForCurrentUser

/// Runs blocking file work on a background queue, keeping Swift's cooperative threads free.
func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}

enum Preferences {
    static var projectRoots: [URL] {
        get {
            guard let paths = UserDefaults.standard.stringArray(forKey: "projectRoots") else { return Projects.defaultRoots(home: home) }
            return paths.map { URL(fileURLWithPath: $0) }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "projectRoots") }
    }

    static var inactiveDays: Int {
        let days = UserDefaults.standard.integer(forKey: "inactiveDays")
        return days > 0 ? days : 30
    }
}

/// State every screen shares: the disk, permissions, and the message after something moved.
@MainActor
final class Shared: ObservableObject {
    static let shared = Shared()

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var detail: String?
        var session: UUID?
        var problems: [String] = []
        var offerEmptyTrash = false
    }

    @Published private(set) var space: Volume.Space?
    @Published private(set) var volumeName = "Macintosh HD"
    @Published private(set) var fullDiskAccess = Permissions.fullDiskAccess()
    /// Unknown without Full Disk Access: macOS hides the Trash's contents.
    @Published private(set) var trashBytes: Int64?
    @Published var banner: Banner?

    init() { refreshSpace() }

    func refreshSpace() {
        space = Volume.space()
        volumeName = (try? home.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Macintosh HD"
        let access = Permissions.fullDiskAccess()
        if access != fullDiskAccess {
            fullDiskAccess = access
            // Newly visible folders change what there is to find.
            if access { CleanupModel.shared.scanIfStarted() }
        }
        guard access else { trashBytes = nil; return }
        Task {
            let usage = await background { DiskUsage.measure(home.appendingPathComponent(".Trash")) }
            self.trashBytes = usage.bytes + usage.shared
        }
    }

    /// Tells the person what happened after a move: how much, how to undo it, what didn't work.
    func report(_ outcome: Trasher.Outcome, title: String? = nil) {
        let problems = outcome.failures.map { "\($0.url.lastPathComponent): \($0.reason)" }
        if let session = outcome.session {
            banner = Banner(title: title ?? "Moved \(Bytes.text(outcome.bytes)) to the Trash",
                            detail: "The space comes back when you empty the Trash.",
                            session: session.id, problems: problems, offerEmptyTrash: true)
        } else if !problems.isEmpty {
            banner = Banner(title: problems.count == 1 ? "Couldn't move 1 item" : "Couldn't move \(problems.count) items", detail: nil, problems: problems)
        }
    }

    func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = (trashBytes.map { "This permanently deletes \(Bytes.text($0)), " } ?? "This permanently deletes ")
            + "including anything you put in the Trash yourself. Nothing in it can be put back afterwards."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let problem = Privileged.emptyTrash() {
            banner = Banner(title: "The Trash wasn't emptied", detail: problem)
        } else {
            banner = Banner(title: "Emptied the Trash", detail: nil)
            HistoryModel.shared.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refreshSpace() }
        }
        refreshSpace()
    }
}

enum CheckState { case on, off, mixed }

// MARK: - Cleanup

@MainActor
final class CleanupModel: ObservableObject {
    static let shared = CleanupModel()

    @Published private(set) var findings: [String: Finding] = [:]
    /// Rules still looking.
    @Published private(set) var pending: Set<String> = []
    @Published var selected: Set<String> = []
    @Published var expanded: Set<String> = []
    @Published private(set) var scannedAt: Date?
    @Published private(set) var moving = false
    private var cancel = Cancellation()
    private var started = false

    var isScanning: Bool { !pending.isEmpty }

    func startIfNeeded() { if !started { scan() } }
    func scanIfStarted() { if started { scan() } }

    func scan() {
        started = true
        cancel.cancel()
        let token = Cancellation()
        cancel = token
        let fullDiskAccess = Shared.shared.fullDiskAccess
        let context = ScanContext(home: home, projectRoots: Preferences.projectRoots,
                                  inactiveAfter: Double(Preferences.inactiveDays) * 86_400, fullDiskAccess: fullDiskAccess,
                                  appName: { folder in Apps.identifier(in: folder).flatMap { AppLookup.name(for: $0) } },
                                  isOpen: AppLookup.openCheck())
        findings = [:]
        selected = []
        scannedAt = nil
        let rules = Catalog.rules.filter { fullDiskAccess || !$0.needsFullDiskAccess }
        pending = Set(rules.map(\.id))
        for rule in rules {
            Task {
                let items = await background { rule.find(context, token) }
                guard !token.isCancelled else { return }
                self.finish(rule, items.sorted { $0.usage.bytes > $1.usage.bytes })
            }
        }
    }

    private func finish(_ rule: Rule, _ items: [Item]) {
        findings[rule.id] = Finding(rule: rule, items: items)
        if rule.safety != .review { selected.formUnion(items.filter(\.suggested).map(\.id)) }
        pending.remove(rule.id)
        if pending.isEmpty { scannedAt = Date() }
    }

    var allItems: [Item] { findings.values.flatMap(\.items) }
    var selectedItems: [Item] { allItems.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.usage.bytes } }
    var foundBytes: Int64 { findings.values.reduce(0) { $0 + $1.bytes } }

    func bytes(in group: Rule.Group) -> Int64 {
        findings.values.filter { $0.rule.group == group }.reduce(0) { $0 + $1.bytes }
    }

    func state(_ finding: Finding?) -> CheckState {
        guard let finding, !finding.items.isEmpty else { return .off }
        let count = finding.items.filter { selected.contains($0.id) }.count
        return count == 0 ? .off : count == finding.items.count ? .on : .mixed
    }

    func toggle(_ finding: Finding) {
        let ids = finding.items.map(\.id)
        if state(finding) == .on { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    func toggle(_ item: Item) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func moveSelectedToTrash() async {
        let items = selectedItems
        guard !items.isEmpty, !moving else { return }
        moving = true
        // A group of small files is measured as a whole; its parts share the total evenly.
        let entries = items.flatMap { item in item.urls.map { (url: $0, bytes: Optional(item.usage.bytes / Int64(item.urls.count))) } }
        let outcome = await Trasher.move(entries, title: "Cleanup")
        let moved = Set(outcome.session?.records.map(\.original) ?? [])
        for (id, finding) in findings {
            let remaining = finding.items.filter { item in !item.urls.allSatisfy { moved.contains($0.path) } }
            findings[id] = Finding(rule: finding.rule, items: remaining)
        }
        selected = selected.intersection(allItems.map(\.id))
        moving = false
        Shared.shared.report(outcome)
    }
}

// MARK: - Space

@MainActor
final class SpaceModel: ObservableObject {
    static let shared = SpaceModel()
    /// Folders smaller than this aren't remembered while measuring; they are quick to measure again.
    nonisolated static let remembered: Int64 = 512 * 1024

    struct Entry: Identifiable, Equatable {
        let url: URL
        let isFolder: Bool
        var bytes: Int64?
        /// macOS guards it and Spare has no Full Disk Access, so it stays closed.
        var locked = false
        var unreadable = 0
        var id: String { url.path }
        var name: String { FileManager.default.displayName(atPath: url.path) }
    }

    /// The folders from the starting point down to the one shown.
    @Published private(set) var trail: [URL] = [home]
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var measuring = 0
    private var sizes: [String: Int64] = [:]
    /// Folders measured all the way down: every folder inside of at least `remembered` bytes is in `sizes`.
    private var complete: Set<String> = []
    private var cancel = Cancellation()
    private var started = false

    var current: URL { trail.last ?? home }
    var currentBytes: Int64? {
        if let known = sizes[current.path] { return known }
        guard measuring == 0, !entries.isEmpty else { return nil }
        return entries.reduce(0) { $0 + ($1.bytes ?? 0) }
    }
    var largest: Int64 { entries.compactMap(\.bytes).max() ?? 0 }

    func startIfNeeded() { if !started { started = true; load() } }

    func open(_ url: URL) {
        trail.append(url)
        load()
    }

    func go(to index: Int) {
        guard index < trail.count - 1 else { return }
        trail = Array(trail.prefix(index + 1))
        load()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = current
        panel.prompt = "Show"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        trail = [url]
        load()
    }

    func reload() {
        sizes = [:]
        complete = []
        load()
    }

    private func load() {
        cancel.cancel()
        let token = Cancellation()
        cancel = token
        let folder = current
        let guarded = Shared.shared.fullDiskAccess ? [] : Permissions.guardedPaths()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [])) ?? []
        var list: [Entry] = []
        var toMeasure: [URL] = []
        for url in contents where url.lastPathComponent != ".DS_Store" {
            let values = try? url.resourceValues(forKeys: keys)
            let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true
            if !isFolder {
                list.append(Entry(url: url, isFolder: false, bytes: Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)))
            } else if guarded.contains(url.path) {
                list.append(Entry(url: url, isFolder: true, bytes: nil, locked: true))
            } else if let known = sizes[url.path] {
                list.append(Entry(url: url, isFolder: true, bytes: known))
            } else {
                list.append(Entry(url: url, isFolder: true, bytes: nil))
                toMeasure.append(url)
            }
        }
        entries = sorted(list)
        measuring = toMeasure.count
        for url in toMeasure {
            Task {
                let (usage, found) = await background { () -> (Usage, [(String, Int64)]) in
                    var found: [(String, Int64)] = []
                    let usage = DiskUsage.measure(url, skip: guarded, cancel: token, threshold: SpaceModel.remembered) { found.append(($0, $1)) }
                    return (usage, found)
                }
                guard !token.isCancelled else { return }
                for (path, bytes) in found { self.sizes[path] = bytes }
                let total = usage.bytes + usage.shared
                self.sizes[url.path] = total
                self.complete.insert(url.path)
                if let index = self.entries.firstIndex(where: { $0.url == url }) {
                    self.entries[index].bytes = total
                    self.entries[index].unreadable = usage.unreadable
                    self.entries = self.sorted(self.entries)
                }
                self.measuring -= 1
            }
        }
    }

    private func sorted(_ list: [Entry]) -> [Entry] {
        list.sorted { a, b in
            switch (a.bytes, b.bytes) {
            case let (x?, y?): return x != y ? x > y : a.name.localizedStandardCompare(b.name) == .orderedAscending
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    func moveToTrash(_ entry: Entry) async {
        let outcome = await Trasher.move([(entry.url, entry.bytes)], title: "Moved from Space")
        guard outcome.session != nil else { Shared.shared.report(outcome); return }
        entries.removeAll { $0.id == entry.id }
        // Every folder above it is smaller now.
        if let bytes = entry.bytes {
            for path in sizes.keys where entry.url.path.hasPrefix(path + "/") { sizes[path, default: 0] -= bytes }
        }
        sizes.removeValue(forKey: entry.url.path)
        Shared.shared.report(outcome)
    }
}

// MARK: - Apps

@MainActor
final class AppsModel: ObservableObject {
    static let shared = AppsModel()

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var measured: Set<String> = []
    @Published private(set) var loading = false
    @Published var selection: InstalledApp.ID?
    /// Leftovers the person unticked before uninstalling.
    @Published var kept: Set<String> = []
    @Published private(set) var orphans: [Orphan] = []
    @Published private(set) var orphansLoading = false
    @Published var orphanSelection: Set<String> = []
    @Published private(set) var working = false
    private var started = false

    func startIfNeeded() { if !started { load() } }

    func load() {
        started = true
        loading = true
        let fullDiskAccess = Shared.shared.fullDiskAccess
        Task {
            let list = await background { Apps.installed(home: home) }
            self.apps = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.measured = []
            await withTaskGroup(of: (String, Usage, [Leftover]).self) { group in
                for app in list {
                    group.addTask {
                        await background {
                            let cancel = Cancellation()
                            return (app.id, DiskUsage.measure(app.url), app.isApple ? [] : Apps.leftovers(for: app, home: home, fullDiskAccess: fullDiskAccess, cancel: cancel))
                        }
                    }
                }
                for await (id, size, leftovers) in group {
                    guard let index = self.apps.firstIndex(where: { $0.id == id }) else { continue }
                    self.apps[index].size = size
                    self.apps[index].leftovers = leftovers
                    self.measured.insert(id)
                }
            }
            self.loading = false
            self.loadOrphans()
        }
    }

    func loadOrphans() {
        orphansLoading = true
        let installed = Set(apps.map(\.bundleID))
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let fullDiskAccess = Shared.shared.fullDiskAccess
        Task {
            let found = await background { () -> [Orphan] in
                // Background jobs and their prefixes count as in use: "com.google.keystone.agent" keeps "com.google.keystone".
                var jobs = Set<String>()
                let labels = Array(Launchd.services(domain: "gui/\(getuid())").keys) + Array(Launchd.services(domain: "system").keys)
                for label in labels {
                    var parts = label.split(separator: ".").map(String.init)
                    while parts.count >= 3 { jobs.insert(parts.joined(separator: ".")); parts.removeLast() }
                }
                return Apps.orphans(home: home, fullDiskAccess: fullDiskAccess, cancel: Cancellation()) { id in
                    installed.contains(id) || running.contains(id) || jobs.contains(id) || AppLookup.url(for: id) != nil
                }
            }
            self.orphans = found.filter { $0.bytes > 0 }
            self.orphanSelection = self.orphanSelection.intersection(found.map(\.id))
            self.orphansLoading = false
        }
    }

    var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.bytes } }

    func uninstall(_ app: InstalledApp) async {
        guard !working else { return }
        working = true
        defer { working = false }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        if !running.isEmpty {
            running.forEach { $0.terminate() }
            for _ in 0..<30 where running.contains(where: { !$0.isTerminated }) { try? await Task.sleep(nanoseconds: 200_000_000) }
            if running.contains(where: { !$0.isTerminated }) {
                Shared.shared.banner = .init(title: "\(app.name) is still open", detail: "Quit it, then uninstall again.")
                return
            }
        }
        let leftovers = app.leftovers.filter { !kept.contains($0.id) }
        // Stop its login agents before their files go.
        for agent in leftovers where agent.kind == "Login agent" {
            if let label = NSDictionary(contentsOf: agent.url)?["Label"] as? String { launchctl(["bootout", "gui/\(getuid())/\(label)"]) }
        }
        let entries = [(url: app.url, bytes: Optional(app.size.bytes))] + leftovers.map { (url: $0.url, bytes: Optional($0.usage.bytes)) }
        let outcome = await Trasher.move(entries, title: "Uninstalled \(app.name)")
        if !FileManager.default.fileExists(atPath: app.url.path) {
            apps.removeAll { $0.id == app.id }
            selection = nil
        }
        Shared.shared.report(outcome, title: outcome.session.map { _ in "Moved \(app.name) and its files to the Trash" })
    }

    func removeSelectedOrphans() async {
        let chosen = orphans.filter { orphanSelection.contains($0.id) }
        guard !chosen.isEmpty, !working else { return }
        working = true
        defer { working = false }
        let entries = chosen.flatMap { $0.leftovers.map { (url: $0.url, bytes: Optional($0.usage.bytes)) } }
        let outcome = await Trasher.move(entries, title: "Leftovers of removed apps")
        let moved = Set(outcome.session?.records.map(\.original) ?? [])
        orphans = orphans.compactMap { orphan in
            var rest = orphan
            rest.leftovers.removeAll { moved.contains($0.url.path) }
            return rest.leftovers.isEmpty ? nil : rest
        }
        orphanSelection = orphanSelection.intersection(orphans.map(\.id))
        Shared.shared.report(outcome)
    }
}

@discardableResult
func launchctl(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

// MARK: - Background items

@MainActor
final class BackgroundModel: ObservableObject {
    static let shared = BackgroundModel()

    struct Row: Identifiable {
        let item: LaunchItem
        var owner: String?
        var ownerURL: URL?
        /// The owner is a guess from the label's company prefix.
        var guessed = false
        var status: Launchd.Status?
        var id: String { item.id }
        var title: String { owner ?? item.label }
    }

    /// A privileged helper no job starts any more.
    struct Helper: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var helpers: [Helper] = []
    @Published private(set) var loading = false
    @Published private(set) var working = false
    private var started = false

    func startIfNeeded() { if !started { load() } }

    func load() {
        started = true
        loading = true
        Task {
            let (items, services, helpers, apps) = await background { () -> ([LaunchItem], [String: Launchd.Status], [URL], [InstalledApp]) in
                let apps = Apps.installed(home: home)
                let items = LaunchItem.all(home: home, apps: apps.filter { !$0.isApple }.map(\.url))
                var services = Launchd.services(domain: "system")
                services.merge(Launchd.services(domain: "gui/\(getuid())")) { system, _ in system }
                let programs = Set(items.compactMap(\.program))
                let helpers = Catalog.list(URL(fileURLWithPath: "/Library/PrivilegedHelperTools")).filter { !programs.contains($0.path) }
                return (items, services, helpers, apps)
            }
            self.rows = items.map { item in
                var row = Row(item: item, status: services[item.label])
                if let owner = Self.owner(of: item, apps: apps) { row.owner = owner.name; row.ownerURL = owner.url; row.guessed = owner.guessed }
                return row
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            self.helpers = helpers.map { Helper(url: $0) }
            self.loading = false
        }
    }

    static func owner(of item: LaunchItem, apps: [InstalledApp]) -> (name: String, url: URL?, guessed: Bool)? {
        for id in item.associatedBundleIDs {
            if let url = AppLookup.url(for: id) { return (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url, false) }
        }
        if let app = item.programApp, FileManager.default.fileExists(atPath: app.path) {
            return (FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""), app, false)
        }
        if item.label.hasPrefix("homebrew.mxcl.") { return ("Homebrew: " + item.label.dropFirst("homebrew.mxcl.".count), nil, false) }
        let parts = item.label.split(separator: ".")
        if parts.count >= 3 {
            let company = parts.prefix(2).joined(separator: ".") + "."
            if let app = apps.first(where: { !$0.isApple && $0.bundleID.hasPrefix(company) }) { return (app.name, app.url, true) }
        }
        return nil
    }

    func remove(_ row: Row) async {
        guard !working, row.item.scope != .app else { return }
        working = true
        defer { working = false }
        let item = row.item
        if item.scope == .user {
            launchctl(["bootout", "gui/\(getuid())/\(item.label)"])
            let outcome = await Trasher.move([(item.url, nil)], title: "Removed \(row.title)")
            if outcome.session != nil { rows.removeAll { $0.id == row.id } }
            Shared.shared.report(outcome, title: outcome.session.map { _ in "Removed \(row.title) and stopped it" })
            return
        }
        let domain = item.scope == .system ? "system" : "gui/\(getuid())"
        if let record = moveAsAdministrator(item.url, before: "launchctl bootout \(domain)/\(Privileged.quoted(item.label)) 2>/dev/null; ",
                                            prompt: "Spare wants to remove \(row.title)'s background item.") {
            let session = TrashSession(title: "Removed \(row.title)", records: [record], bytes: 0)
            HistoryModel.shared.add(session)
            rows.removeAll { $0.id == row.id }
            Shared.shared.banner = .init(title: "Removed \(row.title) and stopped it", detail: "It's in the Trash. History can put it back.", session: session.id)
        }
    }

    func remove(_ helper: Helper) async {
        guard !working else { return }
        working = true
        defer { working = false }
        if let record = moveAsAdministrator(helper.url, before: "", prompt: "Spare wants to remove a leftover helper tool.") {
            let session = TrashSession(title: "Removed \(helper.url.lastPathComponent)", records: [record], bytes: 0)
            HistoryModel.shared.add(session)
            helpers.removeAll { $0.id == helper.id }
            Shared.shared.banner = .init(title: "Moved \(helper.url.lastPathComponent) to the Trash", detail: nil, session: session.id)
        }
    }

    /// Moves a file only root may touch into the Trash, handing it to the person.
    private func moveAsAdministrator(_ url: URL, before: String, prompt: String) -> TrashRecord? {
        let trash = home.appendingPathComponent(".Trash")
        var target = trash.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            target = trash.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " \(Int(Date().timeIntervalSince1970))." + url.pathExtension)
        }
        let command = before + "mv \(Privileged.quoted(url.path)) \(Privileged.quoted(target.path)) && chown -R \(getuid()) \(Privileged.quoted(target.path))"
        if let problem = Privileged.run(command, prompt: prompt) {
            if problem != "Cancelled." { Shared.shared.banner = .init(title: "Couldn't remove it", detail: problem) }
            return nil
        }
        return TrashRecord(original: url.path, trashed: target.path, bytes: nil)
    }
}

// MARK: - History

@MainActor
final class HistoryModel: ObservableObject {
    static let shared = HistoryModel()
    private let store = TrashHistory(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Spare/History.json"))
    @Published private(set) var sessions: [TrashSession] = []
    /// Changes whenever items may have moved, so their state is read again.
    @Published private(set) var revision = 0

    init() { sessions = store.load() }

    func add(_ session: TrashSession) {
        sessions.insert(session, at: 0)
        store.save(sessions)
    }

    func refresh() { revision += 1 }

    func session(_ id: UUID) -> TrashSession? { sessions.first { $0.id == id } }

    /// Puts items back, asking for a password for ones that came from folders only an administrator can change.
    @discardableResult
    func putBack(_ records: [TrashRecord]) -> [String] {
        var problems: [String] = []
        for record in records where record.state == .inTrash {
            do { try Trash.putBack(record) }
            catch where Trash.isPermission(error) {
                let command = "mkdir -p \(Privileged.quoted(URL(fileURLWithPath: record.original).deletingLastPathComponent().path)) && "
                    + "[ ! -e \(Privileged.quoted(record.original)) ] && mv \(Privileged.quoted(record.trashed)) \(Privileged.quoted(record.original)) && "
                    + "chown -R root:wheel \(Privileged.quoted(record.original))"
                if let problem = Privileged.run(command, prompt: "Spare wants to put an item back."), problem != "Cancelled." {
                    problems.append("\(URL(fileURLWithPath: record.original).lastPathComponent): \(problem)")
                }
            } catch {
                problems.append("\(URL(fileURLWithPath: record.original).lastPathComponent): \(error.localizedDescription)")
            }
        }
        revision += 1
        Shared.shared.refreshSpace()
        return problems
    }

    func putBack(session id: UUID) {
        guard let session = session(id) else { return }
        let problems = putBack(session.records)
        Shared.shared.banner = problems.isEmpty
            ? .init(title: "Put back \(session.title.lowercased().hasPrefix("cleanup") ? "everything from that cleanup" : "everything")", detail: nil)
            : .init(title: "Some items couldn't be put back", detail: nil, problems: problems)
        // What was put back can be found again.
        if session.title == "Cleanup" { CleanupModel.shared.scanIfStarted() }
        if session.title.hasPrefix("Uninstalled") || session.title.hasPrefix("Leftovers") { AppsModel.shared.load() }
        if session.title.hasPrefix("Removed") { BackgroundModel.shared.load() }
    }

    func forget(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        store.save(sessions)
    }
}
