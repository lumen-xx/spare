import SwiftUI
import SpareCore

enum StartupState: String {
    case running = "Running", waiting = "Waiting", off = "Off", turnedOff = "Turned off", notAllowed = "Not allowed", leftBehind = "Left behind"
    var color: Color {
        switch self {
        case .running: .green
        case .waiting: .blue
        case .off, .turnedOff: .secondary
        case .notAllowed: .secondary
        case .leftBehind: .orange
        }
    }
    var help: String {
        switch self {
        case .running: "Running now."
        case .waiting: "Loaded, waiting for its next start."
        case .off: "Not loaded right now."
        case .turnedOff: "Turned off: it won't start until it's turned on again."
        case .notAllowed: "Switched off in Login Items settings."
        case .leftBehind: "The program it starts is gone, usually because its app was removed."
        }
    }
}

/// One thing that starts on its own, whichever way it was set up.
struct StartupRow: Identifiable {
    enum Source {
        /// A launchd file Spare can stop, turn off and remove.
        case job(LaunchItem)
        /// Registered by an app with macOS; changed in Login Items settings or by uninstalling the app.
        case record(LoginRecord)
        /// A privileged helper nothing starts any more.
        case helper(URL)
    }

    let id: String
    let source: Source
    var name: String
    var appURL: URL?
    var kind: String
    var schedule: String
    var state: StartupState
    var from: String
    var place: String
    var origin: Origin
    var note: String?
    var stateText: String { state.rawValue }
    /// Opens when you log in, as opposed to running in the background.
    var isLoginItem: Bool { kind == "Opens at login" || kind == "Login helper" }

    var job: LaunchItem? { if case .job(let job) = source { job } else { nil } }
    var removable: Bool {
        guard origin.removable else { return false }
        switch source {
        case .job, .helper: return true
        case .record: return false
        }
    }
    var toggleable: Bool { job != nil && origin.removable }
    var file: URL? {
        switch source {
        case .job(let job): job.url
        case .helper(let url): url
        case .record(let record): record.url.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        }
    }
}

@MainActor
final class StartupModel: ObservableObject {
    static let shared = StartupModel()
    @Published private(set) var rows: [StartupRow] = []
    @Published private(set) var loading = false
    @Published private(set) var working = false
    private var started = false

    func startIfNeeded() { if !started { load() } }

    func load() {
        started = true
        loading = true
        Task {
            self.rows = await background { Self.collect() }
            self.loading = false
        }
    }

