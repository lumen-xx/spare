import SwiftUI
import SpareCore

/// What macOS downloaded for itself: models, voices and language data in /System/Library/AssetsV2, what an update left
/// behind, and Apple Intelligence's models. System Integrity Protection guards the downloads, so Spare frees what it can
/// by asking macOS: an update's leftovers go to the Trash, and macOS removes the downloads nothing needs any more.
@MainActor
final class MacDownloadsModel: ObservableObject {
    static let shared = MacDownloadsModel()
    @Published private(set) var assets: [SystemAsset] = []
    @Published private(set) var leftovers: UpdateLeftovers.Found?
    /// Downloads nothing needs any more, measured at the urgency Spare frees them at. nil when macOS didn't say.
    @Published private(set) var unused: Int64?
    @Published private(set) var status: AppleIntelligence.Status?
    /// Who keeps each kind of download, in plain words.
    @Published private(set) var holders: [SystemAsset.Feature: String] = [:]
    /// The Siri language that switches Apple Intelligence off; nil when Siri speaks only the Mac's language.
    @Published private(set) var offLanguage: String?
    /// The Siri language Switch On puts back.
    @Published private(set) var savedLanguage: String?
    @Published private(set) var loading = false
    @Published private(set) var freeing = false
    @Published private(set) var switching: Switch?
    /// What the switch is doing right now.
    @Published private(set) var step: String?
    /// The change waiting for the person's consent.
    @Published var asking: Switch?
    private var started = false
    /// Siri's language is mid-change, so quitting waits until it's settled.
    private var unsettled = false
    private var quitWhenSettled = false

    enum Switch: String, Identifiable {
        case off, on, release
        var id: String { rawValue }
    }

    func startIfNeeded() { if !started { load() } }
    func reloadIfStarted() { if started { load() } }

    var total: Int64 { assets.reduce(0) { $0 + $1.bytes } + (leftovers?.bytes ?? 0) }
    /// Some folders couldn't be measured, so the total is a lower bound.
    var partlyHidden: Bool { assets.contains { $0.hidden } }
    var freeable: Int64 { (leftovers?.isLeftover == true ? leftovers?.bytes ?? 0 : 0) + (unused ?? 0) }
    var intelligence: SystemAsset? { assets.first { $0.feature == .appleIntelligence } }

    func load() {
        #if DEBUG
        if Demo.isOn { return }
        #endif
        started = true
        loading = true
        Task {
            async let measured = background { SystemAssets.measure().sorted { $0.bytes > $1.bytes } }
            async let found = background { UpdateLeftovers.find() }
            async let gentle = background { PurgeTool.purgeable(urgency: CacheDelete.Service.macOSDownloads.urgency) }
            async let read = background { Reading.now() }
            let (assets, leftovers, purgeable, reading) = await (measured, found, gentle, read)
            self.assets = assets
            self.leftovers = leftovers
            self.unused = purgeable.map { $0[CacheDelete.Service.macOSDownloads.rawValue] ?? 0 }
            self.status = reading.status
            self.holders = reading.holders
            self.offLanguage = reading.offLanguage
            self.savedLanguage = reading.savedLanguage
            self.loading = false
        }
    }

