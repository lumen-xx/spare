import SwiftUI
import SpareCore

@MainActor
final class SystemChangesModel: ObservableObject {
    static let shared = SystemChangesModel()
    @Published private(set) var rows: [SystemChange] = []
    @Published private(set) var loading = false
    @Published private(set) var working = false
    private var started = false

    func startIfNeeded() { if !started { load() } }
    func reloadIfStarted() { if started { load() } }

    func load() {
        #if DEBUG
        if Demo.isOn { return }
        #endif
        started = true
        loading = true
        Task {
            await reload()
            self.loading = false
        }
    }

    private func reload() async {
        let fullDiskAccess = Shared.shared.fullDiskAccess
        rows = await background { Self.collect(fullDiskAccess: fullDiskAccess) }
    }

    nonisolated static func collect(fullDiskAccess: Bool) -> [SystemChange] {
        var rows: [SystemChange] = []
        let me = NSUserName()
        rows += SystemChanges.accounts(list: Shell.run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"], timeout: 20).output, me: me) { name in
            Shell.run("/usr/bin/dscl", [".", "-read", "/Users/\(name)", "NFSHomeDirectory", "RealName", "UserShell"], timeout: 10).output
        }
        rows += SystemChanges.printers(devices: Shell.run("/usr/bin/lpstat", ["-v"], timeout: 20).output,
                                       states: Shell.run("/usr/bin/lpstat", ["-p"], timeout: 20).output)
        rows += SystemChanges.vpns(Shell.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 20).output) { AppLookup.name(for: $0) }
        rows += SystemChanges.profiles(Shell.run("/usr/bin/profiles", ["list"], timeout: 20).output)
        // macOS keeps privacy decisions in two databases it guards; Spare can read them only with Full Disk Access.
        if fullDiskAccess {
            for (scope, database) in [("user", home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path),
                                      ("system", "/Library/Application Support/com.apple.TCC/TCC.db")] {
                let output = Shell.run("/usr/bin/sqlite3", ["-readonly", "-separator", "|", database,
                                                            "select service, client, client_type, auth_value, last_modified from access"], timeout: 20).output
                rows += SystemChanges.privacy(output, scope: scope, appName: { AppLookup.name(for: $0) },
                                              exists: { FileManager.default.fileExists(atPath: $0) })
            }
        }
        return rows
    }

    /// Deletes hidden accounts and printers and removes privacy decisions, with one administrator prompt for all that
    /// need one. None of this goes through the Trash. What counts as done is what's gone when Spare looks again.
    func apply(_ chosen: [SystemChange]) async {
        let items = chosen.filter(\.removable)
        guard !items.isEmpty, !working else { return }
        working = true
        defer { working = false }
        var problems: [String] = []
        var asAdministrator: [String] = []
        var mine: [(service: String, client: String)] = [], everyone: [(service: String, client: String)] = []
        for item in items {
            switch item.action {
            case .deleteAccount(let name):
                // The account, and the group of the same name installers create alongside it.
                asAdministrator.append("dscl . -delete /Users/\(Privileged.quoted(name)); dscl . -delete /Groups/\(Privileged.quoted(name)) 2>/dev/null")
            case .deletePrinter(let queue):
                asAdministrator.append("lpadmin -x \(Privileged.quoted(queue))")
            case .resetPrivacy(let service, let client, let systemWide):
                if systemWide { everyone.append((service, client)) } else { mine.append((service, client)) }
            case .settings:
                break
            }
        }
        if !mine.isEmpty {
            let script = PrivacyTool.script(mine), timeout = 30 + 10 * Double(mine.count)
            _ = await background { Shell.run("/bin/sh", ["-c", script], timeout: timeout) }
        }
        // Decisions for the whole Mac can only be removed as an administrator.
        if !everyone.isEmpty { asAdministrator.append(PrivacyTool.script(everyone)) }
        if !asAdministrator.isEmpty {
            let command = asAdministrator.map { "(\($0))" }.joined(separator: "; ")
            if let problem = Privileged.run(command + "; true", prompt: "Spare wants to change \(asAdministrator.count == 1 ? "a setting" : "\(asAdministrator.count) settings") for every account.") {
                if problem != "Cancelled." { problems.append(problem) }
                else if asAdministrator.count == items.count { return }
            }
        }
        await reload()
        let left = items.filter { item in rows.contains { $0.id == item.id } }
        let done = items.count - left.count
        if !left.isEmpty, problems.isEmpty {
            problems = left.map { "\($0.name) is still there." }
        }
        let verb = items.allSatisfy { if case .deletePrinter = $0.action { true } else { false } } ? "Removed" : "Deleted"
        Shared.shared.banner = .init(title: done == 0 ? "Nothing was \(verb.lowercased())" : done == 1 ? "\(verb) 1 item" : "\(verb) \(done) items",
                                     detail: left.isEmpty ? nil : left.count == 1 ? "macOS kept 1 item." : "macOS kept \(left.count) items.",
                                     problems: problems, failed: done == 0)
    }
}

struct ChangesView: View {
    let kind: SystemChange.Kind
    @ObservedObject var model = SystemChangesModel.shared
    @ObservedObject var shared = Shared.shared
    @State private var selection = Set<SystemChange.ID>()
    @State private var sortOrder = [KeyPathComparator(\SystemChange.name)]
    @State private var onlyGone = false
    @State private var confirming = false

