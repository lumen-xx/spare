import SwiftUI
import SpareCore

@MainActor
final class HomeModel: ObservableObject {
    static let shared = HomeModel()
    @Published private(set) var items: [HomeItem] = []
    @Published private(set) var loading = false
    @Published private(set) var working = false
    private var started = false

    func startIfNeeded() { if !started { load() } }

    func load() {
        #if DEBUG
        if Demo.isOn { return }
        #endif
        started = true
        loading = true
        Task {
            var found = await background {
                HomeItems.hidden(home: home, appInstalled: { AppLookup.url(for: $0) != nil }, toolFound: { Shell.which($0) != nil },
                                 appNamed: HomeModel.appNamed())
                    + HomeItems.shared()
            }
            self.items = found
            // Sizes last: the list is useful before every folder is measured.
            let urls = found.map(\.url)
            let sizes = await background { Catalog.measure(urls, cancel: Cancellation()) }
            for index in found.indices { found[index].bytes = sizes[index].bytes + sizes[index].shared }
            self.items = found
            self.loading = false
        }
    }

    /// Whether an installed app's name contains a word, checked off the main thread.
    nonisolated static func appNamed() -> (String) -> Bool {
        let names = Apps.installed(home: home).map { $0.name.lowercased() }
        return { owner in names.contains { $0.contains(owner.lowercased()) } }
    }

    /// Moves items to the Trash: your own directly, others' (in the shared folder) after one password prompt.
    func remove(_ chosen: [HomeItem]) async {
        let items = chosen.filter { $0.origin.removable }
        guard !items.isEmpty, !working else { return }
        working = true
        defer { working = false }
        let me = NSUserName()
        func mine(_ item: HomeItem) -> Bool { ((try? FileManager.default.attributesOfItem(atPath: item.url.path))?[.ownerAccountName] as? String) == me }
        let yours = items.filter(mine)
        let others = items.filter { !mine($0) }
        var outcome = Trasher.Outcome(session: nil, failures: [])
        if !yours.isEmpty {
            outcome = await Trasher.move(yours.map { ($0.url, $0.bytes) }, title: yours.count == 1 ? "Removed \(yours[0].name)" : "Removed \(yours.count) items from your home folder")
        }
        var moved = outcome.session?.records.count ?? 0
        if !others.isEmpty, let records = AdminTrash.move(others.map(\.url), prompt: "Spare wants to remove items other accounts own in the shared folder."),
           !records.isEmpty {
            HistoryModel.shared.add(TrashSession(title: "Removed \(records.count) shared items", records: records, bytes: others.compactMap(\.bytes).reduce(0, +)))
            moved += records.count
        }
        load()
        Shared.shared.refreshSpace()
        guard moved > 0 || !outcome.failures.isEmpty else { return }
        Shared.shared.banner = .init(title: moved == 1 ? "Moved 1 item to the Trash" : "Moved \(moved) items to the Trash",
                                     detail: "History can put them back until you empty the Trash.",
                                     session: HistoryModel.shared.sessions.first?.id,
                                     problems: outcome.failures.map { "\($0.url.lastPathComponent): \($0.reason)" }, failed: moved == 0)
    }
}

