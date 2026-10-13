import SwiftUI
import SpareCore

@MainActor
final class SystemDataModel: ObservableObject {
    static let shared = SystemDataModel()
    @Published private(set) var snapshots: [LocalSnapshot] = []
    @Published private(set) var assets: [SystemAsset] = []
    @Published private(set) var backupDisk: String?
    @Published private(set) var loading = false
    @Published var selected: Set<String> = []
    private var started = false

    func startIfNeeded() { if !started { load() } }

    func load() {
        started = true
        loading = true
        Task {
            let (snapshots, destination) = await background { () -> ([LocalSnapshot], String?) in
                let list = Snapshots.parse(Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30).output)
                let info = Shell.run("/usr/bin/tmutil", ["destinationinfo"], timeout: 30).output
                let name = info.split(separator: "\n").first { $0.hasPrefix("Name") }?.split(separator: ":", maxSplits: 1).last
                return (list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }, name.map { $0.trimmingCharacters(in: .whitespaces) })
            }
            self.snapshots = snapshots
            self.backupDisk = destination
            self.selected = self.selected.intersection(snapshots.map(\.id))
            self.assets = await background { SystemAssets.measure() }
            self.loading = false
        }
    }

    /// Deletes local snapshots with Time Machine's own command, after one password prompt.
    func delete(_ chosen: [LocalSnapshot]) {
        let stamps = chosen.compactMap(\.stamp)
        guard !stamps.isEmpty else { return }
        let command = stamps.map { "tmutil deletelocalsnapshots \($0)" }.joined(separator: "; ")
        if let problem = Privileged.run(command, prompt: "Spare wants to delete \(stamps.count == 1 ? "a Time Machine snapshot" : "\(stamps.count) Time Machine snapshots").") {
            if problem != "Cancelled." { Shared.shared.banner = .init(title: "Couldn't delete the snapshots", detail: problem) }
        } else {
            Shared.shared.banner = .init(title: stamps.count == 1 ? "Deleted 1 snapshot" : "Deleted \(stamps.count) snapshots",
                                         detail: "Your Time Machine backups on the backup disk aren't affected.")
        }
        selected = []
        load()
        Shared.shared.refreshSpace()
    }
}

struct SystemDataView: View {
    @ObservedObject var model = SystemDataModel.shared
    @ObservedObject var shared = Shared.shared
    @State private var confirming: [LocalSnapshot] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("What macOS keeps for itself: Time Machine's snapshots on this disk, and what it downloads for its own features. Spare shows where the space goes and how to get it back without harming macOS.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                snapshotsSection
                assetsSection
            }
            .padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 90)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.top)
        .toolbar {
            ToolbarItem {
                Button { model.load() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading).help("Look Again")
            }
        }
        .alert(confirming.count == 1 ? "Delete this snapshot?" : "Delete \(confirming.count) snapshots?",
               isPresented: Binding(get: { !confirming.isEmpty }, set: { if !$0 { confirming = [] } })) {
            Button("Delete", role: .destructive) { let chosen = confirming; model.delete(chosen) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They can't be restored. Backups on your Time Machine disk stay as they are. macOS asks for an administrator password.")
        }
        .onAppear { model.startIfNeeded() }
    }

    static let sizeNote = "macOS doesn't report how much each snapshot holds; neither tmutil nor APFS gives a size, which is why System Settings counts them under System Data. It reports one total for everything it can clear by itself: these snapshots, iCloud files that are also online, and caches it manages."

    private var snapshotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Time Machine Snapshots").font(.system(size: 15, weight: .semibold))
                    Text("Hourly copies of this disk Time Machine keeps while \(model.backupDisk.map { "“\($0)”" } ?? "the backup disk") isn't connected. macOS deletes them on its own when it needs room, so they count as space macOS can clear itself.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let space = shared.space, !model.snapshots.isEmpty {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Up to \(Bytes.text(space.purgeable))").font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        Text("with other purgeable data").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .help(Self.sizeNote)
                }
                if !model.snapshots.isEmpty {
                    Button("Delete Selected…") { confirming = model.snapshots.filter { model.selected.contains($0.id) } }
                        .disabled(model.selected.isEmpty)
                    Button("Delete All…") { confirming = model.snapshots }
                }
            }
            Panel {
                if model.snapshots.isEmpty {
                    Text(model.loading ? "Looking…" : "No local snapshots.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                    if index > 0 { Divider().padding(.leading, 40) }
                    HStack(spacing: 10) {
                        CheckBox(state: model.selected.contains(snapshot.id) ? .on : .off) {
                            if model.selected.contains(snapshot.id) { model.selected.remove(snapshot.id) } else { model.selected.insert(snapshot.id) }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snapshot.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? snapshot.name).font(.system(size: 12.5, weight: .medium))
                            Text((snapshot.date.map { $0.ago + " · " } ?? "") + (snapshot.dataless ? "Already emptied by macOS; only its record is left" : "Holds older versions of changed files"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // APFS reports no size per snapshot; an emptied one is known to hold nothing.
                        Text(snapshot.dataless ? Bytes.text(0) : "Size not reported")
                            .font(.system(size: 12, weight: snapshot.dataless ? .medium : .regular).monospacedDigit())
                            .foregroundStyle(snapshot.dataless ? .primary : .tertiary)
                            .help(snapshot.dataless ? "macOS already gave this snapshot's space back." : Self.sizeNote)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
    }

    private var assetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloaded by macOS").font(.system(size: 15, weight: .semibold))
                    Text("Models and data macOS fetched for its own features. System Integrity Protection guards them, so no app, not even with an administrator password, can delete them. Switching off the feature lets macOS remove them.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                SizeText(bytes: model.assets.reduce(0) { $0 + $1.bytes }, weight: .semibold)
            }
            Panel {
                if model.assets.isEmpty {
                    Text(model.loading ? "Measuring…" : "Nothing downloaded.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(Array(model.assets.enumerated()), id: \.element.id) { index, asset in
                    if index > 0 { Divider().padding(.leading, 56) }
                    HStack(alignment: .center, spacing: 12) {
                        SymbolTile(symbol: asset.feature.symbol, tint: asset.feature == .appleIntelligence ? .purple : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(asset.feature.rawValue).font(.system(size: 13, weight: .semibold))
                                OriginBadge(origin: .macOS)
                            }
                            Text(asset.feature.remedy).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 10)
                        SizeText(bytes: asset.bytes, weight: .semibold)
                        if let url = asset.feature.settings {
                            Button("Open Settings") { NSWorkspace.shared.open(url) }.controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .help(asset.folders.map(\.lastPathComponent).joined(separator: "\n"))
                }
            }
        }
    }
}
