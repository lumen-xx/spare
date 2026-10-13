import SwiftUI
import SpareCore

struct ExtensionRow: Identifiable {
    var item: Extension
    var id: String { item.id }
    var name: String { item.name }
    var category: String { item.category.rawValue }
    var from: String { item.owner ?? (item.origin == .thirdParty ? "" : item.origin.label) }
    var place: String { item.category == .system ? "System" : item.forAllUsers ? "All accounts" : "Your account" }
    var size: Int64 { item.bytes ?? -1 }
    var state: String { item.state ?? "" }
}

@MainActor
final class ExtensionsModel: ObservableObject {
    static let shared = ExtensionsModel()
    @Published private(set) var rows: [ExtensionRow] = []
    @Published private(set) var loading = false
    @Published private(set) var working = false
    private var started = false

    func startIfNeeded() { if !started { load() } }

    func load() {
        started = true
        loading = true
        Task {
            self.rows = await background { Self.collect() }.map { ExtensionRow(item: $0) }
            self.loading = false
        }
    }

    nonisolated static func collect() -> [Extension] {
        var items = Extensions.systemExtensions(Shell.run("/usr/bin/systemextensionsctl", ["list"], timeout: 20).output)
        // A system extension lives inside the app that installed it, and goes when that app is uninstalled.
        let apps = Apps.installed(home: home)
        for index in items.indices {
            let bundleID = items[index].detail?.components(separatedBy: " · ").last ?? ""
            if let app = apps.first(where: { FileManager.default.fileExists(atPath: $0.url.appendingPathComponent("Contents/Library/SystemExtensions/\(bundleID).systemextension").path) }) {
                items[index].owner = app.name
            }
        }
        for category in Extension.Category.allCases where !category.folders.isEmpty {
            items += Extensions.scan(category, home: home)
        }
        items += Extensions.receipts(Shell.run("/usr/sbin/pkgutil", ["--pkgs"], timeout: 30).output)
        return items
    }

    /// Moves extensions to the Trash: your own without a password, every account's together after one prompt.
    func remove(_ chosen: [ExtensionRow]) async {
        let items = chosen.map(\.item).filter(\.removable)
        guard !items.isEmpty, !working else { return }
        working = true
        defer { working = false }
        var moved = 0
        var problems: [Trash.Failure] = []
        let yours = items.filter { !$0.forAllUsers }
        if !yours.isEmpty {
            let outcome = await Trasher.move(yours.compactMap { item in item.url.map { ($0, item.bytes) } },
                                             title: yours.count == 1 ? "Removed \(yours[0].name)" : "Removed \(yours.count) extensions")
            moved += outcome.session?.records.count ?? 0
            problems += outcome.failures
        }
        let shared = items.filter(\.forAllUsers)
        if !shared.isEmpty {
            // A removed audio driver only disappears once the audio system restarts; sound stops for a moment.
            let after = shared.contains { $0.category == .audioDrivers } ? ["killall coreaudiod"] : []
            if let records = AdminTrash.move(shared.compactMap(\.url), after: after,
                                             prompt: "Spare wants to remove \(shared.count == 1 ? shared[0].name : "\(shared.count) items") installed for every account."),
               !records.isEmpty {
                HistoryModel.shared.add(TrashSession(title: shared.count == 1 ? "Removed \(shared[0].name)" : "Removed \(shared.count) extensions",
                                                     records: records, bytes: shared.compactMap(\.bytes).reduce(0, +)))
                moved += records.count
            }
        }
        load()
        Shared.shared.refreshSpace()
        guard moved > 0 || !problems.isEmpty else { return }
        let restart = items.contains { $0.category == .kernel }
        Shared.shared.banner = .init(title: moved == 1 ? "Moved 1 item to the Trash" : "Moved \(moved) items to the Trash",
                                     detail: restart ? "Kernel extensions unload after a restart." : "History can put them back.",
                                     session: HistoryModel.shared.sessions.first?.id,
                                     problems: problems.map { "\($0.url.lastPathComponent): \($0.reason)" })
    }
}

