import SwiftUI
import SpareCore

/// A package as the table shows it, with the text columns sort by.
struct PackageRow: Identifiable {
    var package: Package
    var bytes: Int64?
    var id: String { package.id }
    var name: String { package.name }
    var manager: String { package.manager.rawValue }
    var kind: String { package.kind }
    var version: String { package.version }
    var neededBy: String { package.neededBy.joined(separator: ", ") }
    var why: String { package.requested ? "You installed it" : "Needed by another package" }
    var size: Int64 { bytes ?? -1 }
}

@MainActor
final class PackagesModel: ObservableObject {
    static let shared = PackagesModel()
    @Published private(set) var rows: [PackageRow] = []
    @Published private(set) var managers: [Package.Manager] = []
    @Published private(set) var loading = false
    @Published private(set) var working = false
    /// Homebrew formulae nothing needs any more, which `brew autoremove` would remove.
    @Published private(set) var unused: [String] = []
    private var started = false

    func startIfNeeded() { if !started { load() } }

    #if DEBUG
    func showDemo(_ demo: [PackageRow], managers: [Package.Manager], unused: [String]) {
        started = true
        rows = demo
        self.managers = managers
        self.unused = unused
    }
    #endif

    func load() {
        #if DEBUG
        if Demo.isOn { return }
        #endif
        started = true
        loading = true
        Task {
            let (packages, managers) = await background { Self.collect() }
            self.managers = managers
            self.rows = packages.map { PackageRow(package: $0) }
            self.loading = false
            self.unused = await background {
                guard Shell.which("brew") != nil else { return [] }
                // "==> Would autoremove 3 unneeded formulae:" followed by one name per line.
                let output = Shell.run("brew", ["autoremove", "--dry-run"], timeout: 120).output
                return output.split(separator: "\n").filter { !$0.hasPrefix("==>") && !$0.contains(" ") && !$0.isEmpty }.map(String.init)
            }
            // Sizes last: they take the longest and the list is useful without them.
            let sizes = await background { () -> [String: Int64] in
                var sizes: [String: Int64] = [:]
                let measured = Catalog.measure(packages.map { $0.location ?? URL(fileURLWithPath: "/nonexistent") }, cancel: Cancellation())
                for (index, package) in packages.enumerated() where package.location != nil { sizes[package.id] = measured[index].bytes }
                return sizes
            }
            for index in self.rows.indices { self.rows[index].bytes = sizes[self.rows[index].id] }
        }
    }

    nonisolated static func collect() -> ([Package], [Package.Manager]) {
        var packages: [Package] = []
        var found: [Package.Manager] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if Shell.which("brew") != nil {
            found.append(.homebrew)
            let prefix = Shell.run("brew", ["--prefix"], timeout: 30).output.trimmingCharacters(in: .whitespacesAndNewlines)
            packages += PackageParsing.homebrew(Data(Shell.run("brew", ["info", "--json=v2", "--installed"], timeout: 120).output.utf8), prefix: prefix)
        }
        if Shell.which("npm") != nil {
            found.append(.npm)
            let root = Shell.run("npm", ["root", "-g"], timeout: 30).output.trimmingCharacters(in: .whitespacesAndNewlines)
            packages += PackageParsing.npm(Data(Shell.run("npm", ["ls", "-g", "--depth=0", "--json"], timeout: 60).output.utf8), root: root)
        }
        if Shell.which("pnpm") != nil {
            found.append(.pnpm)
            packages += PackageParsing.pnpm(Data(Shell.run("pnpm", ["ls", "-g", "--json"], timeout: 60).output.utf8))
        }
        if Shell.which("bun") != nil {
            found.append(.bun)
            packages += PackageParsing.bun(Shell.run("bun", ["pm", "ls", "-g"], timeout: 60).output, root: home + "/.bun/install/global/node_modules")
        }
        if Shell.which("cargo") != nil {
            found.append(.cargo)
            packages += PackageParsing.cargo(Shell.run("cargo", ["install", "--list"], timeout: 60).output, bin: home + "/.cargo/bin")
        }
        if Shell.which("uv") != nil {
            found.append(.uv)
            let root = Shell.run("uv", ["tool", "dir"], timeout: 30).output.trimmingCharacters(in: .whitespacesAndNewlines)
            packages += PackageParsing.uv(Shell.run("uv", ["tool", "list"], timeout: 60).output, root: root)
        }
        if Shell.which("pipx") != nil {
            found.append(.pipx)
            packages += PackageParsing.pipx(Data(Shell.run("pipx", ["list", "--json"], timeout: 60).output.utf8))
        }
        packages += Toolchains.find(home: FileManager.default.homeDirectoryForCurrentUser)
        packages += HandTools.find { path in
            Shell.run("/usr/sbin/pkgutil", ["--file-info", path], timeout: 10).output
                .split(separator: "\n").first { $0.hasPrefix("pkgid: ") }.map { String($0.dropFirst("pkgid: ".count)) }
        }
        return (packages, found)
    }