    /// Moves an update's leftovers to the Trash after one password prompt, then asks macOS to remove the downloads
    /// nothing needs. The banner says what came back, with Put Back for the Trash part.
    func free() {
        guard !freeing, switching == nil else { return }
        #if DEBUG
        if Demo.isOn { pretendToFree(); return }
        #endif
        freeing = true
        Task {
            var session: TrashSession?
            var stayed = false
            if let leftovers, leftovers.isLeftover {
                guard let records = AdminTrash.move(leftovers.items, prompt: "Spare wants to move what a macOS update left behind to the Trash.") else {
                    // Cancelled, or the banner already says what went wrong.
                    freeing = false
                    return
                }
                if records.isEmpty {
                    stayed = true
                } else {
                    var bytes = leftovers.bytes
                    if records.count < leftovers.items.count {
                        // Only part of it moved: what's left is measured where it is.
                        let moved = Set(records.map(\.original))
                        let left = leftovers.items.filter { !moved.contains($0.path) }
                        bytes -= await background { Catalog.measure(left, cancel: Cancellation()).reduce(Int64(0)) { $0 + $1.bytes } }
                    }
                    let moved = TrashSession(title: "Leftover " + (leftovers.product ?? "macOS update"), records: records, bytes: max(0, bytes))
                    HistoryModel.shared.add(moved)
                    session = moved
                }
            }
            var purged: Int64 = 0
            var problem: String?
            if (unused ?? 0) > 0 {
                let result = await background { PurgeTool.purge(.macOSDownloads) }
                purged = result.freed
                problem = result.error
            }
            freeing = false
            announce(trashed: session, stayed: stayed, purged: purged, problem: problem)
            Shared.shared.refreshSpace()
            load()
        }
    }

    private func announce(trashed session: TrashSession?, stayed: Bool, purged: Int64, problem: String?) {
        let others = (stayed ? ["The update's leftovers didn't move. Something may still be using them; try again after a restart."] : [])
            + (problem.map { ["Unused downloads: \($0)"] } ?? [])
        if let session {
            Shared.shared.banner = .init(title: "Moved \(Bytes.text(session.bytes)) to the Trash",
                                         detail: "It's freed when you empty the Trash, and History can put it back until then."
                                            + (purged > 0 ? " macOS also removed \(Bytes.text(purged)) of downloads nothing needed." : ""),
                                         session: session.id, problems: others, offerEmptyTrash: true)
        } else if purged > 0 {
            Shared.shared.banner = .init(title: "macOS freed \(Bytes.text(purged))",
                                         detail: "It removed downloads no feature needed any more. A feature that wants one later downloads it again.",
                                         problems: others)
        } else if !others.isEmpty {
            Shared.shared.banner = .init(title: "Nothing was freed", detail: others.first, problems: Array(others.dropFirst()), failed: true,
                                         next: .init(title: "Try Again") { MacDownloadsModel.shared.free() })
        } else {
            Shared.shared.banner = .init(title: "Nothing more to free right now",
                                         detail: "macOS keeps a download while a feature still uses it, and decides that itself.")
        }
    }

    /// Switches Apple Intelligence off or on through Siri's language, or gets macOS to let go of models it still holds.
    /// Call only after the person agreed to the change.
    func run(_ change: Switch) {
        guard switching == nil, !freeing else { return }
        switching = change
        step = "Getting ready"
        unsettled = true
        #if DEBUG
        if Demo.isOn { pretendToSwitch(change); return }
        #endif
        let show: @Sendable (String) -> Void = { text in
            DispatchQueue.main.async { MainActor.assumeIsolated { MacDownloadsModel.shared.show(step: text) } }
        }
        let purge: @Sendable () -> CacheDelete.PurgeResult = {
            // Siri's language is final once macOS is asked to delete the models, so a quit no longer has to wait.
            DispatchQueue.main.async { MainActor.assumeIsolated { MacDownloadsModel.shared.settle() } }
            return PurgeTool.purge(.macOSDownloads)
        }
        Task {
            let outcome = await background { () -> AppleIntelligenceSwitch.Outcome in
                let environment = LiveSiriEnvironment()
                switch change {
                case .off: return AppleIntelligenceSwitch.turnOff(environment, purge: purge, step: show)
                case .on: return AppleIntelligenceSwitch.turnOn(environment)
                case .release: return AppleIntelligenceSwitch.release(environment, purge: purge, step: show)
                }
            }
            finish(change, outcome)
        }
    }

    private func show(step text: String) {
        guard switching != nil else { return }
        // The dots beside it say it's still going.
        step = text.hasSuffix("…") ? String(text.dropLast()) : text
    }