struct ExtensionsView: View {
    @ObservedObject var model = ExtensionsModel.shared
    @State private var selection = Set<ExtensionRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\ExtensionRow.category), KeyPathComparator(\ExtensionRow.name)]
    @State private var category = "All"
    @State private var hideMacOS = false
    @State private var confirming = false

    private var visible: [ExtensionRow] {
        model.rows.filter { row in
            (category == "All" || row.category == category) && (!hideMacOS || row.item.origin != .macOS)
        }.sorted(using: sortOrder)
    }
    private var chosen: [ExtensionRow] { model.rows.filter { selection.contains($0.id) } }
    private var categories: [Extension.Category] { Extension.Category.allCases.filter { kind in model.rows.contains { $0.item.category == kind } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $category) {
                    Text("Everything (\(model.rows.count))").tag("All")
                    Divider()
                    ForEach(categories, id: \.self) { kind in
                        Text("\(kind.rawValue) (\(model.rows.filter { $0.item.category == kind }.count))").tag(kind.rawValue)
                    }
                }
                .fixedSize()
                Toggle("Hide macOS's own", isOn: $hideMacOS).toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 6)
            if let kind = Extension.Category(rawValue: category) {
                Text(kind.explanation).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 8)
            }
            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 8) {
                        if let url = row.item.url { Image(nsImage: AppLookup.icon(for: url, size: 18)).frame(width: 18, height: 18) }
                        else { Image(systemName: row.item.category.symbol).frame(width: 18).foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 5) { Text(row.name).lineLimit(1); OriginBadge(origin: row.item.origin) }
                            if let detail = row.item.detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        }
                    }
                    .help(row.item.url?.path ?? row.item.detail ?? row.name)
                }
                .width(min: 220, ideal: 320)
                TableColumn("Kind", value: \.category).width(min: 110, ideal: 160)
                TableColumn("From", value: \.from) { row in
                    Text(row.item.owner.map { "Inside \($0)" } ?? row.from)
                }
                .width(min: 70, ideal: 120)
                TableColumn("State", value: \.state) { row in
                    Text(row.item.state ?? "").foregroundStyle(row.item.state?.contains("uninstall") == true ? .orange : .secondary).lineLimit(1)
                }
                .width(min: 60, ideal: 120)
                TableColumn("Where", value: \.place).width(min: 80, ideal: 100)
                TableColumn("Size", value: \.size) { row in SizeText(bytes: row.item.bytes) }.width(min: 60, ideal: 80)
            }
            .contextMenu(forSelectionType: ExtensionRow.ID.self) { ids in
                let rows = model.rows.filter { ids.contains($0.id) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(rows.compactMap(\.item.url)) }
                    .disabled(rows.allSatisfy { $0.item.url == nil })
                if rows.contains(where: { $0.item.category == .system }) {
                    Button("Open Login Items & Extensions Settings…") { Permissions.openLoginItemsSettings() }
                }
                Divider()
                Button("Move to Trash…", role: .destructive) { selection = Set(ids); confirming = true }
                    .disabled(!rows.contains(where: \.item.removable))
            } primaryAction: { ids in
                NSWorkspace.shared.activateFileViewerSelecting(model.rows.filter { ids.contains($0.id) }.compactMap(\.item.url))
            }
            .overlay { if model.loading && model.rows.isEmpty { ProgressView("Looking through drivers and plug-ins…") } }
            actionBar
        }
        .toolbar {
            ToolbarItem {
                Button { model.load() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading).help("Look Again")
            }
        }
        .alert(chosen.filter(\.item.removable).count == 1 ? "Move \(chosen.first { $0.item.removable }?.name ?? "it") to the Trash?"
                                                          : "Move \(chosen.filter(\.item.removable).count) items to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { let rows = chosen; Task { await model.remove(rows) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .onAppear { model.startIfNeeded() }
    }

    private var confirmMessage: String {
        let items = chosen.map(\.item).filter(\.removable)
        var parts: [String] = []
        if items.contains(where: \.forAllUsers) { parts.append("Some are installed for every account, so macOS asks for an administrator password once.") }
        if items.contains(where: { $0.category == .audioDrivers }) { parts.append("The audio system restarts, so sound stops for a moment, including in calls.") }
        if items.contains(where: { $0.category == .kernel }) { parts.append("Kernel extensions unload after a restart.") }
        let skipped = chosen.count - items.count
        if skipped > 0 { parts.append("\(skipped == 1 ? "1 item stays" : "\(skipped) items stay"): macOS's own, or removed with its app or installer.") }
        parts.append("History can put everything back until you empty the Trash.")
        return parts.joined(separator: " ")
    }

    private var actionBar: some View {
        let removable = chosen.filter(\.item.removable)
        return HStack(spacing: 10) {
            Text(chosen.isEmpty ? "\(visible.count) items" : "\(chosen.count) selected" + (removable.count < chosen.count ? " · \(chosen.count - removable.count) can't be moved here" : ""))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if model.working { ProgressView().controlSize(.small) }
            Button("Move to Trash…", role: .destructive) { confirming = true }.disabled(removable.isEmpty || model.working)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}
