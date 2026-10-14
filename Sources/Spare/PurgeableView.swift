import SwiftUI
import SpareCore

/// Space macOS gives back by itself when it runs low: what each part of macOS is holding, the parts Spare can free
/// at once, and Time Machine's local snapshots.
@MainActor
final class PurgeableModel: ObservableObject {
    static let shared = PurgeableModel()
    /// Bytes per part of macOS. nil before the first answer, or when macOS didn't give one.
    @Published private(set) var services: [String: Int64]?
    @Published private(set) var measuring = false
    @Published private(set) var unanswered = false
    @Published private(set) var freeing: CacheDelete.Service?
    @Published private(set) var snapshots: [LocalSnapshot] = []
    @Published private(set) var snapshotProblem: String?
    @Published private(set) var backupDisk: String?
    @Published private(set) var listing = false
    @Published var selected: Set<String> = []
    private var started = false

    func startIfNeeded() { if !started { load() } }
    func reloadIfStarted() { if started { load() } }

    /// What Spare can free now: the parts it offers, as measured at the urgency each is freed at.
    var freeable: Int64 { CacheDelete.Service.allCases.filter(\.spareFrees).reduce(0) { $0 + bytes($1) } }
    var total: Int64? { services.map { $0.values.reduce(0, +) } }
    func bytes(_ service: CacheDelete.Service) -> Int64 { services?[service.rawValue] ?? 0 }
    /// Parts of macOS Spare doesn't know by name.
    var other: Int64 {
        let known = Set(CacheDelete.Service.allCases.map(\.rawValue))
        return services?.filter { !known.contains($0.key) }.values.reduce(0, +) ?? 0
    }

    func load() {
        #if DEBUG
        if Demo.isOn { return }
        #endif
        started = true
        measuring = true
        listing = true
        Task {
            let measured = await background { () -> [String: Int64]? in
                // macOS gives up more the more urgently it's asked, so each part is read at the urgency Spare frees it at.
                guard var answer = PurgeTool.purgeable(urgency: 3) else { return nil }
                if let gentle = PurgeTool.purgeable(urgency: CacheDelete.Service.macOSDownloads.urgency) {
                    answer[CacheDelete.Service.macOSDownloads.rawValue] = gentle[CacheDelete.Service.macOSDownloads.rawValue] ?? 0
                }
                return answer
            }
            self.services = measured
            self.unanswered = measured == nil
            self.measuring = false
        }
        Task {
            let (list, problem, disk) = await background { () -> ([LocalSnapshot], String?, String?) in
                let result = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30)
                let info = Shell.run("/usr/bin/tmutil", ["destinationinfo"], timeout: 30).output
                let name = info.split(separator: "\n").first { $0.hasPrefix("Name") }?.split(separator: ":", maxSplits: 1).last
                let problem = result.succeeded ? nil : result.output.split(separator: "\n").first.map(String.init) ?? "tmutil stopped with code \(result.status)."
                return (Snapshots.parse(result.output).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) },
                        problem, name.map { $0.trimmingCharacters(in: .whitespaces) })
            }
            self.snapshots = list
            self.snapshotProblem = problem
            self.backupDisk = disk
            self.selected = self.selected.intersection(list.map(\.id))
            self.listing = false
        }
    }

    /// Asks macOS to free what Spare offers, one part after another, then says how much came back.
    func free(_ chosen: [CacheDelete.Service]) {
        guard freeing == nil else { return }
        #if DEBUG
        if Demo.isOn { Demo.pretend("Spare would have asked macOS to free this space."); return }
        #endif
        Task {
            var freed: Int64 = 0
            var problems: [String] = []
            for service in chosen where bytes(service) > 0 {
                freeing = service
                let result = await background { PurgeTool.purge(service) }
                freed += result.freed
                if let error = result.error { problems.append("\(service.title): \(error)") }
            }
            freeing = nil
            if problems.isEmpty || freed > 0 {
                Shared.shared.banner = .init(title: freed > 0 ? "Freed \(Bytes.text(freed))" : "Nothing more to free right now",
                                             detail: freed > 0 ? "macOS removed what apps had said it could delete. Apps fetch anything they need again."
                                                               : "macOS kept what it holds, as it may when the disk has room.",
                                             problems: problems)
            } else {
                Shared.shared.banner = .init(title: "macOS didn't free the space", detail: problems.first,
                                             problems: problems.count > 1 ? problems : [], failed: true,
                                             next: .init(title: "Try Again") { PurgeableModel.shared.free(chosen) })
            }
            Shared.shared.refreshSpace()
            load()
        }
    }

    /// Deletes local snapshots with Time Machine's own command, after one password prompt.
    func delete(_ chosen: [LocalSnapshot]) {
        #if DEBUG
        if Demo.isOn { Demo.pretend("Spare would have deleted the snapshots."); return }
        #endif
        let stamps = chosen.compactMap(\.stamp)
        guard !stamps.isEmpty else { return }
        let command = stamps.map { "tmutil deletelocalsnapshots \($0)" }.joined(separator: "; ")
        if let problem = Privileged.run(command, prompt: "Spare wants to delete \(stamps.count == 1 ? "a Time Machine snapshot" : "\(stamps.count) Time Machine snapshots").") {
            if problem != "Cancelled." {
                Shared.shared.banner = .init(title: "The snapshots weren't deleted", detail: problem, failed: true,
                                             next: .init(title: "Try Again") { PurgeableModel.shared.delete(chosen) })
            }
        } else {
            Shared.shared.banner = .init(title: stamps.count == 1 ? "Deleted 1 snapshot" : "Deleted \(stamps.count) snapshots",
                                         detail: "Your backups on the Time Machine disk aren't affected.")
        }
        selected = []
        load()
        Shared.shared.refreshSpace()
    }

    #if DEBUG
    func showDemo(services: [String: Int64], snapshots: [LocalSnapshot], backupDisk: String) {
        started = true
        self.services = services
        self.snapshots = snapshots
        self.backupDisk = backupDisk
    }
    #endif
}

