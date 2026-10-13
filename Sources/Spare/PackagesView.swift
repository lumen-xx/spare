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

    func load() {
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
        return (packages, found)
    }

    /// Runs each package manager's own uninstall command. Package managers delete directly, so these can't be put
    /// back from the Trash; the confirmation shows how to install them again.
    func uninstall(_ chosen: [PackageRow]) async {
        guard !chosen.isEmpty, !working else { return }
        working = true
        defer { working = false }
        let groups = Dictionary(grouping: chosen.map(\.package)) { "\($0.manager.rawValue)|\($0.isCask)" }
        var removed: [String] = []
        var problems: [String] = []
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
        load()
        Shared.shared.refreshSpace()
        Shared.shared.banner = .init(title: removed.isEmpty ? "Nothing was uninstalled" : "Uninstalled \(removed.count == 1 ? removed[0] : "\(removed.count) packages")",
                                     detail: removed.isEmpty ? nil : "Package managers delete directly, so these aren't in the Trash.", problems: problems, failed: removed.isEmpty)
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
    @ObservedObject var model = PackagesModel.shared
    @State private var selection = Set<PackageRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\PackageRow.name)]
    @State private var manager: String = "All"
    @State private var onlyRequested = false
    @State private var search = ""
    @State private var confirming = false
    @State private var confirmingAutoremove = false

    private var visible: [PackageRow] {
        model.rows.filter { row in
            (manager == "All" || row.manager == manager)
                && (!onlyRequested || row.package.requested)
                && (search.isEmpty || row.name.localizedCaseInsensitiveContains(search) || (row.package.summary ?? "").localizedCaseInsensitiveContains(search))
        }.sorted(using: sortOrder)
    }
    private var chosen: [PackageRow] { model.rows.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Manager", selection: $manager) {
                    Text("All").tag("All")
                    ForEach(model.managers, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .fixedSize()
                Toggle("Only what you installed", isOn: $onlyRequested).toggleStyle(.checkbox)
                    .help("Hide packages that were installed only because another package needs them")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain).frame(width: 160)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            if !model.unused.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "leaf").foregroundStyle(.green)
                    Text("\(model.unused.count == 1 ? "1 Homebrew formula was" : "\(model.unused.count) Homebrew formulae were") installed for packages that are gone, and nothing needs \(model.unused.count == 1 ? "it" : "them") now.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Unused…") { confirmingAutoremove = true }.disabled(model.working)
                }
                .padding(.horizontal, 18).padding(.bottom, 10)
                // Its own view: two alerts on one view and only the last one ever shows.
                .alert("Remove unused Homebrew formulae?", isPresented: $confirmingAutoremove) {
                    Button("Remove", role: .destructive) { Task { await model.autoremove() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("\(model.unused.joined(separator: ", ")). Nothing installed needs them. Homebrew deletes them directly.")
                }
            }
            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name).lineLimit(1)
                        if let summary = row.package.summary, !summary.isEmpty {
                            Text(summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .help(row.package.summary ?? row.name)
                }
                .width(min: 180, ideal: 260)
                TableColumn("Manager", value: \.manager) { row in Text(row.package.isCask ? "Homebrew Cask" : row.manager) }.width(min: 70, ideal: 100)
                TableColumn("Version", value: \.version).width(min: 60, ideal: 80)
                TableColumn("Why It's Here", value: \.why) { row in
                    Text(row.why).foregroundStyle(row.package.requested ? .primary : .secondary)
                }
                .width(min: 110, ideal: 150)
                TableColumn("Needed By", value: \.neededBy) { row in
                    Text(row.package.neededBy.isEmpty ? "—" : row.neededBy)
                        .foregroundStyle(row.package.neededBy.isEmpty ? .tertiary : .primary)
                        .lineLimit(1).help(row.neededBy)
                }
                .width(min: 120, ideal: 200)
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
                if model.loading && model.rows.isEmpty { ProgressView("Asking package managers…") }
                else if !model.loading && model.managers.isEmpty {
                    EmptyNote(symbol: "shippingbox", title: "No package managers found", text: "Spare looks for Homebrew, npm, pnpm, Bun, Cargo, uv and pipx.")
                }
            }
            HStack(spacing: 10) {
                Text(chosen.isEmpty ? "\(visible.count) packages" : "\(chosen.count) selected · \(Bytes.text(chosen.compactMap(\.bytes).reduce(0, +)))")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
                Button("Uninstall…", role: .destructive) { confirming = true }.disabled(chosen.isEmpty || model.working)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Button { model.load() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading).help("Look Again")
            }
        }
        .alert(chosen.count == 1 ? "Uninstall \(chosen[0].name)?" : "Uninstall \(chosen.count) packages?", isPresented: $confirming) {
            Button("Uninstall", role: .destructive) { let rows = chosen; Task { await model.uninstall(rows) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(uninstallMessage)
        }
        .onAppear { model.startIfNeeded() }
    }

    private var uninstallMessage: String {
        let names = Set(chosen.map(\.name))
        let stillNeeded = chosen.filter { !$0.package.neededBy.allSatisfy(names.contains) }
        var text = "Each package manager removes its own packages directly; they don't go to the Trash. To get one back: \(chosen.prefix(3).map(\.package.reinstall).joined(separator: "; "))\(chosen.count > 3 ? "; …" : "")."
        if !stillNeeded.isEmpty {
            text += "\n\n\(stillNeeded.map(\.name).joined(separator: ", ")) \(stillNeeded.count == 1 ? "is" : "are") still needed by \(Set(stillNeeded.flatMap(\.package.neededBy)).subtracting(names).sorted().joined(separator: ", ")). Homebrew refuses to remove packages others need."
        }
        return text
    }
}