    private func finish(_ change: Switch, _ outcome: AppleIntelligenceSwitch.Outcome) {
        switching = nil
        step = nil
        settle()
        let freed = outcome.purge?.freed ?? 0
        if outcome.done {
            switch change {
            case .off:
                Shared.shared.banner = .init(title: "Apple Intelligence is off",
                                             detail: (outcome.siriLanguage.map { "Siri now speaks \(AppleIntelligence.languageName($0)). " } ?? "")
                                                + (freed > 0 ? "macOS removed \(Bytes.text(freed)) of its models." : "macOS removes its models over the next few minutes."))
            case .on:
                Shared.shared.banner = .init(title: "Apple Intelligence is on again",
                                             detail: "Siri speaks \(outcome.siriLanguage.map(AppleIntelligence.languageName) ?? "your Mac's language") again. macOS may download the models again.")
            case .release:
                Shared.shared.banner = .init(title: freed > 0 ? "macOS removed the models" : "macOS let go of the models",
                                             detail: (freed > 0 ? "\(Bytes.text(freed)) is free again. " : "It removes them over the next few minutes. ")
                                                + "Siri speaks as it did before.")
            }
        } else {
            // Trying again asks again: the change reaches the person's other devices too.
            Shared.shared.banner = .init(title: change == .on ? "Apple Intelligence didn't switch on"
                                             : change == .off ? "Apple Intelligence didn't switch off" : "macOS kept the models",
                                         detail: outcome.error ?? "Nothing changed.", failed: true,
                                         next: .init(title: "Try Again") {
                                             Navigation.shared.page = .macOSDownloads
                                             MacDownloadsModel.shared.asking = change
                                         })
        }
        Shared.shared.refreshSpace()
        load()
    }

    /// Siri's language is final; a quit that was waiting goes ahead.
    private func settle() {
        unsettled = false
        if quitWhenSettled {
            quitWhenSettled = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// For quitting: true while Siri's language is mid-change. The app then quits as soon as it's settled.
    func holdQuit() -> Bool {
        guard unsettled else { return false }
        quitWhenSettled = true
        return true
    }

    #if DEBUG
    func showDemo(assets: [SystemAsset], leftovers: UpdateLeftovers.Found?, unused: Int64, status: AppleIntelligence.Status,
                  holders: [SystemAsset.Feature: String], offLanguage: String?, savedLanguage: String?) {
        started = true
        self.assets = assets.sorted { $0.bytes > $1.bytes }
        self.leftovers = leftovers
        self.unused = unused
        self.status = status
        self.holders = holders
        self.offLanguage = offLanguage
        self.savedLanguage = savedLanguage
    }

    /// Nothing on the Mac changes in demo mode: these only show what would follow.
    private func pretendToFree() {
        freeing = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            freeing = false
            var session: TrashSession?
            if let leftovers, leftovers.isLeftover {
                session = TrashSession(title: "Leftover " + (leftovers.product ?? "macOS update"), records: [], bytes: leftovers.bytes)
                HistoryModel.shared.add(session!)
            }
            announce(trashed: session, stayed: false, purged: unused ?? 0, problem: nil)
        }
    }

    private func pretendToSwitch(_ change: Switch) {
        let steps = switch change {
        case .off: ["Saving your Siri settings", "Switching Siri to German (Germany)", "Checking that macOS switched Apple Intelligence off",
                    "Waiting for macOS to let go of the models", "Asking macOS to delete them"]
        case .on: ["Putting Siri back"]
        case .release: ["Switching Siri to English (US) for a moment", "Waiting for macOS to make Apple Intelligence available",
                        "Waiting for macOS to take the models", "Switching Siri back to German (Germany)", "Asking macOS to delete them"]
        }
        Task {
            for text in steps {
                show(step: text)
                try? await Task.sleep(for: .seconds(3))
            }
            let freed = change == .on ? nil : CacheDelete.PurgeResult(service: CacheDelete.Service.macOSDownloads.rawValue, reported: intelligence?.bytes ?? 0)
            finish(change, AppleIntelligenceSwitch.Outcome(done: true, siriLanguage: change == .on ? "en-US" : "de-DE", purge: freed))
        }
    }
    #endif
}

/// Siri, Apple Intelligence and who keeps which download, read together off the main thread.
private struct Reading: Sendable {
    var status: AppleIntelligence.Status
    var holders: [SystemAsset.Feature: String]
    var offLanguage: String?
    var savedLanguage: String?

    static func now() -> Reading {
        let status = AppleIntelligence.status()
        let environment = LiveSiriEnvironment()
        let subscriptions = AssetSubscriptions.live()
        var holders: [SystemAsset.Feature: String] = [:]
        if let subscriptions {
            for feature in SystemAsset.Feature.allCases {
                holders[feature] = AssetSubscriptions.holder(of: feature, in: subscriptions, siriLanguage: status.siriLanguage,
                                                             systemLanguage: status.systemLanguage)
            }
        }
        let off = status.systemLanguage.flatMap { system in
            AppleIntelligence.offLanguage(system: system, current: status.siriLanguage,
                                          installed: subscriptions.map(AssetSubscriptions.siriLanguages) ?? [],
                                          supported: environment.supportedLanguages())
        }
        return Reading(status: status, holders: holders, offLanguage: off, savedLanguage: environment.loadSaved()?.siriLanguage)
    }
}

struct MacDownloadsView: View {
    @ObservedObject var model = MacDownloadsModel.shared
    @State private var confirmingFree = false
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        PageScroll {
            header.arrives(0)
            canGo.arrives(1)
            if showsIntelligence { intelligence.arrives(2) }
            kept.arrives(3)
            Text("System Integrity Protection guards what macOS downloads, so no app can delete it, not even with an administrator password. macOS removes a download by itself once nothing holds on to it, and Spare shows what does.")
                .font(.spare(size: 11.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .arrives(4)
        }
        .toolbar {
            ToolbarItem {
                Button { model.load() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || model.freeing || model.switching != nil).help("Look Again")
            }
        }
        .alert("Free \(Bytes.text(model.freeable))?", isPresented: $confirmingFree) {
            Button("Free") { model.free() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(freeMessage)
        }
        .sheet(item: $model.asking) { change in
            IntelligenceConsent(change: change, model: model)
        }
        .onAppear {
            model.startIfNeeded()
            #if DEBUG
            // Screenshots of the consent sheet and of a switch on its way, with demo data only.
            if Demo.isOn, let change = UserDefaults.standard.string(forKey: "demoConsent").flatMap({ MacDownloadsModel.Switch(rawValue: $0) }) {
                model.asking = change
            }
            if Demo.isOn, let change = UserDefaults.standard.string(forKey: "demoRun").flatMap({ MacDownloadsModel.Switch(rawValue: $0) }) {
                model.run(change)
            }
            #endif
        }
    }

    private var freeMessage: String {
        var parts: [String] = []
        if let leftovers = model.leftovers, leftovers.isLeftover {
            parts.append("\(leftovers.product.map { "The leftover \($0)" } ?? "What a macOS update left behind") goes to the Trash after you enter an administrator password. History can put it back until you empty the Trash.")
        }
        if (model.unused ?? 0) > 0 {
            parts.append(parts.isEmpty ? "macOS removes downloads nothing needs any more. A feature that wants one later downloads it again."
                                       : "macOS also removes downloads nothing needs any more.")
        }
        return parts.joined(separator: " ")
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(model.freeing ? "Freeing" : model.loading ? "Measuring" : "Downloaded by macOS").contentTransition(.opacity)
                    if model.loading || model.freeing { ThinkingDots().transition(.opacity) }
                }
                .font(.spare(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .animation(Motion.gentle(Motion.settle, reduceMotion: reduceMotion), value: model.loading)
                Text((model.partlyHidden ? "At least " : "") + Bytes.text(model.total))
                    .font(.spare(size: 46, weight: .bold))
                    .contentTransition(.numericText())
                    .animation(Motion.count.delay(Beat.settle), value: model.total)
                Text(model.freeable > 0 ? "\(Bytes.text(model.freeable)) of it can go now" : "macOS keeps it for features you use")
                    .font(.spare(size: 12)).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button { confirmingFree = true } label: {
                Label("Free…", systemImage: "wind").padding(.horizontal, 2)
            }
            .spareButton(.primary)
            .controlSize(.large)
            .disabled(model.freeable == 0 || model.freeing || model.switching != nil)
        }
    }

    private var canGo: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Can Go Now", subtitle: "Nothing on this Mac needs these")
            Card(seed: 0xCA9) {
                if let leftovers = model.leftovers, leftovers.isLeftover {
                    DownloadRow(symbol: "shippingbox", tint: Ink.sea, title: leftovers.product ?? "What a macOS update left behind",
                                text: (leftovers.downloaded.map { "Downloaded \($0.formatted(date: .abbreviated, time: .omitted)). " } ?? "")
                                    + "It's older than the macOS you run, so nothing will install from it.",
                                bytes: leftovers.bytes) {
                        RevealButton(url: UpdateLeftovers.folder)
                    }
                    SketchDivider(seed: 0x1EF7).padding(.leading, 56).padding(.trailing, 14)
                }
                DownloadRow(symbol: "arrow.down.app", tint: (model.unused ?? 0) > 0 ? Ink.sea : .secondary,
                            title: "Downloads nothing uses any more", text: unusedText, bytes: model.unused,
                            measuring: model.loading && model.unused == nil) { EmptyView() }
            }
        }
    }

    private var unusedText: String {
        switch model.unused {
        case let bytes? where bytes > 0: "No feature needs these now. macOS removes them when asked, and fetches one again if a feature ever wants it."
        case .some: "None right now. macOS lets go of a download once no feature uses it."
        case nil: model.loading ? "Asking macOS." : "macOS didn't say: its clean-up service didn't answer."
        }
    }

    // MARK: Apple Intelligence

    /// A Mac that can't run it, with nothing downloaded for it, has nothing to show.
    private var showsIntelligence: Bool { !(model.status?.state == .unavailable && model.intelligence == nil) }

    private var intelligence: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Apple Intelligence", subtitle: "Its models stay on this Mac while it's on")
            Card(seed: 0xA1) {
                HStack(alignment: .center, spacing: 12) {
                    SymbolTile(symbol: "brain.head.profile", tint: model.status?.state == .on ? Ink.ink : model.status?.state == .releasing ? Ink.warm : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text("Apple Intelligence").font(.spare(size: 13, weight: .semibold))
                            if let tag = stateTag { tag }
                        }
                        Group {
                            if let step = model.step {
                                HStack(spacing: 7) {
                                    Text(step)
                                    ThinkingDots()
                                }
                            } else {
                                Text(intelligenceText)
                            }
                        }
                        .font(.spare(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .animation(Motion.gentle(Motion.settle, reduceMotion: reduceMotion), value: model.step)
                    }
                    Spacer(minLength: 12)
                    if let asset = model.intelligence { DownloadSize(bytes: asset.bytes, hidden: asset.hidden) }
                    intelligenceAction
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
    }

    private var stateTag: Tag? {
        switch model.status?.state {
        case .on: Tag(text: "On", tint: Ink.sage)
        case .off: Tag(text: "Off", tint: .secondary)
        case .releasing: Tag(text: "Off", tint: Ink.warm)
        case .unavailable: Tag(text: "Not available", tint: .secondary)
        case .unknown, nil: nil
        }
    }

    /// The tag already says on or off, so the explanation starts after it.
    private var intelligenceText: String {
        guard let status = model.status else { return "Looking at Siri's language and your Mac's." }
        var text = status.explanation
        for prefix in ["On: ", "Off: "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            text = text.prefix(1).uppercased() + text.dropFirst()
        }
        if let holder = model.holders[.appleIntelligence], status.state != .unavailable { text += " " + holder }
        return text
    }

    @ViewBuilder private var intelligenceAction: some View {
        if let status = model.status, model.switching == nil {
            switch status.state {
            case .on:
                Button("Switch Off…") { model.asking = .off }
                    .spareButton(.secondary).controlSize(.small)
                    .disabled(model.offLanguage == nil || model.freeing)
                    .help(model.offLanguage == nil ? "Siri speaks no language but your Mac's, so Spare can't switch Apple Intelligence off."
                                                   : "Switch Apple Intelligence off, so macOS removes its models")
            case .releasing:
                Button("Remove Models…") { model.asking = .release }
                    .spareButton(.secondary).controlSize(.small)
                    .disabled(model.freeing)
            case .off where status.savedBySpare:
                Button("Switch On…") { model.asking = .on }
                    .spareButton(.secondary).controlSize(.small)
                    .disabled(model.freeing)
            default:
                EmptyView()
            }
        }
    }

    // MARK: Kept

    private var kept: some View {
        let assets = model.assets.filter { $0.feature != .appleIntelligence }
        let waiting = model.leftovers.flatMap { $0.isLeftover ? nil : $0 }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Kept for macOS Features", subtitle: "What holds on to each, and what would let it go")
            Card(seed: 0x6E9) {
                if let waiting {
                    DownloadRow(symbol: "arrow.down.circle", tint: .secondary, title: waiting.product ?? "A macOS update",
                                text: (waiting.downloaded.map { "Downloaded \($0.formatted(date: .abbreviated, time: .omitted)) and waiting to be installed. " }
                                    ?? "Waiting to be installed. ") + "Installing it frees this space.",
                                bytes: waiting.bytes) {
                        if let url = SystemAsset.Feature.updates.settings {
                            Button("Software Update") { NSWorkspace.shared.open(url) }.spareButton(.secondary).controlSize(.small)
                        }
                    }
                    if !assets.isEmpty { SketchDivider(seed: 0x3A17).padding(.leading, 56).padding(.trailing, 14) }
                }
                if assets.isEmpty && waiting == nil {
                    HStack(spacing: 8) {
                        if model.loading { ThinkingDots() }
                        Text(model.loading ? "Measuring" : "Nothing downloaded.").font(.spare(size: 12.5)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                    if index > 0 { SketchDivider(seed: Jitter.seed(asset.id)).padding(.leading, 56).padding(.trailing, 14) }
                    DownloadRow(symbol: asset.feature.symbol, tint: .secondary, title: asset.feature.rawValue,
                                text: (model.holders[asset.feature] ?? asset.feature.about) + " " + asset.feature.remedy,
                                bytes: asset.bytes, hidden: asset.hidden) {
                        if let url = asset.feature.settings {
                            Button("Open Settings") { NSWorkspace.shared.open(url) }.spareButton(.secondary).controlSize(.small)
                        }
                    }
                    .help(folderNames(asset.folders))
                }
            }
        }
    }
}

/// The folders a kind of download is in, for its tooltip: a few names, then how many more.
private func folderNames(_ folders: [URL]) -> String {
    let names = folders.map(\.lastPathComponent)
    return (names.count > 8 ? names.prefix(7) + ["and \(names.count - 7) more"] : names).joined(separator: "\n")
}

/// One kind of download: what it is, who keeps it, its size and what can be done.
private struct DownloadRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    let bytes: Int64?
    var hidden = false
    var measuring = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SymbolTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.spare(size: 13, weight: .semibold))
                Text(text).font(.spare(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if measuring { ThinkingDots() } else { DownloadSize(bytes: bytes, hidden: hidden) }
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

/// A download's size. macOS hides some folders from every app, so a hidden one is at least that much, or unknown.
private struct DownloadSize: View {
    let bytes: Int64?
    var hidden = false

    var body: some View {
        if hidden && (bytes ?? 0) < 1_000_000 {
            Text("Size not reported").font(.spare(size: 12)).foregroundStyle(.tertiary)
                .help("macOS doesn't let apps measure these folders.")
        } else if hidden {
            VStack(alignment: .trailing, spacing: 1) {
                Text("at least").font(.spare(size: 10.5)).foregroundStyle(.secondary)
                SizeText(bytes: bytes, weight: .semibold)
            }
            .help("macOS doesn't let apps measure all of these folders, so there's more than this.")
        } else {
            SizeText(bytes: bytes, weight: .semibold)
        }
    }
}

/// Asks before Spare changes Siri's language: what changes, where else it shows up, and how to undo it.
private struct IntelligenceConsent: View {
    let change: MacDownloadsModel.Switch
    @ObservedObject var model: MacDownloadsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                SymbolTile(symbol: "brain.head.profile", tint: Ink.ink, size: 36)
                Text(title).font(.spare(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: point.symbol).font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(width: 18).accessibilityHidden(true)
                        Text(point.text).font(.spare(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.spareButton(.secondary).keyboardShortcut(.cancelAction)
                Button(action) {
                    dismiss()
                    model.run(change)
                }
                .spareButton(.primary).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(24)
        .frame(width: 470)
        .background(PaperBackground())
    }

    private var title: String {
        switch change {
        case .off: "Switch Apple Intelligence off?"
        case .on: "Switch Apple Intelligence on again?"
        case .release: "Let macOS remove the models?"
        }
    }

    private var action: String {
        switch change {
        case .off: "Switch Off"
        case .on: "Switch On"
        case .release: "Remove Models"
        }
    }

    private var models: String {
        guard let asset = model.intelligence, asset.bytes >= 1_000_000 else { return "its models" }
        return "its models (\(asset.hidden ? "at least " : "")\(Bytes.text(asset.bytes)))"
    }

    private var points: [(symbol: String, text: String)] {
        let mac = model.status?.systemLanguage.map(AppleIntelligence.languageName) ?? "your Mac's language"
        let siri = model.status?.siriLanguage.map(AppleIntelligence.languageName) ?? "its own language"
        switch change {
        case .off:
            let target = model.offLanguage.map(AppleIntelligence.languageName) ?? "another language"
            return [(symbol: "character.bubble",
                     text: "Siri will listen and answer in \(target). macOS runs Apple Intelligence only while Siri and your Mac use the same language, so it switches off, and macOS removes \(models)."),
                    (symbol: "icloud", text: "Siri's language syncs through iCloud, so Siri on your iPhone and iPad changes too."),
                    (symbol: "sparkles", text: "Writing Tools, Image Playground and Apple Intelligence's other features stop working on this Mac."),
                    (symbol: "arrow.uturn.backward", text: "Switch On puts Siri's language and voice back as they are now. macOS may then download the models again.")]
        case .on:
            let back = model.savedLanguage.map(AppleIntelligence.languageName) ?? mac
            return [(symbol: "character.bubble", text: "Siri goes back to \(back), with the voice it had before, and Apple Intelligence can run again."),
                    (symbol: "icloud", text: "Siri's language syncs through iCloud, so Siri on your iPhone and iPad changes too."),
                    (symbol: "arrow.down.circle", text: "macOS downloads Apple Intelligence's models again, several gigabytes, when it's ready to.")]
        case .release:
            return [(symbol: "character.bubble",
                     text: "Apple Intelligence is off, but macOS still holds \(models). It lets go of them only as Apple Intelligence switches from on to off, so Spare switches Siri to \(mac) for about a minute, then back to \(siri)."),
                    (symbol: "icloud", text: "Siri's language syncs through iCloud, so Siri on your iPhone and iPad follows both changes."),
                    (symbol: "clock", text: "It takes up to two minutes. If something doesn't work, Spare puts Siri back as it was.")]
        }
    }
}