struct PurgeableView: View {
    @ObservedObject var model = PurgeableModel.shared
    @ObservedObject var shared = Shared.shared
    @State private var confirmingFree = false
    @State private var confirmingDelete: [LocalSnapshot] = []
    @Environment(\.reduceMotion) private var reduceMotion

    /// The parts listed, in a sensible order: what Spare frees first, then what macOS keeps for itself.
    private let order: [CacheDelete.Service] = [.purgeableFiles, .macOSDownloads, .timeMachine, .cloudCopies, .containerCaches, .spotlight, .thumbnails]

    var body: some View {
        PageScroll {
            header.arrives(0)
            parts.arrives(1)
            snapshotsSection.arrives(2)
            Text("System Settings counts all of this as System Data. macOS frees it by itself when an app or an update needs the room, so it's never wasted, only borrowed.")
                .font(.spare(size: 11.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .arrives(3)
        }
        .toolbar {
            ToolbarItem {
                Button { Refresh.everything() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.measuring || model.freeing != nil).help("Look Again")
            }
        }
        .alert("Free \(Bytes.text(model.freeable)) now?", isPresented: $confirmingFree) {
            Button("Free") { model.free(CacheDelete.Service.allCases.filter(\.spareFrees)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS removes copies apps said it may delete, such as streamed media and caches, and downloads nothing uses any more. Apps fetch anything they need again.")
        }
        .alert(confirmingDelete.count == 1 ? "Delete this snapshot?" : "Delete \(confirmingDelete.count) snapshots?",
               isPresented: Binding(get: { !confirmingDelete.isEmpty }, set: { if !$0 { confirmingDelete = [] } })) {
            Button("Delete", role: .destructive) { let chosen = confirmingDelete; model.delete(chosen) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They can't be restored. Backups on your Time Machine disk stay as they are. macOS asks for an administrator password.")
        }
        .onAppear { model.startIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(model.freeing != nil ? "Freeing" : model.measuring ? "Asking macOS" : "macOS can clear by itself")
                        .contentTransition(.opacity)
                    if model.measuring || model.freeing != nil { ThinkingDots().transition(.opacity) }
                }
                .font(.spare(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .animation(Motion.gentle(Motion.settle, reduceMotion: reduceMotion), value: model.measuring)
                Text(Bytes.text(model.total ?? shared.space?.purgeable ?? 0))
                    .font(.spare(size: 46, weight: .bold))
                    .contentTransition(.numericText())
                    .animation(Motion.count.delay(Beat.settle), value: model.total)
                Text(model.freeable > 0 ? "\(Bytes.text(model.freeable)) of it can be freed now" : "macOS keeps the rest until it needs the room")
                    .font(.spare(size: 12)).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button { confirmingFree = true } label: {
                Label("Free Now…", systemImage: "wind").padding(.horizontal, 2)
            }
            .spareButton(.primary)
            .controlSize(.large)
            .disabled(model.freeable == 0 || model.freeing != nil)
        }
    }

    @ViewBuilder private var parts: some View {
        if model.unanswered {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "What macOS Is Holding")
                ProblemNote(title: "macOS didn't say what it can clear",
                            text: "Its clean-up service didn't answer, so the parts can't be listed. The snapshots below come from Time Machine and still work.",
                            actionTitle: "Try Again") { model.load() }
            }
        } else {
            VStack(alignment: .leading, spacing: 26) {
                group("Spare Can Free Now", subtitle: "Apps and macOS have said these may go",
                      services: order.filter(\.spareFrees), other: false)
                group("macOS Clears These Itself", subtitle: "When an app or an update needs the room",
                      services: order.filter { !$0.spareFrees && model.bytes($0) > 0 }, other: model.other > 0)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, subtitle: String, services: [CacheDelete.Service], other: Bool) -> some View {
        if !services.isEmpty || other || model.services == nil {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: title, subtitle: subtitle)
                Card {
                    ForEach(Array(services.enumerated()), id: \.element) { index, service in
                        if index > 0 { RowDivider().padding(.leading, 56).padding(.trailing, 14) }
                        row(service)
                    }
                    if other {
                        if !services.isEmpty { RowDivider().padding(.leading, 56).padding(.trailing, 14) }
                        PartRow(symbol: "ellipsis", title: "Other parts of macOS", about: "Smaller caches macOS keeps for itself.",
                                bytes: model.other, active: false, measuring: false) { EmptyView() }
                    }
                    if model.services == nil && services.isEmpty {
                        HStack(spacing: 8) { ThinkingDots(); Text("Asking macOS").font(.spare(size: 12.5)).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ service: CacheDelete.Service) -> some View {
        PartRow(symbol: symbol(service), title: service.title, about: service.about,
                bytes: model.services == nil ? nil : model.bytes(service), active: service.spareFrees,
                measuring: model.measuring && model.services == nil) {
            if model.freeing == service {
                ThinkingDots()
            } else if service.spareFrees {
                Button("Free") { model.free([service]) }
                    .spareButton(.secondary).controlSize(.small)
                    .disabled(model.bytes(service) == 0 || model.freeing != nil)
            } else if service == .cloudCopies {
                Button("Cloud Downloads") { Navigation.shared.page = .cloudDownloads }
                    .spareButton(.quiet).controlSize(.small)
                    .help("See which cloud files are downloaded, and remove downloads yourself")
            }
        }
    }

    private func symbol(_ service: CacheDelete.Service) -> String {
        switch service {
        case .timeMachine: "clock.arrow.circlepath"
        case .purgeableFiles: "doc.on.doc"
        case .cloudCopies: "icloud.and.arrow.down"
        case .containerCaches: "archivebox"
        case .macOSDownloads: "arrow.down.app"
        case .spotlight: "magnifyingglass"
        case .thumbnails: "photo.on.rectangle"
        }
    }

    private var snapshotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Time Machine Snapshots",
                           subtitle: "Hourly copies kept while \(model.backupDisk.map { "“\($0)”" } ?? "the backup disk") isn't connected") {
                if !model.snapshots.isEmpty {
                    HStack(spacing: 6) {
                        Button("Delete Selected…") { confirmingDelete = model.snapshots.filter { model.selected.contains($0.id) } }
                            .disabled(model.selected.isEmpty)
                        Button("Delete All…") { confirmingDelete = model.snapshots }
                    }
                    .spareButton(.secondary)
                    .controlSize(.small)
                }
            }
            if let problem = model.snapshotProblem {
                ProblemNote(title: "Time Machine didn't list its snapshots",
                            text: "It answered: “\(problem)” This usually passes; try again in a moment.",
                            actionTitle: "Try Again") { model.load() }
            } else {
                Card {
                    if model.snapshots.isEmpty {
                        HStack(spacing: 8) {
                            if model.listing { ThinkingDots() }
                            Text(model.listing ? "Looking" : "No local snapshots right now.").font(.spare(size: 12.5)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                    ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        if index > 0 { RowDivider().padding(.leading, 42).padding(.trailing, 12) }
                        SnapshotRow(snapshot: snapshot)
                    }
                }
            }
        }
    }
}

/// One part of macOS that holds space, with what it is and what can be done about it.
private struct PartRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let about: String
    let bytes: Int64?
    /// Something Spare can act on, so its symbol is in colour.
    let active: Bool
    let measuring: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SymbolTile(symbol: symbol, tint: active ? Ink.sea : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.spare(size: 13, weight: .semibold))
                Text(about).font(.spare(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if measuring { ThinkingDots() } else { SizeText(bytes: bytes, weight: .semibold) }
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

private struct SnapshotRow: View {
    let snapshot: LocalSnapshot
    @ObservedObject var model = PurgeableModel.shared

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(state: model.selected.contains(snapshot.id) ? .on : .off) { toggle() }
            .accessibilityLabel(snapshot.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? snapshot.name)
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? snapshot.name).font(.spare(size: 12.5, weight: .medium))
                Text((snapshot.date.map { $0.ago + " · " } ?? "") + (snapshot.dataless ? "Already emptied by macOS; only its record is left" : "Holds older versions of changed files"))
                    .font(.spare(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            // APFS reports no size per snapshot; an emptied one is known to hold nothing.
            Text(snapshot.dataless ? Bytes.text(0) : "Size not reported")
                .font(.spare(size: 12, weight: snapshot.dataless ? .medium : .regular).monospacedDigit())
                .foregroundStyle(snapshot.dataless ? .primary : .tertiary)
                .help(snapshot.dataless ? "macOS already gave this snapshot's space back."
                                        : "Neither Time Machine nor APFS reports a size per snapshot. Their total is part of Time Machine snapshots above.")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private func toggle() {
        if model.selected.contains(snapshot.id) { model.selected.remove(snapshot.id) } else { model.selected.insert(snapshot.id) }
    }
}