    /// Removes packages the way each is meant to go: the package manager's own uninstall command, a specific command
    /// such as `rustup toolchain uninstall`, or moving a folder or file to the Trash (one password prompt for what only
    /// an administrator may move). Package managers delete directly, so their packages can't be put back from the Trash.
    func uninstall(_ chosen: [PackageRow]) async {
        let removable = chosen.map(\.package).filter { $0.origin.removable || $0.manager == .toolchain }
        guard !removable.isEmpty, !working else { return }
        working = true
        defer { working = false }
        var removed: [String] = []
        var problems: [String] = []

        let managed = removable.filter { $0.removal == .manager }
        let groups = Dictionary(grouping: managed) { "\($0.manager.rawValue)|\($0.isCask)" }
        for (_, packages) in groups.sorted(by: { $0.key < $1.key }) {
            guard let first = packages.first else { continue }
            let command = first.manager.uninstall + (first.isCask ? ["--cask"] : [])
            let result = await background { Shell.run(command[0], Array(command.dropFirst()) + packages.map(\.name), timeout: 600) }
            if result.succeeded { removed += packages.map(\.name) }
            else if result.output.contains("sudo") || result.output.localizedCaseInsensitiveContains("password") {
                // Some casks remove files only an administrator may; Homebrew asks for the password in Terminal only.
                problems.append("\(first.manager.rawValue) needs your password for this. In Terminal, run: \(command.joined(separator: " ")) \(packages.map(\.name).joined(separator: " "))")
            } else {
                // Keep the tool's own words; Homebrew explains which package still needs it.
                let lines = result.output.split(separator: "\n").map(String.init).filter { $0.localizedCaseInsensitiveContains("error") || $0.contains("required by") || $0.contains("Refusing") }
                problems.append("\(first.manager.rawValue): " + (lines.isEmpty ? String(result.output.suffix(400)) : lines.prefix(4).joined(separator: " ")))
            }
        }

        for package in removable {
            guard case .command(let command) = package.removal else { continue }
            let result = await background { Shell.run(command[0], Array(command.dropFirst()), timeout: 600) }
            if result.succeeded { removed.append(package.name) } else { problems.append("\(package.name): " + String(result.output.suffix(300))) }
        }

        // Folders and files: your own go to the Trash directly; ones in shared places together after one password prompt.
        let trashed = removable.filter { $0.removal == .trash && $0.location != nil }
        let yours = trashed.filter { FileManager.default.isWritableFile(atPath: $0.location!.deletingLastPathComponent().path) }
        if !yours.isEmpty {
            let outcome = await Trasher.move(yours.map { ($0.location!, nil) }, title: yours.count == 1 ? "Removed \(yours[0].name)" : "Removed \(yours.count) tools")
            let moved = Set(outcome.session?.records.map(\.original) ?? [])
            removed += yours.filter { moved.contains($0.location!.path) }.map(\.name)
            problems += outcome.failures.map { "\($0.url.lastPathComponent): \($0.reason)" }
        }
        let guarded = trashed.filter { !FileManager.default.isWritableFile(atPath: $0.location!.deletingLastPathComponent().path) }
        if !guarded.isEmpty, let records = AdminTrash.move(guarded.map { $0.location! },
                                                           prompt: "Spare wants to remove \(guarded.count == 1 ? guarded[0].name : "\(guarded.count) tools") installed for every account.") {
            if !records.isEmpty {
                HistoryModel.shared.add(TrashSession(title: guarded.count == 1 ? "Removed \(guarded[0].name)" : "Removed \(guarded.count) tools", records: records, bytes: 0))
            }
            let moved = Set(records.map(\.original))
            removed += guarded.filter { moved.contains($0.location!.path) }.map(\.name)
        }

        load()
        Shared.shared.refreshSpace()
        let inTrash = trashed.contains { removed.contains($0.name) }
        Shared.shared.banner = .init(title: removed.isEmpty ? "Nothing was removed" : "Removed \(removed.count == 1 ? removed[0] : "\(removed.count) items")",
                                     detail: removed.isEmpty ? nil : inTrash ? "Folders and files are in the Trash; History can put them back." : "Package managers delete directly, so these aren't in the Trash.",
                                     session: inTrash ? HistoryModel.shared.sessions.first?.id : nil,
                                     problems: problems, failed: removed.isEmpty)
    }

