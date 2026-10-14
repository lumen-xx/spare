import SwiftUI
import SpareCore

/// Privacy and debloating: Apple Intelligence and its models, what macOS shares with Apple, Apple's apps, and small
/// annoyances. Switches show what's on; nothing changes until the person reviews the changes and applies them.
@MainActor
final class DebloatModel: ObservableObject {
    static let shared = DebloatModel()

    @Published private(set) var states: [String: Debloat.State] = [:]
    /// The tweaks Spare's profile locks, nil while it isn't installed.
    @Published private(set) var profile: Set<String>?
    /// Bytes of each known model set on this Mac; nil when macOS's asset service didn't answer.
    @Published private(set) var models: [String: Int64]?
    @Published private(set) var apps: [BuiltInApp] = []
    @Published private(set) var blocks: [String: BuiltInApps.Block] = [:]
    @Published private(set) var dock: Set<String> = []
    /// Apple's optional apps from the App Store that are installed.
    @Published private(set) var optional: [InstalledApp] = []
    /// Switches the person flipped and hasn't applied: tweak → applied or not.
    @Published private(set) var edits: [String: Bool] = [:]
    @Published private(set) var loading = false
    /// What's happening, while something changes.
    @Published private(set) var step: String?
    /// The profile Spare is waiting for the person to approve in System Settings.
    @Published private(set) var awaiting: Set<String>?
    @Published var reviewing = false
    /// What Spare changed outside its profile, nil until read.
    @Published private(set) var undoable: Debloat.Undoable?
    private var started = false
    private var removeModelsAfterProfile = false
    private var watch: Task<Void, Never>?
    /// Counts loads, so an older one finishing late never overwrites a newer one.
    private var generation = 0

    func startIfNeeded() { if !started { load() } }
    func reloadIfStarted() { if started { load() } }