struct HomeView: View {
    let place: HomeItem.Place
    @ObservedObject var model = HomeModel.shared
    @State private var selection = Set<HomeItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\HomeItem.sortSize, order: .reverse)]
    @State private var onlyGone = false
    @State private var confirming = false

    private var mine: [HomeItem] { model.items.filter { $0.place == place } }
    private var visible: [HomeItem] { mine.filter { !onlyGone || $0.ownerGone }.sorted(using: sortOrder) }
    private var chosen: [HomeItem] { mine.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(place == .home
                     ? "Files and folders in your home folder that Finder hides: settings, caches and data of tools and apps. Ones whose tool or app is gone are marked."
                     : "/Users/Shared, which every account can use. Installers often leave licensing and support files here.")
                    .font(.spare(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if place == .home && mine.contains(where: \.ownerGone) {
                    Toggle("Only what's left behind", isOn: $onlyGone).toggleStyle(SketchCheckStyle()).fixedSize()
                }
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 12)
            .arrives(0)
            TableCard(seed: "home-\(place.rawValue)") { table }.arrives(1)
            ActionBar {
                Text(chosen.isEmpty ? countText(visible.count, "item") : "\(chosen.count) selected · \(Bytes.text(chosen.compactMap(\.bytes).reduce(0, +)))")
                    .font(.spare(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if model.working { ThinkingDots() }
                Button("Move to Trash…", role: .destructive) { confirming = true }
                    .spareButton(.secondary)
                    .disabled(!chosen.contains { $0.origin.removable } || model.working)
            }
            .arrives(2)
        }
        .arrivalStage(replay: model.items.isEmpty)
        .toolbar {
            ToolbarItem {
                Button { model.load() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading).help("Look Again")
            }
        }
        .alert(chosen.count == 1 ? "Move \(chosen[0].name) to the Trash?" : "Move \(chosen.count) items to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { let items = chosen; Task { await model.remove(items) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .onAppear { model.startIfNeeded() }
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 8) {
                    Image(nsImage: AppLookup.icon(for: item.url, size: 18)).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Text(item.name).lineLimit(1)
                            OriginBadge(origin: item.origin)
                            if item.sensitive {
                                Tag(text: "Keys", tint: Ink.warm, symbol: "key.fill")
                                    .help("Holds keys, tokens or passwords. Without them you may be locked out of servers or services.")
                            }
                        }
                        if item.ownerGone {
                            Text("\(item.owner ?? "Its app") is no longer on this Mac").font(.spare(size: 10.5)).foregroundStyle(Ink.warm).lineLimit(1)
                        }
                    }
                }
                .help(item.url.path)
            }
            .width(min: 220, ideal: 300)
            TableColumn("Belongs To", value: \.ownerText) { item in Text(item.owner ?? "—").foregroundStyle(.secondary) }.width(min: 90, ideal: 150)
            TableColumn("Kind", value: \.kind).width(min: 70, ideal: 90)
            TableColumn("Changed", value: \.sortDate) { item in
                Text(item.modified?.ago ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Size", value: \.sortSize) { item in SizeText(bytes: item.bytes) }.width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: HomeItem.ID.self) { ids in
            let items = mine.filter { ids.contains($0.id) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
            Divider()
            Button("Move to Trash…", role: .destructive) { selection = Set(ids); confirming = true }
                .disabled(!items.contains { $0.origin.removable })
        } primaryAction: { ids in
            NSWorkspace.shared.activateFileViewerSelecting(mine.filter { ids.contains($0.id) }.map(\.url))
        }
        .overlay {
            if model.loading && model.items.isEmpty {
                VStack(spacing: 8) { ThinkingDots(); Text("Looking").font(.spare(size: 12)).foregroundStyle(.secondary) }
            } else if !model.loading && mine.isEmpty {
                EmptyState(doodle: .sprout, title: "Nothing here", text: "Nothing hidden to show.")
            }
        }
    }

    private var confirmMessage: String {
        var parts: [String] = []
        let keys = chosen.filter(\.sensitive)
        if !keys.isEmpty { parts.append("\(keys.map(\.name).joined(separator: ", ")) \(keys.count == 1 ? "holds" : "hold") keys or passwords. Keep a copy if you still use them.") }
        let settings = chosen.filter { $0.kind == "Settings" && !$0.sensitive }
        if !settings.isEmpty { parts.append("Settings files such as \(settings.prefix(3).map(\.name).joined(separator: ", ")) are how your tools are set up.") }
        parts.append("History can put everything back until you empty the Trash.")
        return parts.joined(separator: " ")
    }
}

extension HomeItem {
    var ownerText: String { owner ?? "" }
    var sortSize: Int64 { bytes ?? -1 }
    var sortDate: Date { modified ?? .distantPast }
}