    func autoremove() async {
        guard !working else { return }
        working = true
        defer { working = false }
        let result = await background { Shell.run("brew", ["autoremove"], timeout: 600) }
        let count = unused.count
        load()
        Shared.shared.banner = .init(title: result.succeeded ? "Removed \(count == 1 ? "1 unused formula" : "\(count) unused formulae")" : "Homebrew couldn't clean up",
                                     detail: result.succeeded ? nil : String(result.output.suffix(300)), failed: !result.succeeded)
    }
}

struct PackagesView: View {
    enum Part { case managers, toolchains, manual }
    let part: Part
    @ObservedObject var model = PackagesModel.shared
    @State private var selection = Set<PackageRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\PackageRow.name)]
    @State private var manager: String = "All"
    @State private var onlyRequested = false
    @State private var search = ""
    @State private var confirming = false
    @State private var confirmingAutoremove = false

    private var mine: [PackageRow] {
        model.rows.filter { row in
            switch part {
            case .managers: row.package.manager != .toolchain && row.package.manager != .manual
            case .toolchains: row.package.manager == .toolchain
            case .manual: row.package.manager == .manual
            }
        }
    }

    private var visible: [PackageRow] {
        mine.filter { row in
            (manager == "All" || row.manager == manager)
                && (!onlyRequested || row.package.requested)
                && (search.isEmpty || row.name.localizedCaseInsensitiveContains(search) || (row.package.summary ?? "").localizedCaseInsensitiveContains(search))
        }.sorted(using: sortOrder)
    }
    private var chosen: [PackageRow] { mine.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            filters.arrives(0)
            if part == .managers && !model.unused.isEmpty { unusedNote.arrives(1) }
            TableCard { table }.arrives(2, rise: 0)
            ActionBar {
                Text(chosen.isEmpty ? countText(visible.count, "item") : "\(chosen.count) selected · \(Bytes.text(chosen.compactMap(\.bytes).reduce(0, +)))")
                    .font(.spare(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.count, value: chosen.count)
                Spacer()
                if model.working { ThinkingDots() }
                Button(part == .managers ? "Uninstall…" : "Remove…", role: .destructive) { confirming = true }
                    .spareButton(.secondary)
                    .disabled(chosen.isEmpty || model.working)
            }
            .arrives(3)
        }
        .arrivalStage(replay: model.rows.isEmpty)
        .toolbar {
            ToolbarItem {
                Button { model.load() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading).help("Look Again")
            }
        }
        .alert(chosen.count == 1 ? "Remove \(chosen[0].name)?" : "Remove \(chosen.count) items?", isPresented: $confirming) {
            Button("Remove", role: .destructive) { let rows = chosen; Task { await model.uninstall(rows) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(uninstallMessage)
        }
        .onAppear { model.startIfNeeded() }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            if part == .managers {
                Picker("Manager", selection: $manager) {
                    Text("All").tag("All")
                    ForEach(model.managers, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .fixedSize()
                Toggle("Only what you installed", isOn: $onlyRequested)
                    .toggleStyle(SpareCheckStyle())
                    .help("Hide packages that were installed only because another package needs them")
            } else {
                Text(part == .toolchains
                     ? "Language versions and SDKs: Rust toolchains, Node, Python and Ruby versions, Xcode's Command Line Tools."
                     : "Commands in /usr/local that no package manager tracks: copied there by hand or by an app's installer.")
                    .font(.spare(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            SearchField(prompt: "Search", text: $search).frame(width: 190)
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 12)
    }

    private var unusedNote: some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: "leaf", tint: Ink.sage, size: 24)
            Text("\(model.unused.count == 1 ? "1 Homebrew formula was" : "\(model.unused.count) Homebrew formulae were") installed for packages that are gone, and nothing needs \(model.unused.count == 1 ? "it" : "them") now.")
                .font(.spare(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("Remove Unused…") { confirmingAutoremove = true }
                .spareButton(.secondary).controlSize(.small)
                .disabled(model.working)
        }
        .padding(.horizontal, 22).padding(.bottom, 12)
        // Its own view: two alerts on one view and only the last one ever shows.
        .alert("Remove unused Homebrew formulae?", isPresented: $confirmingAutoremove) {
            Button("Remove", role: .destructive) { Task { await model.autoremove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.unused.joined(separator: ", ")). Nothing installed needs them. Homebrew deletes them directly.")
        }
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) { Text(row.name).lineLimit(1); OriginBadge(origin: row.package.origin) }
                    if let note = row.package.note {
                        Text(note).font(.spare(size: 10.5)).foregroundStyle(row.package.kind == "Broken link" ? Ink.warm : Color.secondary).lineLimit(1)
                    } else if let summary = row.package.summary, !summary.isEmpty {
                        Text(summary).font(.spare(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help([row.package.summary, row.package.note, row.package.location?.path].compactMap { $0 }.joined(separator: "\n"))
            }
            .width(min: 180, ideal: 260)
            TableColumn(part == .managers ? "Manager" : "Kind", value: \.kind) { row in
                Text(part == .managers ? (row.package.isCask ? "Homebrew Cask" : row.manager) : row.kind)
            }
            .width(min: 70, ideal: 110)
            TableColumn("Version", value: \.version).width(min: 60, ideal: 80)
            TableColumn(part == .managers ? "Why It's Here" : "Where", value: \.why) { row in
                if part == .managers {
                    Text(row.why).foregroundStyle(row.package.requested ? .primary : .secondary)
                } else {
                    Text(row.package.location.map { Catalog.tilde($0, home: home) } ?? "—").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 110, ideal: 190)
            TableColumn("Needed By", value: \.neededBy) { row in
                Text(row.package.neededBy.isEmpty ? "—" : row.neededBy)
                    .foregroundStyle(row.package.neededBy.isEmpty ? .tertiary : .primary)
                    .lineLimit(1).help(row.neededBy)
            }
            .width(min: 90, ideal: 160)
            TableColumn("Size", value: \.size) { row in SizeText(bytes: row.bytes) }.width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: PackageRow.ID.self) { ids in
            let rows = model.rows.filter { ids.contains($0.id) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(rows.compactMap(\.package.location)) }
                .disabled(rows.allSatisfy { $0.package.location == nil })
            Button("Copy Install Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rows.map(\.package.reinstall).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Uninstall…", role: .destructive) { selection = Set(ids); confirming = true }
        }
        .overlay {
            if model.loading && model.rows.isEmpty {
                VStack(spacing: 8) { ThinkingDots(); Text("Asking package managers").font(.spare(size: 12)).foregroundStyle(.secondary) }
            } else if !model.loading && mine.isEmpty {
                EmptyState(doodle: .box, title: "Nothing here", text: "Spare looks for Homebrew, npm, pnpm, Bun, Cargo, uv and pipx packages, language versions, and tools in /usr/local.")
            }
        }
    }

    private var uninstallMessage: String {
        if part != .managers {
            let notes = chosen.compactMap(\.package.note).filter { !$0.hasPrefix("Installed by") }
            return (["Folders and files go to the Trash, and History can put them back. Rust toolchains are removed with rustup."] + notes).joined(separator: "\n\n")
        }
        let names = Set(chosen.map(\.name))
        let stillNeeded = chosen.filter { !$0.package.neededBy.allSatisfy(names.contains) }
        var text = "Each package manager removes its own packages directly; they don't go to the Trash. To get one back: \(chosen.prefix(3).map(\.package.reinstall).joined(separator: "; "))\(chosen.count > 3 ? "; …" : "")."
        if !stillNeeded.isEmpty {
            text += "\n\n\(stillNeeded.map(\.name).joined(separator: ", ")) \(stillNeeded.count == 1 ? "is" : "are") still needed by \(Set(stillNeeded.flatMap(\.package.neededBy)).subtracting(names).sorted().joined(separator: ", ")). Homebrew refuses to remove packages others need."
        }
        return text
    }
}
