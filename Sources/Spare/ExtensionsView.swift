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
        // A system extension lives inside the app that installed it, and macOS removes it only together with that app.
        let apps = Apps.installed(home: home)
        for index in items.indices {
            let bundleID = items[index].detail?.components(separatedBy: " · ").last ?? ""
            if let app = apps.first(where: { FileManager.default.fileExists(atPath: $0.url.appendingPathComponent("Contents/Library/SystemExtensions/\(bundleID).systemextension").path) }) {
                items[index].owner = app.name
                items[index].ownerURL = app.url
            }
            let owner = items[index].owner
            items[index].note = items[index].state == "Removed at restart" ? "An older copy macOS removes the next time you restart."
                : owner.map { "Goes away when you uninstall \($0)." }
                ?? "Its app is gone. macOS removes it only with its app: install the app again, then move it to the Trash."
                    + (items[index].state == "Off" ? " It's switched off, so it does nothing meanwhile." : "")
        }
        for category in Extension.Category.allCases where !category.folders.isEmpty {
            items += Extensions.scan(category, home: home)
        }
        items += receipts()
        return items
    }

    /// Installer packages other than Apple's, with what each still has on the disk.
    nonisolated static func receipts() -> [Extension] {
        var items = Extensions.receipts(Shell.run("/usr/sbin/pkgutil", ["--pkgs"], timeout: 30).output)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            let id = items[index].name
            let infoText = Shell.run("/usr/sbin/pkgutil", ["--pkg-info-plist", id], timeout: 20).output
            let info = (try? PropertyListSerialization.propertyList(from: Data(infoText.utf8), format: nil)) as? [String: Any] ?? [:]
            let volume = URL(fileURLWithPath: info["volume"] as? String ?? "/")
            let files = Shell.run("/usr/sbin/pkgutil", ["--files", id], timeout: 30).output.split(separator: "\n").map(String.init)
            let plan = Receipts.plan(id: id, volume: volume, location: info["install-location"] as? String ?? "/", files: files)
            let bytes = Catalog.measure(plan.roots, cancel: Cancellation()).reduce(0) { $0 + $1.bytes }
            let installed = (info["install-time"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            let detail = [(info["pkg-version"] as? String).map { "Version " + $0 }, installed.map { "installed " + $0.formatted(date: .abbreviated, time: .omitted) }]
                .compactMap { $0 }.joined(separator: " · ")
            lock.lock()
            items[index].parts = plan.roots
            items[index].bytes = bytes
            items[index].detail = detail.isEmpty ? nil : detail
            items[index].note = plan.roots.isEmpty ? "Its files are already gone; only macOS's record of it is left."
                : "Still installed: " + plan.roots.prefix(3).map(\.lastPathComponent).joined(separator: ", ") + (plan.roots.count > 3 ? " and \(plan.roots.count - 3) more" : "")
            lock.unlock()
        }
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
        // Everything that needs an administrator goes in one request, so there is one password prompt.
        let packages = items.filter { $0.category == .receipts }
        let shared = items.filter { $0.forAllUsers && $0.category != .receipts }
        var forgotten = 0
        if !packages.isEmpty || !shared.isEmpty {
            let uid = getuid()
            let parts = packages.flatMap(\.parts)
            let stops = parts.filter { $0.pathExtension == "plist" && ($0.path.hasPrefix("/Library/LaunchDaemons/") || $0.path.hasPrefix("/Library/LaunchAgents/")) }
                .compactMap { plist -> String? in
                    guard let label = NSDictionary(contentsOf: plist)?["Label"] as? String else { return nil }
                    return "launchctl bootout \(plist.path.hasPrefix("/Library/LaunchDaemons/") ? "system" : "gui/\(uid)")/\(Privileged.quoted(label))"
                }
            var after = packages.map { "pkgutil --forget \(Privileged.quoted($0.name))" }
            // A removed audio driver only disappears once the audio system restarts; sound stops for a moment.
            if shared.contains(where: { $0.category == .audioDrivers }) || parts.contains(where: { $0.path.hasPrefix("/Library/Audio/Plug-Ins/HAL/") }) {
                after.append("killall coreaudiod")
            }
            let urls = parts + shared.compactMap(\.url)
            let count = packages.count + shared.count
            let names = (packages + shared).map(\.name)
            let prompt = "Spare wants to remove \(count == 1 ? names[0] : "\(count) items") installed for every account."
            if urls.isEmpty {
                // Only installer records are left: nothing to move.
                if let problem = Privileged.run(after.joined(separator: "; ") + "; true", prompt: prompt) {
                    if problem != "Cancelled." { Shared.shared.banner = .init(title: "Couldn't remove it", detail: problem, failed: true) }
                } else {
                    forgotten = packages.count
                }
            } else if let records = AdminTrash.move(urls, before: stops, after: after, prompt: prompt) {
                forgotten = packages.count
                if !records.isEmpty {
                    HistoryModel.shared.add(TrashSession(title: count == 1 ? "Removed \(names[0])" : "Removed \(count) items",
                                                         records: records, bytes: (packages + shared).compactMap(\.bytes).reduce(0, +)))
                    moved += records.count
                }
            }
        }
        load()
        Shared.shared.refreshSpace()
        guard moved > 0 || forgotten > 0 || !problems.isEmpty else { return }
        let restart = items.contains { $0.category == .kernel }
        Shared.shared.banner = .init(title: moved == 0 && forgotten > 0 ? "Removed \(forgotten == 1 ? packages[0].name : "\(forgotten) installer packages")"
                                     : moved == 1 ? "Moved 1 item to the Trash" : "Moved \(moved) items to the Trash",
                                     detail: restart ? "Kernel extensions unload after a restart."
                                        : moved == 0 ? "macOS no longer lists \(forgotten == 1 ? "it" : "them") as installed." : "History can put them back.",
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
                            if let note = row.item.note {
                                Text(note).font(.system(size: 10.5)).lineLimit(1).truncationMode(.tail)
                                    .foregroundStyle(row.item.category == .system && row.item.owner == nil && row.item.state != "Removed at restart" ? Color.orange : Color.secondary)
                            } else if let detail = row.item.detail {
                                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .help([row.item.note, row.item.detail, row.item.url?.path].compactMap { $0 }.joined(separator: "\n"))
                }
                .width(min: 220, ideal: 320)
                TableColumn("Kind", value: \.category).width(min: 110, ideal: 160)
                TableColumn("From", value: \.from) { row in
                    Text(row.item.owner.map { "Inside \($0)" } ?? (row.item.category == .system ? "App removed" : row.from))
                        .foregroundStyle(row.item.category == .system && row.item.owner == nil ? .secondary : .primary)
                }
                .width(min: 70, ideal: 120)
                TableColumn("State", value: \.state) { row in
                    Text(row.item.state ?? "").foregroundStyle(row.item.state == "On" ? .primary : .secondary).lineLimit(1)
                }
                .width(min: 60, ideal: 120)
                TableColumn("Where", value: \.place).width(min: 80, ideal: 100)
                TableColumn("Size", value: \.size) { row in SizeText(bytes: row.item.bytes) }.width(min: 60, ideal: 80)
            }
            .contextMenu(forSelectionType: ExtensionRow.ID.self) { ids in
                let rows = model.rows.filter { ids.contains($0.id) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(rows.compactMap(\.item.url)) }
                    .disabled(rows.allSatisfy { $0.item.url == nil })
                if let owner = rows.first(where: { $0.item.ownerURL != nil })?.item, let url = owner.ownerURL {
                    Button("Uninstall \(owner.owner ?? "the App")…") { ExtensionsView.uninstall(app: url) }
                }
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
        .alert(chosen.filter(\.item.removable).count == 1 ? "Remove \(chosen.first { $0.item.removable }?.name ?? "it")?"
                                                          : "Remove \(chosen.filter(\.item.removable).count) items?", isPresented: $confirming) {
            Button("Remove", role: .destructive) { let rows = chosen; Task { await model.remove(rows) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .onAppear { model.startIfNeeded() }
    }

    /// Opens the app in Apps, where uninstalling shows everything that goes with it.
    static func uninstall(app url: URL) {
        Navigation.shared.page = .apps
        UserDefaults.standard.set(AppsView.Mode.installed.rawValue, forKey: "appsMode")
        AppsModel.shared.startIfNeeded()
        AppsModel.shared.selection = url.path
    }

    private var confirmMessage: String {
        let items = chosen.map(\.item).filter(\.removable)
        var parts: [String] = []
        let packages = items.filter { $0.category == .receipts }
        if !packages.isEmpty {
            let leftover = packages.flatMap(\.parts)
            parts.append(leftover.isEmpty ? "macOS forgets \(packages.count == 1 ? "this installer's record" : "these installers' records"); no files are left to move."
                         : "Moves what they installed to the Trash (\(leftover.prefix(4).map(\.lastPathComponent).joined(separator: ", "))\(leftover.count > 4 ? ", …" : "")), stops their background jobs, and has macOS forget them.")
        }
        if items.contains(where: \.forAllUsers) { parts.append("Some are installed for every account, so macOS asks for an administrator password once.") }
        if items.contains(where: { $0.category == .audioDrivers || $0.parts.contains { $0.path.hasPrefix("/Library/Audio/Plug-Ins/HAL/") } }) {
            parts.append("The audio system restarts, so sound stops for a moment, including in calls.")
        }
        if items.contains(where: { $0.category == .kernel }) { parts.append("Kernel extensions unload after a restart.") }
        let skipped = chosen.count - items.count
        if skipped > 0 { parts.append("\(skipped == 1 ? "1 item stays" : "\(skipped) items stay"): macOS's own, or removed with its app or installer.") }
        parts.append("History can put everything back until you empty the Trash.")
        return parts.joined(separator: " ")
    }

    private var actionBar: some View {
        let removable = chosen.filter(\.item.removable)
        return HStack(spacing: 10) {
            Text(chosen.isEmpty ? "\(visible.count) items" : "\(chosen.count) selected" + (removable.count < chosen.count ? " · \(chosen.count - removable.count) \(chosen.contains { $0.item.category == .system } ? "removed only with their app" : "part of macOS")" : ""))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if model.working { ProgressView().controlSize(.small) }
            if removable.isEmpty, let owner = chosen.first(where: { $0.item.ownerURL != nil })?.item, let url = owner.ownerURL {
                Button("Uninstall \(owner.owner ?? "the App")…") { ExtensionsView.uninstall(app: url) }
            } else {
                Button(chosen.contains { $0.item.category == .receipts } ? "Remove…" : "Move to Trash…", role: .destructive) { confirming = true }
                    .disabled(removable.isEmpty || model.working)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}