    func load() {
        #if DEBUG
        if Demo.isOn { if undoable == nil { undoable = .init() }; return }
        #endif
        started = true
        loading = true
        generation += 1
        let current = generation
        Task {
            async let read = background { () -> (Debloat.Snapshot, [String: Debloat.State]) in
                Debloat.moveOnFromPlayKeysService()
                let snapshot = Debloat.Snapshot.now()
                return (snapshot, Dictionary(uniqueKeysWithValues: Debloat.all.map { ($0.id, snapshot.state($0)) }))
            }
            async let sizes = background { AppleModels.sizes() }
            async let builtIn = background { BuiltInApps.list() }
            async let installed = background { Apps.installed(home: home).filter { $0.isApple && $0.fromAppStore } }
            let ((snapshot, states), models, apps, optional) = await (read, sizes, builtIn, installed)
            guard current == generation else { return }
            self.states = states
            self.profile = snapshot.profile
            self.models = models
            let blocks = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, BuiltInApps.block(of: $0, disabled: snapshot.disabled)) })
            // Blocked apps first, so they're seen without scrolling. Only on loading: rows don't jump while clicking.
            let kept = { (app: BuiltInApp) in blocks[app.id] != .open }
            self.apps = apps.filter(kept) + apps.filter { !kept($0) }
            self.blocks = blocks
            self.dock = snapshot.dock
            self.undoable = Debloat.undoable(apps: apps, disabled: snapshot.disabled)
            self.optional = optional.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // Edits that now match the Mac are done.
            self.edits = edits.filter { id, on in (states[id] == .applied) != on }
            self.loading = false
        }
    }

    // MARK: Switches

    /// Applied now: read back from the Mac, or locked by Spare's profile.
    func applied(_ tweak: Debloat.Tweak) -> Bool {
        states[tweak.id] == .applied || (tweak.inProfile && profile?.contains(tweak.id) == true)
    }

    /// Whether the tweak will be applied once the changes are: the person's edit, or how it is now.
    func wanted(_ tweak: Debloat.Tweak) -> Bool { edits[tweak.id] ?? applied(tweak) }

    func changeable(_ tweak: Debloat.Tweak) -> Bool {
        let state = states[tweak.id]
        return state != .managed && state != .unsupported && step == nil && awaiting == nil
    }

    /// The switch: on while the feature is allowed, which is while the tweak isn't applied.
    func allowed(_ tweak: Debloat.Tweak) -> Binding<Bool> {
        Binding(get: { !self.wanted(tweak) }, set: { allowed in self.set(tweak, applied: !allowed) })
    }

    func set(_ tweak: Debloat.Tweak, applied on: Bool) {
        guard changeable(tweak) else { return }
        edits[tweak.id] = on == applied(tweak) ? nil : on
    }

    /// Switches off everything Spare suggests in a group.
    func suggest(_ group: Debloat.Group) {
        for tweak in Debloat.all where tweak.group == group && tweak.suggested && changeable(tweak) { set(tweak, applied: true) }
    }

    func discard() { edits = [:] }

    // MARK: Check boxes

    /// The card's check box: on when every switch in it is off.
    func allOff(_ tweaks: [Debloat.Tweak]) -> CheckState {
        let usable = tweaks.filter(changeable)
        let off = usable.filter(wanted).count
        return usable.isEmpty || off == 0 ? .off : off == usable.count ? .on : .mixed
    }

    /// Switches all of them off, or back on when they all are off already.
    func toggleAllOff(_ tweaks: [Debloat.Tweak]) {
        let on = allOff(tweaks) != .on
        for tweak in tweaks where changeable(tweak) { set(tweak, applied: on) }
    }

    /// The features that need a model set.
    func users(of set: String) -> [Debloat.Tweak] { Debloat.all.filter { $0.models.contains(set) } }

    /// A model's check box: on when every feature needing it will be off, so it goes.
    func removing(_ set: String) -> CheckState { allOff(users(of: set)) }

    func toggleRemoving(_ set: String) { toggleAllOff(users(of: set)) }

    /// The Models card's Select All.
    var removingAll: CheckState { allOff(Debloat.all.filter { !$0.models.isEmpty }) }

    func toggleRemovingAll() { toggleAllOff(Debloat.all.filter { !$0.models.isEmpty }) }

    /// Switches everything on a page back on.
    func allowAll(_ group: Debloat.Group) {
        for tweak in Debloat.all where tweak.group == group && wanted(tweak) && changeable(tweak) { set(tweak, applied: false) }
        reviewing = true
    }

    var hasChanges: Bool { !edits.isEmpty }

    var turningOff: [Debloat.Tweak] { Debloat.all.filter { edits[$0.id] == true } }
    var turningOn: [Debloat.Tweak] { Debloat.all.filter { edits[$0.id] == false } }

    /// The tweaks the profile should lock once the changes are applied.
    var targetProfile: Set<String> {
        Set(Debloat.all.filter { $0.inProfile && wanted($0) && states[$0.id] != .managed && states[$0.id] != .unsupported }.map(\.id))
    }

    var profileChanges: Bool { targetProfile != (profile ?? []) }

    /// Model sets that are on this Mac and can go once these tweaks are applied.
    func removableSets(for tweaks: Set<String>) -> [String] {
        Debloat.setsToRemove(off: tweaks).filter { (models?[$0] ?? 0) > 0 }
    }

    func modelBytes(_ sets: [String]) -> Int64 { sets.reduce(0) { $0 + (models?[$1] ?? 0) } }

    /// Sets the installed profile already keeps from downloading, still on disk.
    var removableNow: [String] { removableSets(for: profile ?? []) }

    // MARK: Applying

    func apply() {
        guard hasChanges, step == nil else { return }
        #if DEBUG
        if Demo.isOn { edits = [:]; Demo.pretend("Spare would have applied these changes."); return }
        #endif
        let on = turningOff, off = turningOn
        let target = targetProfile
        let changeProfile = profileChanges
        let sets = removableSets(for: target)
        step = "Changing settings"
        Task {
            let problems = await background { () -> [String] in
                var journal = Debloat.Journal.load()
                var problems: [String] = []
                for tweak in off { problems += Debloat.revert(tweak, journal: &journal) }
                for tweak in on { problems += Debloat.apply(tweak, journal: &journal) }
                journal.save()
                let restart = Set((on + off).filter { $0.changes.contains { !$0.inProfile } }.flatMap(\.restart))
                for name in restart { _ = Shell.run("/usr/bin/killall", [name]) }
                return problems
            }
            step = nil
            edits = [:]
            if changeProfile {
                if target.isEmpty {
                    removeProfile(problems: problems)
                } else {
                    removeModelsAfterProfile = !sets.isEmpty
                    present(target, problems: problems)
                }
            } else {
                Shared.shared.banner = problems.isEmpty
                    ? .init(title: "Changed \(on.count + off.count == 1 ? "1 setting" : "\(on.count + off.count) settings")", detail: nil)
                    : .init(title: "Some settings didn't change", detail: nil, problems: problems, failed: true)
            }
            load()
        }
    }

    /// Writes the profile and opens it, so System Settings offers it, then waits for the person to approve it.
    private func present(_ tweaks: Set<String>, problems: [String]) {
        let file = URL.cachesDirectory.appendingPathComponent("com.opyuii.spare/Spare Privacy.mobileconfig")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Debloat.profile(tweaks).write(to: file, options: .atomic)
        } catch {
            Shared.shared.banner = .init(title: "Spare couldn't write the profile", detail: error.localizedDescription, failed: true)
            return
        }
        awaiting = tweaks
        // Settings opens straight away at Device Management; the steps stay on this page while Spare waits, so
        // nothing else pops up. A second look brings Settings back to the front once the profile is listed.
        NSWorkspace.shared.open(file)
        Self.openProfiles()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if awaiting == tweaks { Self.openProfiles() }
        }
        if !problems.isEmpty {
            Shared.shared.banner = .init(title: "Some settings didn't change", detail: nil, problems: problems, failed: true)
        }
        watchForProfile(tweaks)
    }

    static func openProfiles() {
        if let url = URL(string: SystemChanges.profilesSettings) { NSWorkspace.shared.open(url) }
    }

    /// Looks every two seconds, for up to fifteen minutes, whether the profile arrived.
    private func watchForProfile(_ tweaks: Set<String>) {
        watch?.cancel()
        watch = Task {
            for _ in 0..<450 {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                let installed = await background { Debloat.installedProfile() }
                if installed == tweaks {
                    awaiting = nil
                    load()
                    if removeModelsAfterProfile {
                        removeModelsAfterProfile = false
                        removeModels(Debloat.setsToRemove(off: tweaks))
                    } else {
                        Shared.shared.banner = .init(title: "The profile is installed", detail: "Its settings are locked until you switch them on again here.")
                    }
                    return
                }
            }
            awaiting = nil
        }
    }

    func stopWaiting() {
        watch?.cancel()
        awaiting = nil
        removeModelsAfterProfile = false
    }

    /// Removes "Spare Privacy" and with it everything it locks, after the person's password.
    func removeInstalledProfile() {
        guard profile != nil, step == nil, awaiting == nil else { return }
        #if DEBUG
        if Demo.isOn { Demo.pretend("Spare would have removed its profile."); return }
        #endif
        edits = [:]
        removeProfile(problems: [])
        load()
    }

    private func removeProfile(problems: [String]) {
        if let problem = Privileged.run(Debloat.removeProfileCommand(),
                                        prompt: "Spare wants to remove its privacy profile.") {
            if problem == "Cancelled." { return }
            Shared.shared.banner = .init(title: "Remove “Spare Privacy” in System Settings",
                                         detail: "macOS didn't let Spare remove it: \(problem)", problems: problems, failed: true,
                                         next: .init(title: "Open System Settings") { DebloatModel.openProfiles() })
        } else {
            Shared.shared.banner = .init(title: "Removed the privacy profile",
                                         detail: "Everything it locked is as macOS has it again. macOS may download Apple Intelligence's models again.",
                                         problems: problems)
        }
        load()
    }

    /// Asks macOS's asset service to remove the models the profile keeps from downloading.
    func removeModels(_ chosen: [String]? = nil) {
        let sets = chosen ?? removableNow
        guard !sets.isEmpty, step == nil else { return }
        #if DEBUG
        if Demo.isOn { Demo.pretend("Spare would have removed these models."); return }
        #endif
        let before = models ?? [:]
        step = "Removing models"
        Task {
            let failed = await background { AppleModels.remove(sets) }
            let sizes = await background { AppleModels.sizes() }
            step = nil
            let problems = failed.map { "\($0.set): \($0.reason)" }
            // Only the sets macOS agreed to remove count, and only when it says how much is left.
            let titles = Set(failed.map(\.set))
            let done = sets.filter { name in !titles.contains(Debloat.modelSet(name)?.title ?? name) }
            let before = done.reduce(Int64(0)) { $0 + (before[$1] ?? 0) }
            let after = sizes.map { sizes in done.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) } }
            if done.isEmpty {
                Shared.shared.banner = .init(title: "macOS kept the models", detail: problems.first, problems: Array(problems.dropFirst()), failed: true,
                                             next: .init(title: "Try Again") { DebloatModel.shared.removeModels() })
            } else if let after, after < before {
                Shared.shared.banner = .init(title: "Removed \(Bytes.text(before - after)) of models",
                                             detail: "The profile keeps them from downloading again.", problems: problems)
            } else {
                Shared.shared.banner = .init(title: "macOS let go of \(Bytes.text(before)) of models",
                                             detail: "It deletes the files on its own schedule, usually within a few minutes. Storage settings may count them until then.",
                                             problems: problems)
            }
            Shared.shared.refreshSpace()
            load()
        }
    }

    // MARK: Undoing everything

    /// Anything of Spare's to undo, once read.
    var anythingToUndo: Bool { profile != nil || !(undoable?.isEmpty ?? true) }

    /// What undoing does, as a sentence: "Removes the “Spare Privacy” profile, puts back 3 settings and lets 1 app open again."
    var undoPlan: String? {
        var parts: [String] = []
        if profile != nil { parts.append("removes the “Spare Privacy” profile") }
        if let undoable {
            if !undoable.tweaks.isEmpty { parts.append("puts back \(undoable.tweaks.count == 1 ? "1 setting" : "\(undoable.tweaks.count) settings") as they were") }
            if !undoable.blocked.isEmpty { parts.append("lets \(undoable.blocked.count == 1 ? "1 blocked app" : "\(undoable.blocked.count) blocked apps") open again") }
        }
        guard let last = parts.popLast() else { return nil }
        let sentence = parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }

    /// One thing Spare can undo, for the list to pick from.
    struct UndoItem: Identifiable, Hashable {
        enum Kind: Hashable { case profile, tweak, app }
        let kind: Kind
        let id: String
        let title: String
        let detail: String
    }

    /// Everything there is to undo now: the profile, each setting Spare changed, each blocked app.
    var undoItems: [UndoItem] {
        var items: [UndoItem] = []
        if let profile {
            items.append(UndoItem(kind: .profile, id: "profile", title: "“Spare Privacy” profile",
                                  detail: "Switches \(profile.count == 1 ? "1 setting" : "\(profile.count) settings") back on. Needs your password."))
        }
        for id in undoable?.tweaks ?? [] {
            guard let tweak = Debloat.all.first(where: { $0.id == id }) else { continue }
            items.append(UndoItem(kind: .tweak, id: id, title: tweak.title, detail: "Put back as it was"))
        }
        for id in undoable?.blocked ?? [] {
            let name = apps.first { $0.bundleID == id }?.name ?? id
            items.append(UndoItem(kind: .app, id: id, title: name, detail: "Opens again"))
        }
        return items
    }

    /// Undoes the chosen items, the profile last as it needs a password. True when all of them are undone; a
    /// cancelled password counts as not done.
    @discardableResult
    func undo(_ chosen: Set<UndoItem>) async -> Bool {
        guard step == nil, !chosen.isEmpty else { return chosen.isEmpty }
        #if DEBUG
        if Demo.isOn { Demo.pretend("Spare would have undone \(chosen.count) things."); return false }
        #endif
        stopWaiting()
        edits = [:]
        step = "Undoing"
        let tweaks = Set(chosen.filter { $0.kind == .tweak }.map(\.id))
        let unblock = Set(chosen.filter { $0.kind == .app }.map(\.id))
        let removeProfile = chosen.contains { $0.kind == .profile }
        let apps = apps.isEmpty ? await background { BuiltInApps.list() } : apps
        let local = await background { () -> [String] in
            guard !tweaks.isEmpty || !unblock.isEmpty else { return [] }
            let result = Debloat.undoLocal(apps: apps, tweaks: tweaks, unblock: unblock)
            for name in result.restart { _ = Shell.run("/usr/bin/killall", [name]) }
            return result.problems
        }
        var problems = local
        var cancelled = false
        if removeProfile, await background({ Debloat.installedProfile() }) != nil {
            if let problem = Privileged.run(Debloat.removeProfileCommand(), prompt: "Spare wants to remove its privacy profile.") {
                if problem == "Cancelled." { cancelled = true } else { problems.append("“Spare Privacy”: \(problem)") }
            }
        }
        step = nil
        load()
        let profileLeft = removeProfile ? await background { Debloat.installedProfile() } != nil : false
        let done = problems.isEmpty && !cancelled && !profileLeft
        if done {
            Shared.shared.banner = .init(title: chosen.count == 1 ? "Undid 1 change" : "Undid \(chosen.count) changes",
                                         detail: removeProfile ? "Apple Intelligence models may download again." : nil)
        } else if cancelled {
            Shared.shared.banner = .init(title: "The profile is still installed",
                                         detail: "Everything else you picked is undone. Remove “Spare Privacy” when you're ready, here or in System Settings.",
                                         problems: problems, failed: true)
        } else {
            Shared.shared.banner = .init(title: "Some things weren't undone", detail: problems.count == 1 ? problems[0] : nil,
                                         problems: problems.count == 1 ? [] : problems, failed: true,
                                         log: problems.joined(separator: "\n"))
        }
        return done
    }

    // MARK: Apple's apps

    func toggleBlock(_ app: BuiltInApp) {
        guard step == nil else { return }
        let block = blocks[app.id] ?? .open
        step = block == .blocked ? "Allowing \(app.name)" : "Blocking \(app.name)"
        Task {
            let problem = await background { () -> String? in
                block == .blocked ? BuiltInApps.unblock(app, disabled: Launchd.disabledInSession()) : BuiltInApps.block(app)
            }
            step = nil
            if let problem {
                Shared.shared.banner = .init(title: block == .blocked ? "\(app.name) is still blocked" : "\(app.name) isn't blocked", detail: problem, failed: true)
            } else {
                Shared.shared.banner = block == .blocked
                    ? .init(title: "\(app.name) opens again", detail: nil)
                    : .init(title: "\(app.name) won't open", detail: "Allow it again here whenever you like. A macOS update lifts the block, and Spare then shows it.")
            }
            load()
        }
    }

    func toggleDock(_ app: BuiltInApp) {
        guard step == nil else { return }
        let inDock = dock.contains(app.bundleID)
        step = "Changing the Dock"
        Task {
            await background {
                var journal = Debloat.Journal.load()
                let key = "dock:\(app.bundleID)"
                if inDock {
                    if let tile = Dock.remove(app.bundleID) { journal.entries[key] = .init(previous: .dock([tile]), date: Date()) }
                } else {
                    var tile: Debloat.DockTile?
                    if case .dock(let tiles)? = journal.entries[key]?.previous { tile = tiles.first }
                    Dock.add(app.bundleID, tile: tile, url: app.url)
                    journal.entries[key] = nil
                }
                journal.save()
            }
            step = nil
            load()
        }
    }

    #if DEBUG
    /// Screenshots of the review and of the wait for the profile, with made-up data only.
    func showDemo(review: Bool, waiting: Bool) {
        started = true
        models = [Debloat.foundationModels: 0, "com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive": 434_500_000]
        if review {
            edits = ["spatial-photos": true, "writing-tools": true, "genmoji": true]
            reviewing = true
        }
        if waiting { awaiting = ["spatial-photos"] }
    }
    #endif

    func uninstall(_ app: InstalledApp) {
        Navigation.shared.page = .apps
        AppsModel.shared.startIfNeeded()
        AppsModel.shared.selection = app.id
    }
}

