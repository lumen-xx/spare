import SwiftUI
import UniformTypeIdentifiers
import SpareCore

struct SettingsView: View {
    @ObservedObject var shared = Shared.shared
    @ObservedObject var updates = Updates.shared
    @State private var roots = Preferences.projectRoots
    @AppStorage("inactiveDays") private var inactiveDays = 30
    @AppStorage(Feel.paperKey) private var paper = true
    @AppStorage(Feel.hapticsKey) private var haptics = true
    @AppStorage(Feel.soundKey) private var sound = false
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

            group("How Spare Feels", footer: "Motion follows Reduce Motion, and colours follow Increase Contrast, in the Accessibility settings of your Mac.") {
                Toggle(isOn: $paper) { label("Paper texture", "A faint grain on the page, felt more than seen.") }.row()
                divider("haptics")
                Toggle(isOn: $haptics) { label("Soft taps", "A light tap on Force Touch trackpads when something finishes.") }.row()
                divider("sound")
                Toggle(isOn: $sound) { label("Quiet sound", "A soft pop when something finishes.") }.row()
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
            .arrives(4)
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