    private var mine: [SystemChange] { model.rows.filter { $0.kind == kind } }
    private var visible: [SystemChange] { mine.filter { !onlyGone || $0.ownerGone }.sorted(using: sortOrder) }
    private var chosen: [SystemChange] { mine.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(explanation).font(.spare(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if kind == .privacy && mine.contains(where: \.ownerGone) {
                    Toggle("Only apps that are gone", isOn: $onlyGone).toggleStyle(SpareCheckStyle()).fixedSize()
                }
                if let settings = settingsURL {
                    Button("Open Settings…") { NSWorkspace.shared.open(settings) }.spareButton(.secondary).controlSize(.small)
                }
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 12)
            .arrives(0)
            if kind == .privacy && !shared.fullDiskAccess {
                FullDiskAccessNote(compact: true).padding(.horizontal, 18).padding(.bottom, 12).arrives(1)
            }
            TableCard { table }.arrives(2, rise: 0)
            ActionBar {
                Text(chosen.isEmpty ? countText(visible.count, "item") : "\(chosen.count) selected" + (chosen.contains { !$0.removable } ? " · \(chosen.filter { !$0.removable }.count) changed only in Settings" : ""))
                    .font(.spare(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.working { ThinkingDots() }
                if kind != .vpn && kind != .profile {
                    Button(actionTitle + "…", role: .destructive) { confirming = true }
                        .spareButton(.secondary)
                        .disabled(!chosen.contains(where: \.removable) || model.working)
                }
            }
            .arrives(3)
        }
        .arrivalStage(replay: model.rows.isEmpty)
        .toolbar {
            ToolbarItem {
                Button { Refresh.everything() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading).help("Look Again")
            }
        }
        .alert(confirmTitle, isPresented: $confirming) {
            Button(actionTitle, role: .destructive) { let rows = chosen; Task { await model.apply(rows) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .onAppear { model.startIfNeeded() }
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(row.name).lineLimit(1)
                        OriginBadge(origin: row.origin)
                    }
                    if let detail = row.detail {
                        Text(detail).font(.spare(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .help(row.detail ?? row.name)
            }
            .width(min: 220, ideal: 340)
            TableColumn("State", value: \.stateText) { row in
                Text(row.state ?? "—").foregroundStyle(row.state == "Allowed" || row.state == "Connected" ? .primary : .secondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("App", value: \.ownerText) { row in
                Text(row.ownerGone ? "Gone" : row.owner ?? "—").foregroundStyle(row.ownerGone ? Ink.warm : .secondary)
            }
            .width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: SystemChange.ID.self) { ids in
            let rows = mine.filter { ids.contains($0.id) }
            if let settings = settingsURL { Button("Open Settings…") { NSWorkspace.shared.open(settings) } }
            Divider()
            Button(actionTitle + "…", role: .destructive) { selection = Set(ids); confirming = true }
                .disabled(!rows.contains(where: \.removable))
        }
        .overlay {
            if model.loading && model.rows.isEmpty {
                VStack(spacing: 8) { ThinkingDots(); Text("Looking").font(.spare(size: 12)).foregroundStyle(.secondary) }
            } else if !model.loading && mine.isEmpty {
                EmptyState(doodle: kind == .privacy && !shared.fullDiskAccess ? .lock : .sprout, title: "Nothing added", text: emptyText)
            }
        }
    }

    private var actionTitle: String { kind == .printer ? "Remove" : "Delete" }

    private var confirmTitle: String {
        let count = chosen.filter(\.removable).count
        switch kind {
        case .privacy: return count == 1 ? "Delete this permission?" : "Delete \(count) permissions?"
        case .account: return count == 1 ? "Delete this hidden account?" : "Delete \(count) hidden accounts?"
        default: return count == 1 ? "Remove this printer?" : "Remove \(count) printers?"
        }
    }

    private var confirmMessage: String {
        switch kind {
        case .privacy: "macOS deletes these entries from its permission database. An app that's still installed asks again the next time it needs access. Entries for every account need an administrator password."
        case .account: "These accounts were created by installers to run their helpers; nobody logs in with them. This can't be undone from the Trash, and macOS asks for an administrator password."
        default: "You can add the printer again in Printers & Scanners settings. macOS asks for an administrator password."
        }
    }

    private var explanation: String {
        switch kind {
        case .account: "Accounts on this Mac besides yours and macOS's own. Hidden accounts were made by installers to run their helpers."
        case .printer: "Printers added to this Mac. Their drivers are under Drivers."
        case .vpn: "VPN configurations apps added. They go with their app, or in Network settings."
        case .profile: "Configuration profiles that change settings or allow management of this Mac."
        case .privacy: "Permissions you gave apps: camera, microphone, screen recording, files and more. macOS's own aren't listed."
        }
    }

    private var emptyText: String {
        switch kind {
        case .account: "No accounts besides yours."
        case .printer: "No printers have been added."
        case .vpn: "No VPN configurations."
        case .profile: "No configuration profiles are installed."
        case .privacy: shared.fullDiskAccess ? "No permissions given to apps." : "Spare needs Full Disk Access to read these."
        }
    }

    private var settingsURL: URL? {
        switch kind {
        case .account: URL(string: SystemChanges.usersSettings)
        case .printer: URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension")
        case .vpn: URL(string: SystemChanges.networkSettings)
        case .profile: URL(string: SystemChanges.profilesSettings)
        case .privacy: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")
        }
    }
}

extension SystemChange {
    var stateText: String { state ?? "" }
    var ownerText: String { ownerGone ? "Gone" : owner ?? "" }
}