    nonisolated static func collect() -> [StartupRow] {
        // macOS's login items dump takes a few seconds; it runs while everything else is read.
        let uid = Int(getuid())
        var dump = ""
        let waiting = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: waiting) { dump = Shell.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 20).output }
        let apps = Apps.installed(home: home)
        let jobs = LaunchItem.all(home: home, apps: [])
        var services = Launchd.services(domain: "system")
        services.merge(Launchd.services(domain: "gui/\(uid)")) { system, _ in system }
        let turnedOffForYou = Launchd.disabled(domain: "gui/\(uid)")
        let turnedOffSystem = Launchd.disabled(domain: "system")
        waiting.wait()
        let records = LoginItems.parse(dump, uid: uid)
        // The database writes home folders as /Users/<uid>/.
        func local(_ path: String?) -> String? { path?.replacingOccurrences(of: "/Users/\(uid)/", with: home.path + "/") }

        var rows: [StartupRow] = []
        for job in jobs {
            let record = records.first { $0.isLegacy && local($0.url) == job.url.path }
            let turnedOff = (job.scope == .system ? turnedOffSystem : turnedOffForYou)[job.label] == true || job.disabled
            let status = services[job.label]
            let state: StartupState = !job.programExists ? .leftBehind : turnedOff ? .turnedOff
                : record?.allowed == false ? .notAllowed : (status?.pid ?? 0) > 0 ? .running : status?.loaded == true ? .waiting : .off
            let owner = owner(of: job, apps: apps)
            rows.append(StartupRow(id: job.url.path, source: .job(job), name: owner?.name ?? job.label, appURL: owner?.url,
                                   kind: job.scope == .system ? "System service" : "Background agent", schedule: job.schedule,
                                   state: state, from: job.label.hasPrefix("homebrew.mxcl.") ? "Homebrew"
                                       : owner.map { $0.guessed ? "Probably \($0.name)" : $0.name } ?? record?.developer ?? "—",
                                   place: job.scope.rawValue, origin: job.label.hasPrefix("com.apple.") ? .apple : .thirdParty,
                                   note: job.note ?? "\(job.programName) · \(job.label)"))
        }

        let byIdentifier = Dictionary(records.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records where !record.isLegacy {
            let kind: String
            switch record.type {
            case "app" where record.enabled: kind = "Opens at login"
            case "login item" where record.enabled: kind = "Login helper"
            case "agent": kind = "Background agent"
            case "daemon": kind = "System service"
            case "background tasks": kind = "Background activity"
            default: continue
            }
            let parent = record.parent.flatMap { byIdentifier[$0] }
            let appPath = [record.url, parent?.url].compactMap { local($0) }.first { $0.hasPrefix("/") && $0.hasSuffix(".app") }
            let label = record.identifier.split(separator: ".", maxSplits: 1).last.map(String.init) ?? record.identifier
            let status = services[label]
            let state: StartupState = !record.allowed ? .notAllowed : !record.enabled ? .off
                : (status?.pid ?? 0) > 0 ? .running : status?.loaded == true ? .waiting : (kind == "Opens at login" ? .waiting : .off)
            let apple = record.bundleID?.hasPrefix("com.apple.") == true || record.developer == "Apple Inc."
            rows.append(StartupRow(id: record.uuid, source: .record(record), name: record.name.replacingOccurrences(of: ".app", with: ""),
                                   appURL: appPath.map { URL(fileURLWithPath: $0) }, kind: kind,
                                   schedule: kind == "Opens at login" || kind == "Login helper" ? "At login" : "When needed",
                                   state: state, from: parent?.name ?? record.developer ?? "—", place: "Inside the app",
                                   origin: apple ? .macOS : .thirdParty,
                                   note: record.bundleID ?? local(record.executable) ?? local(record.url)))
        }

        let programs = Set(jobs.compactMap(\.program))
        for helper in Catalog.list(URL(fileURLWithPath: "/Library/PrivilegedHelperTools")) where !programs.contains(helper.path) {
            rows.append(StartupRow(id: helper.path, source: .helper(helper), name: helper.lastPathComponent, appURL: nil, kind: "Helper tool",
                                   schedule: "Never", state: .leftBehind, from: "—", place: StartupModel.systemPlace,
                                   origin: .thirdParty, note: "Nothing starts this helper any more; usually left by a removed app."))
        }
        return rows
    }

    nonisolated static let systemPlace = LaunchItem.Scope.system.rawValue

    nonisolated static func owner(of item: LaunchItem, apps: [InstalledApp]) -> (name: String, url: URL?, guessed: Bool)? {
        for id in item.associatedBundleIDs {
            if let url = AppLookup.url(for: id) { return (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url, false) }
        }
        if let app = item.programApp, FileManager.default.fileExists(atPath: app.path) {
            return (FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""), app, false)
        }
        if item.label.hasPrefix("homebrew.mxcl.") { return ("Homebrew: " + item.label.dropFirst("homebrew.mxcl.".count), nil, false) }
        if let company = Apps.company(of: item.label),
           let app = apps.first(where: { !$0.isApple && $0.bundleID.hasPrefix(company + ".") }) {
            return (app.name, app.url, true)
        }
        return nil
    }

    /// Stops and removes background items, moving their files to the Trash. Ones in /Library go together after one password prompt.
    func remove(_ chosen: [StartupRow]) async {
        let removable = chosen.filter(\.removable)
        guard !removable.isEmpty, !working else { return }
        working = true
        defer { working = false }
        let uid = getuid()
        let yours = removable.compactMap { row -> LaunchItem? in
            guard let job = row.job, job.scope == .user else { return nil }
            return job
        }
        var moved = 0
        var problems: [Trash.Failure] = []
        if !yours.isEmpty {
            for job in yours { launchctl(["bootout", "gui/\(uid)/\(job.label)"]) }
            let outcome = await Trasher.move(yours.map { ($0.url, nil) }, title: yours.count == 1 ? "Removed \(name(of: yours[0]))" : "Removed \(yours.count) background items")
            moved += outcome.session?.records.count ?? 0
            problems += outcome.failures
        }
        let guarded = removable.filter { $0.job?.scope != .user }
        if !guarded.isEmpty {
            let stops = guarded.compactMap { row -> String? in
                guard let job = row.job else { return nil }
                return "launchctl bootout \(job.scope == .system ? "system" : "gui/\(uid)")/\(Privileged.quoted(job.label))"
            }
            if let records = AdminTrash.move(guarded.compactMap(\.file), before: stops,
                                             prompt: "Spare wants to remove \(guarded.count == 1 ? guarded[0].name : "\(guarded.count) background items")."),
               !records.isEmpty {
                HistoryModel.shared.add(TrashSession(title: guarded.count == 1 ? "Removed \(guarded[0].name)" : "Removed \(guarded.count) background items",
                                                     records: records, bytes: 0))
                moved += records.count
            }
        }
        load()
        guard moved > 0 || !problems.isEmpty else { return }
        Shared.shared.banner = .init(title: moved == 1 ? "Removed 1 item and stopped it" : "Removed \(moved) items and stopped them",
                                     detail: "Their files are in the Trash. History can put them back.",
                                     session: HistoryModel.shared.sessions.first?.id,
                                     problems: problems.map { "\($0.url.lastPathComponent): \($0.reason)" })
    }

    private func name(of job: LaunchItem) -> String { rows.first { $0.id == job.url.path }?.name ?? job.label }

    /// Turns background items off so they don't start again, or back on. Items for your account need no password.
    func setOn(_ on: Bool, _ chosen: [StartupRow]) async {
        let jobs = chosen.filter(\.toggleable).compactMap(\.job)
        guard !jobs.isEmpty, !working else { return }
        working = true
        defer { working = false }
        let uid = getuid()
        for job in jobs where job.scope != .system {
            let target = "gui/\(uid)/\(job.label)"
            if on { launchctl(["enable", target]); launchctl(["bootstrap", "gui/\(uid)", job.url.path]) }
            else { launchctl(["disable", target]); launchctl(["bootout", target]) }
        }
        let system = jobs.filter { $0.scope == .system }
        if !system.isEmpty {
            let command = system.map { job in
                let target = "system/" + Privileged.quoted(job.label)
                return on ? "(launchctl enable \(target); launchctl bootstrap system \(Privileged.quoted(job.url.path))) 2>/dev/null"
                          : "(launchctl disable \(target); launchctl bootout \(target)) 2>/dev/null"
            }.joined(separator: "; ") + "; true"
            if let problem = Privileged.run(command, prompt: "Spare wants to turn \(on ? "on" : "off") \(system.count == 1 ? "a system service" : "\(system.count) system services")."),
               problem != "Cancelled." {
                Shared.shared.banner = .init(title: "Couldn't change it", detail: problem, failed: true)
            }
        }
        load()
        Shared.shared.banner = .init(title: on ? "Turned on \(jobs.count == 1 ? "1 item" : "\(jobs.count) items")"
                                              : "Turned off \(jobs.count == 1 ? "1 item" : "\(jobs.count) items")",
                                     detail: on ? "They start as they're set up to." : "They won't start again until you turn them on. Nothing was removed.")
    }
}