// MARK: - Page

struct DebloatView: View {
    let group: Debloat.Group
    @ObservedObject var model = DebloatModel.shared
    @Environment(\.reduceMotion) private var reduceMotion

    private var tweaks: [Debloat.Tweak] { Debloat.all.filter { $0.group == group } }

    var body: some View {
        PageScroll {
            header.arrives(0)
            if model.awaiting != nil {
                waiting.arrives(1)
            } else if let locked = model.profile, group == .intelligence || group == .sharing {
                ProfileCard(count: locked.count, busy: model.step != nil) { model.removeInstalledProfile() }.arrives(1)
            }
            if group == .intelligence { modelsCard.arrives(2) }
            switches.arrives(3)
            if group == .apps {
                builtIn.arrives(4)
                if !model.optional.isEmpty { optional.arrives(5) }
            }
            footer.arrives(6)
        }
        .toolbar {
            ToolbarItem {
                Button { Refresh.everything() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || model.step != nil).help("Look Again")
            }
        }
        .sheet(isPresented: $model.reviewing) { DebloatReview(model: model) }
        .onAppear {
            model.startIfNeeded()
            #if DEBUG
            let defaults = UserDefaults.standard
            if Demo.isOn, defaults.bool(forKey: "demoReview") || defaults.bool(forKey: "demoWaiting") {
                model.showDemo(review: defaults.bool(forKey: "demoReview"), waiting: defaults.bool(forKey: "demoWaiting"))
            }
            #endif
        }
    }

