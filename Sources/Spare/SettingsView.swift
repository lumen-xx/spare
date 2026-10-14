import SwiftUI
import UniformTypeIdentifiers
import SpareCore

struct SettingsView: View {
    @ObservedObject var shared = Shared.shared
    @ObservedObject var updates = Updates.shared
    @ObservedObject var debloat = DebloatModel.shared
    @ObservedObject var navigation = Navigation.shared
    @ObservedObject var finder = FinderSettings.shared
    @State private var confirmingUndo = false
    @State private var confirmingUninstall = false
    @State private var roots = Preferences.projectRoots
    @AppStorage("inactiveDays") private var inactiveDays = 30
    @AppStorage(Feel.paperKey) private var paper = true
    @AppStorage(Feel.hapticsKey) private var haptics = true
    @AppStorage(Feel.soundKey) private var sound = false
    @AppStorage(Feel.themeKey) private var theme = Feel.Theme.automatic
    @AppStorage(Ask.key) private var askBeforeTrash = true
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        PageScroll(maxWidth: 700, spacing: 24) {
            group("Project Folders",
                  footer: roots.isEmpty ? "Add the folders where you keep code to find node_modules and other build folders."
                                        : "Spare looks for build folders up to six levels inside these.") {
                ForEach(Array(roots.enumerated()), id: \.element) { index, root in
                    if index > 0 { divider(root.path) }
                    HStack(spacing: 10) {
                        Image(nsImage: FileManager.default.fileExists(atPath: root.path) ? AppLookup.icon(for: root, size: 16) : NSWorkspace.shared.icon(for: .folder))
                            .resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                        Text(Catalog.tilde(root, home: home)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { withAnimation(reduceMotion ? Motion.calm : Motion.expand) { roots.removeAll { $0 == root } }; save() } label: {
                            Image(systemName: "minus").font(.system(size: 10, weight: .bold))
                        }
                        .spareButton(.icon)
                        .controlSize(.small)
                        .help("Stop looking here")
                        .accessibilityLabel("Stop looking in \(root.lastPathComponent)")
                    }
                    .row()
                    .transition(.opacity)
                }
                if !roots.isEmpty { divider("add") }
                HStack {
                    Button("Add Folder…") { add() }.spareButton(.secondary).controlSize(.small)
                    Spacer()
                }
                .row()
                divider("picker")
                HStack {
                    Text("Select projects untouched for")
                    Spacer()
                    Picker("Select projects untouched for", selection: $inactiveDays) {
                        Text("1 week").tag(7)
                        Text("2 weeks").tag(14)
                        Text("1 month").tag(30)
                        Text("2 months").tag(60)
                        Text("3 months").tag(90)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .row()
            }
            .arrives(0)

            group("Permissions") {
                HStack(spacing: 10) {
                    Image(systemName: shared.fullDiskAccess ? "checkmark.circle.fill" : "lock.fill")
                        .foregroundStyle(shared.fullDiskAccess ? Ink.sage : Ink.warm)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                    Text(shared.fullDiskAccess ? "Full Disk Access is on" : "Full Disk Access is off")
                    Spacer()
                    Button("Open Settings…") { Permissions.openFullDiskAccessSettings() }.spareButton(.secondary).controlSize(.small)
                }
                .row()
                .animation(Motion.settle, value: shared.fullDiskAccess)
            }
            .arrives(1)

            group("Finder", footer: "These change Finder for your whole Mac, not only for Spare. Finder restarts for a moment after a change, so it takes it in; its windows come back.") {
                ForEach(Array(FinderOptions.all.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { divider(option.id) }
                    Toggle(isOn: Binding(get: { finder.isOn(option) }, set: { finder.set(option, on: $0) })) {
                        label(option.title, option.detail)
                    }
                    .row()
                }
                divider("library")
                Toggle(isOn: Binding(get: { finder.libraryShown }, set: { finder.showLibrary($0) })) {
                    label("Library folder", "Your Library in your home folder. macOS hides it; apps keep their files there.")
                }
                .row()
                divider("view")
                HStack {
                    label("New folders open as", "Folders you've given their own view keep it.")
                    Spacer()
                    Picker("New folders open as", selection: Binding(get: { finder.view }, set: { finder.setView($0) })) {
                        ForEach(FinderOptions.View.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .row()
            }
            .toggleStyle(SpareSwitchStyle())
            .onAppear { finder.load() }
            // Finder's own switches, like Command-Shift-. for hidden files, show here when you come back to Spare.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in finder.load() }
            .arrives(2)

            group("How Spare Feels", footer: "Motion follows Reduce Motion, and colours follow Increase Contrast, in the Accessibility settings of your Mac.") {
                HStack {
                    label("Appearance", "Automatic follows your Mac.")
                    Spacer()
                    Picker("Appearance", selection: $theme) {
                        ForEach(Feel.Theme.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: theme) { _, _ in Feel.applyTheme() }
                }
                .row()
                divider("paper")
                Toggle(isOn: $paper) { label("Paper texture", "A faint grain on the page, felt more than seen.") }.row()
                divider("haptics")
                Toggle(isOn: $haptics) { label("Soft taps", "A light tap on Force Touch trackpads when something finishes.") }.row()
                divider("sound")
                Toggle(isOn: $sound) { label("Quiet sound", "A soft pop when something finishes.") }.row()
                divider("ask")
                Toggle(isOn: $askBeforeTrash) {
                    label("Ask before moving to the Trash", "History can put things back either way. Spare always asks before anything that can't be put back, and before quitting an open app.")
                }
                .row()
            }
            .toggleStyle(SpareSwitchStyle())
            .arrives(2)

            group("Updates") {
                Toggle(isOn: $updates.automatic) { Text("Check for updates automatically") }.toggleStyle(SpareSwitchStyle()).row()
                divider("check")
                HStack {
                    Button("Check Now") { updates.check() }.spareButton(.secondary).controlSize(.small)
                    Spacer()
                }
                .row()
            }
            .arrives(3)

            group("Undo and Uninstall",
                  footer: "Undo covers Privacy & Debloat. What Spare moved to the Trash is under History. Deleted accounts, printers and permissions don't come back.") {
                HStack(spacing: 12) {
                    label("Undo what Spare changed", undoText)
                    Spacer()
                    Button("Undo…") { confirmingUndo = true }
                        .spareButton(.secondary).controlSize(.small)
                        .disabled(!debloat.anythingToUndo || debloat.step != nil)
                }
                .row()
                divider("uninstall")
                HStack(spacing: 12) {
                    label("Uninstall Spare", "Pick what to undo first, then Spare and its files go to the Trash and Spare quits.")
                    Spacer()
                    Button("Uninstall…") { confirmingUninstall = true }
                        .spareButton(.secondary).controlSize(.small)
                        .disabled(debloat.step != nil)
                }
                .row()
            }
            .arrives(4)
            .onAppear {
                debloat.startIfNeeded()
                askIfSent()
            }
            .onChange(of: navigation.askToUninstall) { _, _ in askIfSent() }
            .sheet(isPresented: $confirmingUndo) {
                UndoSheet(purpose: .undo) { chosen in Task { await debloat.undo(chosen) } }
            }
            .sheet(isPresented: $confirmingUninstall) {
                UndoSheet(purpose: .uninstall) { chosen in
                    Task { if await debloat.undo(chosen) { uninstall() } }
                }
            }

            // As in Strand and Dice: who makes it, which version this is, and where releases live.
            HStack(alignment: .bottom) {
                Text("© \(String(Calendar.current.component(.year, from: Date()))) opyuii\nOpen source under the MIT License.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Version \(version) (\(build))").foregroundStyle(.secondary).textSelection(.enabled)
                    // Quiet buttons rather than Links, which on macOS keep the system's blue whatever the accent.
                    HStack(spacing: 2) {
                        link("GitHub", "https://github.com/lumen-xx/spare")
                        link("opyuii.com", "https://opyuii.com")
                    }
                    .padding(.trailing, -5)
                }
            }
            .font(.spare(size: 11))
            .padding(.horizontal, 6)
            .arrives(5)
        }
    }

    private var undoText: String {
        if debloat.undoable == nil { return "Looking at what Spare changed…" }
        return debloat.undoPlan ?? "Nothing to undo. Everything is as macOS had it."
    }

    /// Opens the Uninstall question when Apps sent the person here for it.
    private func askIfSent() {
        guard navigation.askToUninstall else { return }
        navigation.askToUninstall = false
        confirmingUninstall = true
    }

    private func uninstall() {
        if let problem = Uninstaller.run() {
            shared.banner = .init(title: "Spare is still installed", detail: problem, failed: true)
        }
    }

    private func group<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.spare(size: 13, weight: .semibold)).padding(.horizontal, 6)
                .accessibilityAddTraits(.isHeader)
            Card(radius: 12) { content() }
            if let footer {
                Text(footer).font(.spare(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func link(_ title: String, _ address: String) -> some View {
        Button(title) { if let url = URL(string: address) { NSWorkspace.shared.open(url) } }
            .spareButton(.quiet)
            .controlSize(.mini)
            .help(address)
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.spare(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private func divider(_ key: String) -> some View {
        RowDivider().padding(.horizontal, 12)
    }

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = home
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        withAnimation(reduceMotion ? Motion.calm : Motion.expand) {
            for url in panel.urls where !roots.contains(url) { roots.append(url) }
        }
        save()
    }

    private func save() { Preferences.projectRoots = roots }
}

private extension View {
    /// A settings row's padding inside its card.
    func row() -> some View {
        frame(minHeight: 24).padding(.horizontal, 14).padding(.vertical, 9)
    }
}