struct StartupView: View {
    enum Part { case login, background }
    enum Filter: String, CaseIterable { case all = "All", added = "Not from Apple", leftBehind = "Left behind" }

    let part: Part
    @ObservedObject var model = StartupModel.shared
    @State private var selection = Set<StartupRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\StartupRow.name)]
    @State private var filter = Filter.all
    @State private var confirming = false

    private var mine: [StartupRow] { model.rows.filter { $0.isLoginItem == (part == .login) } }

    private var visible: [StartupRow] {
        mine.filter { row in
            switch filter {
            case .all: true
            case .added: row.origin == .thirdParty
            case .leftBehind: row.state == .leftBehind
            }
        }.sorted(using: sortOrder)
    }
    private var chosen: [StartupRow] { model.rows.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // A wrapping text with a fixed vertical size can ask for any height while the row is being measured,
                // which made the whole window taller than the screen; two lines are plenty here.
                Text(part == .login
                     ? "Apps and helpers that open when you log in. Apps add these themselves; switch them off in Login Items settings, or uninstall the app."
                     : "Agents, services and helpers that run in the background, at startup or on a schedule. Select several with ⌘ or ⇧.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                if part == .background {
                    Picker("Show", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 8) {
                        if let url = row.appURL { Image(nsImage: AppLookup.icon(for: url, size: 20)).frame(width: 20, height: 20) }
                        else { Image(systemName: row.state == .leftBehind ? "questionmark.folder" : "gearshape.2").frame(width: 20).foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 5) {
                                Text(row.name).lineLimit(1)
                                OriginBadge(origin: row.origin)
                            }
                            if let note = row.note { Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        }
                    }
                    .help(row.note ?? row.name)
                }
                .width(min: 200, ideal: 260)
                TableColumn("Kind", value: \.kind).width(min: 120, ideal: 140)
                TableColumn("Runs", value: \.schedule).width(min: 95, ideal: 115)
                TableColumn("State", value: \.stateText) { row in
                    HStack(spacing: 5) {
                        Circle().fill(row.state.color).frame(width: 6, height: 6)
                        Text(row.state.rawValue).foregroundStyle(row.state == .leftBehind ? .orange : .primary)
                    }
                    .help(row.state.help)
                }
                .width(min: 95, ideal: 105)
                TableColumn("From", value: \.from).width(min: 90, ideal: 130)
                TableColumn("Where", value: \.place).width(min: 100, ideal: 115)
            }
            .contextMenu(forSelectionType: StartupRow.ID.self) { ids in menu(for: model.rows.filter { ids.contains($0.id) }) }
                primaryAction: { ids in
                    let files = model.rows.filter { ids.contains($0.id) }.compactMap { $0.file ?? $0.appURL }
                    if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
                }
            .overlay { if model.loading && model.rows.isEmpty { ProgressView() } }
            actionBar
        }
        .toolbar {
            ToolbarItemGroup {
                Button { Permissions.openLoginItemsSettings() } label: { Label("Login Items Settings", systemImage: "switch.2") }
                    .help("Open Login Items & Extensions in System Settings")
                Button { model.load() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading).help("Look Again")
            }
        }
        .alert(removeTitle, isPresented: $confirming) {
            Button("Remove", role: .destructive) { let rows = chosen; Task { await model.remove(rows) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They stop now and won't start again. \(chosen.contains { $0.removable && $0.job?.scope != .user } ? "macOS asks for an administrator password once. " : "")Their files go to the Trash, and History can put them back. Apps they belong to may stop updating or syncing.")
        }
        .onAppear { model.startIfNeeded() }
    }

    private var removeTitle: String {
        let count = chosen.filter(\.removable).count
        return count == 1 ? "Remove \(chosen.first { $0.removable }?.name ?? "it")?" : "Remove \(count) items?"
    }

    @ViewBuilder
    private func menu(for rows: [StartupRow]) -> some View {
        let files = rows.compactMap { $0.file ?? $0.appURL }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }.disabled(files.isEmpty)
        if rows.contains(where: { if case .record = $0.source { true } else { false } }) {
            Button("Open Login Items Settings…") { Permissions.openLoginItemsSettings() }
        }
        Divider()
        Button("Turn Off") { Task { await model.setOn(false, rows) } }.disabled(!rows.contains(where: \.toggleable))
        Button("Turn On") { Task { await model.setOn(true, rows) } }.disabled(!rows.contains(where: \.toggleable))
        Divider()
        Button("Remove…", role: .destructive) { selection = Set(rows.map(\.id)); confirming = true }.disabled(!rows.contains(where: \.removable))
    }

    private var actionBar: some View {
        let rows = chosen
        let locked = rows.filter { !$0.removable && !$0.toggleable }.count
        return HStack(spacing: 10) {
            Text(rows.isEmpty ? countText(visible.count, "item") : "\(rows.count) selected" + (locked > 0 && part == .background ? " · \(locked) changed only in Settings or by uninstalling the app" : ""))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if model.working { ProgressView().controlSize(.small) }
            if part == .login {
                // Apps register these with macOS themselves; only Login Items settings, or uninstalling the app, changes them.
                Button("Open Login Items Settings…") { Permissions.openLoginItemsSettings() }
            } else {
                Button("Turn Off") { Task { await model.setOn(false, rows) } }.disabled(!rows.contains(where: \.toggleable) || model.working)
                Button("Turn On") { Task { await model.setOn(true, rows) } }.disabled(!rows.contains(where: \.toggleable) || model.working)
                Button("Remove…", role: .destructive) { confirming = true }.disabled(!rows.contains(where: \.removable) || model.working)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}

/// Says where something came from; macOS's own is locked.
struct OriginBadge: View {
    let origin: Origin
    var body: some View {
        switch origin {
        case .macOS:
            Label("macOS", systemImage: "lock.fill").labelStyle(.titleAndIcon)
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .help("Part of macOS. Spare doesn't remove it.")
        case .apple:
            Text("Apple").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .help("Made by Apple and added later. It can be removed.")
        case .thirdParty:
            EmptyView()
        }
    }
}