    // MARK: Header

    private var offCount: Int { tweaks.filter(model.wanted).count }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(model.step ?? (model.loading ? "Looking" : kicker)).contentTransition(.opacity)
                    if model.loading || model.step != nil { ThinkingDots().transition(.opacity) }
                }
                .font(.spare(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .animation(Motion.gentle(Motion.settle, reduceMotion: reduceMotion), value: model.loading)
                Text("\(offCount) of \(tweaks.count) off")
                    .font(.spare(size: 46, weight: .bold))
                    .contentTransition(.numericText())
                    .animation(Motion.count.delay(Beat.settle), value: offCount)
                Text(summary).font(.spare(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if model.hasChanges {
                    Button("Discard") { model.discard() }.spareButton(.quiet).controlSize(.small)
                } else if tweaks.contains(where: { $0.suggested && !model.wanted($0) && model.changeable($0) }) {
                    Button("Suggested") { model.suggest(group) }.spareButton(.secondary).controlSize(.small)
                        .help("Switch off what Spare suggests on this page. Nothing changes until you apply.")
                }
                Button { model.reviewing = true } label: {
                    Label(model.hasChanges ? "Apply \(model.edits.count)…" : "Apply…", systemImage: "checkmark").padding(.horizontal, 2)
                }
                .spareButton(.primary)
                .controlSize(.large)
                .disabled(!model.hasChanges || model.step != nil || model.awaiting != nil)
            }
        }
    }

    private var kicker: String {
        switch group {
        case .intelligence: "Apple Intelligence"
        case .sharing: "What your Mac tells Apple"
        case .apps: "Apple's apps"
        case .annoyances: "Small annoyances"
        }
    }

    private var summary: String {
        switch group {
        case .intelligence: "Switch off the features you don't use. Their models are removed and kept from downloading again."
        case .sharing: "Stop analytics, recordings and searches leaving your Mac."
        case .apps: "Quiet the apps that come with macOS, block the ones you never open, and remove the optional ones."
        case .annoyances: "Switch off the surprises nobody asked for."
        }
    }

    private var waiting: some View {
        Card(fill: Ink.lifted) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    SymbolTile(symbol: "checkmark.shield", tint: Ink.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text("Install “Spare Privacy” in System Settings").font(.spare(size: 13, weight: .semibold))
                            ThinkingDots()
                        }
                        Text("Spare is waiting and carries on by itself once it's installed.")
                            .font(.spare(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("Stop Waiting") { model.stopWaiting() }.spareButton(.quiet).controlSize(.small)
                    Button("Open Settings") { DebloatModel.openProfiles() }.spareButton(.secondary).controlSize(.small)
                }
                ProfileGuide()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
    }

    // MARK: Switches

    private var switches: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: switchesTitle, subtitle: "On means macOS does it. Switch off what you don't want, then apply.") {
                SelectAll(title: "Switch All Off", state: model.allOff(tweaks)) { model.toggleAllOff(tweaks) }
                    .disabled(model.step != nil || model.awaiting != nil)
            }
            Card {
                ForEach(Array(tweaks.enumerated()), id: \.element.id) { index, tweak in
                    if index > 0 { RowDivider().padding(.horizontal, 12) }
                    TweakRow(tweak: tweak, model: model)
                }
            }
        }
    }

    private var switchesTitle: String {
        switch group {
        case .intelligence: "Features"
        case .sharing: "Sharing"
        case .apps: "Stores and services"
        case .annoyances: "Behaviour"
        }
    }

    // MARK: Models

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Models", subtitle: "Tick a model to switch off the features that need it; it's removed once you apply.") {
                HStack(spacing: 14) {
                    if !model.removableNow.isEmpty {
                        Button("Remove \(Bytes.text(model.modelBytes(model.removableNow)))") { model.removeModels() }
                            .spareButton(.secondary).controlSize(.small)
                            .disabled(model.step != nil)
                    }
                    SelectAll(title: "Select All", state: model.removingAll) { model.toggleRemovingAll() }
                        .disabled(model.step != nil || model.awaiting != nil)
                }
            }
            Card {
                if model.models == nil && !model.loading {
                    Text("macOS's asset service didn't answer, so Spare can't see or remove the models on this version of macOS.")
                        .font(.spare(size: 12)).foregroundStyle(.secondary).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(Debloat.modelSets.enumerated()), id: \.element.name) { index, set in
                    if index > 0 { RowDivider().padding(.horizontal, 12) }
                    let bytes = model.models?[set.name]
                    let blocked = Debloat.setsToRemove(off: model.profile ?? []).contains(set.name)
                    HStack(spacing: 12) {
                        CheckBox(state: model.removing(set.name)) { model.toggleRemoving(set.name) }
                            .disabled(model.step != nil || model.awaiting != nil)
                            .accessibilityLabel("Remove \(set.title)")
                            .help("Switches off " + ListFormatter.localizedString(byJoining: model.users(of: set.name).map(\.title)))
                        SymbolTile(symbol: "cpu", tint: (bytes ?? 0) > 0 ? Ink.ink : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(set.title).font(.spare(size: 13, weight: .semibold))
                            Text(blocked ? ((bytes ?? 0) > 0 ? "Kept from downloading again. Remove it to get the space back." : "Removed, and kept from downloading again.")
                                         : (bytes ?? 0) > 0 ? "Goes once every feature that needs it is off." : "Not downloaded.")
                                .font(.spare(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        if model.loading && bytes == nil { ThinkingDots() } else if (bytes ?? 0) > 0 { SizeText(bytes: bytes, weight: .semibold) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .onTapGesture { if model.step == nil && model.awaiting == nil { model.toggleRemoving(set.name) } }
                }
            }
        }
    }

    // MARK: Built-in apps

    private var builtIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Built into macOS",
                           subtitle: "These live on the sealed system volume, so no app can delete them and deleting them wouldn't free space. Block the ones you never want open, or take them out of the Dock.")
            Card(hoverRows: true) {
                if model.apps.isEmpty {
                    HStack(spacing: 8) {
                        if model.loading { ThinkingDots() }
                        Text(model.loading ? "Looking" : "No apps found.").font(.spare(size: 12.5)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { RowDivider().padding(.leading, 46).padding(.trailing, 12) }
                    BuiltInRow(app: app, model: model)
                }
            }
        }
    }

    private var optional: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Optional apps from Apple", subtitle: "These came from the App Store and reinstall free from there.")
            Card(hoverRows: true) {
                ForEach(Array(model.optional.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { RowDivider().padding(.leading, 46).padding(.trailing, 12) }
                    HStack(spacing: 10) {
                        Image(nsImage: AppLookup.icon(for: app.url, size: 24)).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                        Text(app.name).font(.spare(size: 12.5, weight: .medium))
                        Spacer(minLength: 12)
                        Button("Uninstall…") { model.uninstall(app) }.spareButton(.secondary).controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .fileMenu([app.url])
                    .hoverWash()
                    .padding(.horizontal, RowWash.inset).padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(footerText).font(.spare(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if tweaks.contains(where: model.applied) {
                Button("Switch All Back On…") { model.allowAll(group) }.spareButton(.quiet).controlSize(.small).padding(.leading, -6)
                    .disabled(model.step != nil || model.awaiting != nil)
            }
        }
        .padding(.horizontal, 4)
    }

    private var footerText: String {
        switch group {
        case .intelligence, .sharing:
            "Settings marked with a lock go into one profile, “Spare Privacy”, which you approve in System Settings; macOS lets only a profile keep them switched off. Changing one later makes a new version that replaces the old one once you approve it. Nothing under /System changes, and System Integrity Protection stays on."
        case .apps:
            "A block works through launchd, as macOS starts every app, and quits the app if it's open. It lasts until the next macOS update replaces the app. Opening a blocked app shows macOS's “can't be opened” message; to keep Music closed without it, switch off Play keys opening Music above."
        case .annoyances:
            "Spare keeps each setting's value from before, and puts exactly that back when you switch it on again."
        }
    }
}

/// A card's check box for all its rows, with its label.
private struct SelectAll: View {
    let title: String
    let state: CheckState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            CheckBox(state: state, action: action).accessibilityLabel(title)
            Text(title).font(.spare(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .onTapGesture(perform: action)
        }
        .fixedSize()
    }
}

/// One setting: what it is, what switching it off costs, and its switch.
private struct TweakRow: View {
    let tweak: Debloat.Tweak
    @ObservedObject var model: DebloatModel

    var body: some View {
        let state = model.states[tweak.id]
        let edited = model.edits[tweak.id] != nil
        Toggle(isOn: model.allowed(tweak)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tweak.title).font(.spare(size: 13, weight: .medium))
                    if tweak.inProfile {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                            .help("Kept off by the “Spare Privacy” profile")
                    }
                    if edited { Tag(text: "Not applied", tint: Ink.warm) }
                    if state == .managed { Tag(text: "Set by your organisation", tint: .secondary) }
                    if state == .unsupported { Tag(text: "Not in this macOS", tint: .secondary) }
                    if state == .partial && !edited { Tag(text: "Partly off", tint: .secondary) }
                }
                Text(tweak.detail).font(.spare(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let caveat = tweak.caveat, model.wanted(tweak) || edited {
                    Text(caveat).font(.spare(size: 11.5)).foregroundStyle(Ink.warm).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(SpareSwitchStyle())
        .disabled(!model.changeable(tweak))
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// A built-in app: whether it can open and whether it's in the Dock.
private struct BuiltInRow: View {
    let app: BuiltInApp
    @ObservedObject var model: DebloatModel
    @State private var confirming = false

    var body: some View {
        let block = model.blocks[app.id] ?? .open
        let inDock = model.dock.contains(app.bundleID)
        HStack(spacing: 10) {
            Image(nsImage: AppLookup.icon(for: app.url, size: 24)).resizable().frame(width: 24, height: 24)
                .opacity(block == .blocked ? 0.45 : 1).accessibilityHidden(true)
            Text(app.name).font(.spare(size: 12.5, weight: .medium))
                .foregroundStyle(block == .blocked ? .secondary : .primary)
            if block == .lapsed { Tag(text: "Opens again since an update", tint: .secondary).help("Block it again to keep it closed.") }
            Spacer(minLength: 12)
            if inDock {
                Button("Remove from Dock") { model.toggleDock(app) }.spareButton(.quiet).controlSize(.small).disabled(model.step != nil)
            }
            // Where the eye goes down the list: blocked apps say so beside a filled Allow, open ones only offer Block.
            if block == .blocked {
                Label("Blocked", systemImage: "nosign")
                    .font(.spare(size: 11.5, weight: .semibold)).foregroundStyle(Ink.warm)
            }
            Button(block == .blocked ? "Allow" : "Block") {
                if block != .blocked && !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
                    confirming = true
                } else {
                    model.toggleBlock(app)
                }
            }
                .spareButton(block == .blocked ? .primary : .secondary).controlSize(.small)
                .disabled(app.job == nil && block != .blocked)
                .help(block == .blocked ? "Let \(app.name) open again" : "Keep \(app.name) from opening")
                .frame(minWidth: 60, alignment: .trailing)
                .disabled(model.step != nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .hoverWash()
        .padding(.horizontal, RowWash.inset).padding(.vertical, 1)
        .contextMenu {
            FileMenuItems(urls: [app.url])
            if !inDock { Button("Add to Dock") { model.toggleDock(app) } }
        }
        .alert("Block \(app.name)?", isPresented: $confirming) {
            Button("Quit and Block", role: .destructive) { model.toggleBlock(app) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(app.name) is open. Blocking it quits it straight away, without asking to save, so save your work first.")
        }
    }
}

/// What applying will do, before it does it.
private struct DebloatReview: View {
    @ObservedObject var model: DebloatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sets = model.removableSets(for: model.targetProfile)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SymbolTile(symbol: "checkmark.shield", tint: Ink.ink, size: 36)
                Text("Apply \(model.edits.count == 1 ? "1 change" : "\(model.edits.count) changes")?").font(.spare(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.turningOff.isEmpty { list("Switching off", model.turningOff) }
                    if !model.turningOn.isEmpty { list("Switching back on", model.turningOn) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            if installing {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Then, in System Settings").font(.spare(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    ProfileGuide(compact: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if model.profileChanges {
                    point("checkmark.shield", model.targetProfile.isEmpty
                          ? "Spare removes its profile, “Spare Privacy”, after you enter an administrator password."
                          : "These settings go into one profile, “Spare Privacy”, which only you can install. Spare opens System Settings for you and waits.")
                }
                if !sets.isEmpty {
                    point("cpu", "Once it's installed, Spare removes \(Bytes.text(model.modelBytes(sets))) of Apple Intelligence models and keeps them from downloading again.")
                }
                if model.turningOff.contains(where: { $0.id == "siri" }) {
                    point("mic.slash", "Siri switches off on this Mac only. Your iPhone and iPad keep it.")
                }
                if installing && model.profile != nil {
                    point("arrow.triangle.2.circlepath", "This makes a new version of “Spare Privacy”. Once you approve it, it replaces the one installed now.")
                }
                point("arrow.uturn.backward", installing || model.profile != nil
                      ? "To undo one, switch it back on here and apply again. To undo all of them, click Remove Profile… at the top of this page, or switch everything back on."
                      : "Switch anything back on here to undo it.")
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.spareButton(.secondary).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    dismiss()
                    model.apply()
                }
                .spareButton(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: installing ? 620 : 480)
        .background(PaperBackground())
    }

    private var installing: Bool { model.profileChanges && !model.targetProfile.isEmpty }

    private func list(_ title: String, _ tweaks: [Debloat.Tweak]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.spare(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(tweaks) { tweak in
                VStack(alignment: .leading, spacing: 1) {
                    Text(tweak.title).font(.spare(size: 12.5, weight: .medium))
                    Text(tweak.changes.isEmpty ? "Profile: its models kept from downloading" : tweak.changes.map(\.command).joined(separator: "\n"))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text(text).font(.spare(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Spare Privacy" as it's installed, with the one button that takes it off again.
private struct ProfileCard: View {
    let count: Int
    let busy: Bool
    let remove: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: "checkmark.shield.fill", tint: Ink.sea, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("“Spare Privacy” is installed").font(.spare(size: 12.5, weight: .semibold))
                Text("It keeps \(count == 1 ? "1 setting" : "\(count) settings") switched off. It's listed in System Settings › General › Device Management and on Spare's Profiles page.")
                    .font(.spare(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Remove Profile…") { confirming = true }
                .spareButton(.secondary).controlSize(.small).disabled(busy)
        }
        .padding(12)
        .background(RoundedRectangle.continuous(12).fill(Ink.wash))
        .confirmationDialog("Remove “Spare Privacy”?", isPresented: $confirming) {
            Button("Remove Profile", role: .destructive, action: remove)
        } message: {
            Text("Everything it keeps switched off switches back on, and Apple Intelligence models may download again. macOS asks for an administrator password.")
        }
    }
}
