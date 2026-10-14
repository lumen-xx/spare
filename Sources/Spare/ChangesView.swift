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
        // The whole Mac's profiles and the person's, then any `profiles list` knows that the first missed.
        let listed = SystemChanges.profiles(systemProfiler: Data(Shell.run("/usr/sbin/system_profiler", ["-xml", "SPConfigurationProfileDataType"], timeout: 30).output.utf8))
        rows += listed
        rows += SystemChanges.profiles(Shell.run("/usr/bin/profiles", ["list"], timeout: 20).output).filter { row in !listed.contains { $0.id == row.id } }
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

    /// Whether an item is still on the Mac. An account or printer macOS can't answer for counts as still there.
    nonisolated static func stillThere(_ item: SystemChange, rows: [SystemChange]) -> Bool {
        switch item.action {
        case .deleteAccount(let name):
            let read = Shell.run("/usr/bin/dscl", [".", "-read", "/Users/\(name)", "UniqueID"], timeout: 10)
            return read.status == 0 || !read.output.contains("eDSRecordNotFound")
        case .deletePrinter(let queue):
            let read = Shell.run("/usr/bin/lpstat", ["-p", queue], timeout: 10)
            return read.status == 0 || !(read.output.contains("Invalid destination") || read.output.contains("not exist"))
        default:
            return rows.contains { $0.id == item.id }
        }
    }

    /// Deletes hidden accounts and printers and removes privacy decisions, with one administrator prompt for all that
    /// need one. None of this goes through the Trash. What counts as done is what's gone when Spare looks again.
    func apply(_ chosen: [SystemChange]) async {
        let items = chosen.filter(\.removable)
        guard !items.isEmpty, !working else { return }
        working = true
        defer { working = false }
        var problems: [String] = []
        // What ran and what came back, for Copy Error.
        var log = ["Chosen: " + items.map(\.id).joined(separator: ", ")]
        // What to run as root, each with the name its errors are reported under.
        var asAdministrator: [(name: String, command: String)] = []
        var mine: [PrivacyTool.Decision] = [], everyone: [PrivacyTool.Decision] = []
        var accounts: [(title: String, name: String)] = []
        for item in items {
            switch item.action {
            case .deleteAccount(let name):
                // In Spare itself, through macOS's identity API: Directory Services refuses a root shell.
                accounts.append((item.name, name))
            case .removeProfile(let identifier):
                asAdministrator.append((item.name, Debloat.removeProfileCommand(identifier)))
            case .deletePrinter(let queue):
                asAdministrator.append((item.name, "lpadmin -x \(Privileged.quoted(queue))"))
            case .resetPrivacy(let service, let client, let systemWide):
                let decision = PrivacyTool.Decision(service: service, client: client,
                                                    label: "\(item.name) (\(SystemChanges.services[service] ?? service.replacingOccurrences(of: "kTCCService", with: "")))")
                if systemWide { everyone.append(decision) } else { mine.append(decision) }
            case .settings:
                break
            }
        }
        if !mine.isEmpty {
            let database = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
            let script = PrivacyTool.script(mine, database: database), timeout = 30 + 10 * Double(mine.count)
            let result = await background { Shell.run("/bin/sh", ["-c", script], timeout: timeout) }
            log.append("Your own permissions, as \(NSUserName()) (exit \(result.status)):\n\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))\n--- script ---\n\(script)")
            problems += result.output.split(whereSeparator: \.isNewline).map(String.init).filter { $0.contains(": ") }
        }
        if !accounts.isEmpty {
            let prompt = "Spare wants to delete \(accounts.count == 1 ? "a hidden account" : "\(accounts.count) hidden accounts")."
            let asked = await background { LocalAccounts.ask(prompt: prompt) }
            if let permission = asked.permission {
                for account in accounts {
                    let name = account.name
                    if let problem = await background({ LocalAccounts.delete(name, permission: permission) }) {
                        problems.append("\(account.title): \(problem)")
                        log.append("Account \(name): \(problem)")
                    }
                }
            } else if asked.problem == "Cancelled." {
                if accounts.count == items.count { return }
            } else if let problem = asked.problem {
                problems.append(problem)
            }
        }
        // Decisions for the whole Mac can only be removed as an administrator.
        if !everyone.isEmpty {
            // Each failure already names its app, so the part's own name stays out of the lines.
            asAdministrator.append(("", PrivacyTool.script(everyone, database: "/Library/Application Support/com.apple.TCC/TCC.db")))
        }
        if !asAdministrator.isEmpty {
            // Each part runs whatever the others do; what a failing part says is printed under its name.
            let command = asAdministrator.map { part in
                "out=$( (\(part.command)) 2>&1 ) || printf '%s%s\\n' \(Privileged.quoted(part.name.isEmpty ? "" : part.name + ": ")) \"$out\""
            }.joined(separator: "\n")
            // A command the shell can't read would fail after the password, with nothing deleted. Each part is
            // checked on its own: inside $( ) the shell reads a part only when it runs it.
            let parts = [command] + asAdministrator.map(\.command)
            let unreadable = await background {
                parts.lazy.map { Shell.run("/bin/sh", ["-n", "-c", $0], timeout: 10) }.first { $0.status != 0 }
            }
            log.append("Shell check of the administrator command: \(unreadable.map { "exit \($0.status): " + $0.output.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "fine")")
            if let unreadable {
                problems.append("Spare made a command macOS's shell can't read, so it didn't ask for your password: \(unreadable.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            } else {
                let result = Privileged.call(command, prompt: "Spare wants to change \(asAdministrator.count == 1 ? "a setting" : "\(asAdministrator.count) settings") for every account.", privileged: true)
                log.append("As administrator: \(result.problem.map { "failed: " + $0 } ?? "finished")\n\((result.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines))")
                if let problem = result.problem {
                    if problem != "Cancelled." { problems.append(problem) }
                    else if mine.isEmpty && accounts.isEmpty { return }
                }
                problems += (result.output ?? "").split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
        }
        await reload()
        DebloatModel.shared.reloadIfStarted()
        // Accounts and printers are asked about one by one, so a listing that failed never counts as deleted.
        let rows = self.rows
        let stayed = await background { items.filter { Self.stillThere($0, rows: rows) } }
        let left = stayed
        let done = items.count - left.count
        if !asAdministrator.isEmpty {
            log.append("--- administrator command ---\n" + asAdministrator.map { part in "out=$( (\(part.command)) 2>&1 )" }.joined(separator: "\n"))
        }
        log.append("Still listed afterwards: " + (left.isEmpty ? "none" : left.map(\.id).joined(separator: ", ")))
        if !left.isEmpty, problems.isEmpty {
            problems = left.map { "\($0.name) is still there." }
        }
        let verb = items.allSatisfy { switch $0.action { case .deletePrinter, .removeProfile: true; default: false } } ? "Removed" : "Deleted"
        Shared.shared.banner = .init(title: done == 0 ? "Nothing was \(verb.lowercased())" : done == 1 ? "\(verb) 1 item" : "\(verb) \(done) items",
                                     detail: left.isEmpty ? nil : problems.count == 1 ? problems[0] : left.count == 1 ? "macOS kept 1 item." : "macOS kept \(left.count) items.",
                                     problems: problems.count == 1 ? [] : problems, failed: done == 0,
                                     log: left.isEmpty ? nil : log.joined(separator: "\n\n"))
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
                if kind != .vpn && (kind != .profile || mine.contains(where: \.removable)) {
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
            if rows.contains(where: { $0.origin == .spare }) {
                Button("Show in Spare") { Navigation.shared.page = .intelligence }
            }
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

    private var actionTitle: String { kind == .printer || kind == .profile ? "Remove" : "Delete" }

    private var confirmTitle: String {
        let count = chosen.filter(\.removable).count
        switch kind {
        case .privacy: return count == 1 ? "Delete this permission?" : "Delete \(count) permissions?"
        case .account: return count == 1 ? "Delete this hidden account?" : "Delete \(count) hidden accounts?"
        case .profile: return "Remove “Spare Privacy”?"
        default: return count == 1 ? "Remove this printer?" : "Remove \(count) printers?"
        }
    }

    private var confirmMessage: String {
        switch kind {
        case .privacy: "macOS deletes these entries from its permission database. An app that's still installed asks again the next time it needs access. Entries for every account need an administrator password."
        case .profile: "Everything it keeps switched off under Privacy & Debloat is as macOS has it again, and macOS may download Apple Intelligence's models again. macOS asks for an administrator password."
        case .account: "These accounts were created by installers to run their helpers; nobody logs in with them. This can't be undone from the Trash, and macOS asks for an administrator password."
        default: "You can add the printer again in Printers & Scanners settings. macOS asks for an administrator password."
        }
    }

    private var explanation: String {
        switch kind {
        case .account: "Accounts on this Mac besides yours and macOS's own. Hidden accounts were made by installers to run their helpers."
        case .printer: "Printers added to this Mac. Their drivers are under Drivers."
        case .vpn: "VPN configurations apps added. They go with their app, or in Network settings."
        case .profile: "Configuration profiles that change settings or allow management of this Mac. Spare's own can be removed here; others only in Settings."
        case .privacy: "Permissions you gave or refused apps and tools: camera, microphone, screen recording, files and more. Deleting one means the app asks again next time. macOS's own aren't listed."
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
