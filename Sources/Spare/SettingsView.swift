import SwiftUI
import SpareCore

struct SettingsView: View {
    @ObservedObject var shared = Shared.shared
    @ObservedObject var updates = Updates.shared
    @State private var roots = Preferences.projectRoots
    @AppStorage("inactiveDays") private var inactiveDays = 30

    var body: some View {
        // Full width so the toolbar's edge spans the window, with the rows kept to a readable width in the middle.
        GeometryReader { geometry in
            form.contentMargins(.horizontal, max(20, (geometry.size.width - 680) / 2), for: .scrollContent)
        }
    }

    private var form: some View {
        Form {
            Section {
                ForEach(roots, id: \.self) { root in
                    HStack {
                        Image(nsImage: AppLookup.icon(for: root, size: 16))
                        Text(Catalog.tilde(root, home: home)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { roots.removeAll { $0 == root }; save() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Stop looking here")
                    }
                }
                Button("Add Folder…") { add() }
                Picker("Select projects untouched for", selection: $inactiveDays) {
                    Text("1 week").tag(7)
                    Text("2 weeks").tag(14)
                    Text("1 month").tag(30)
                    Text("2 months").tag(60)
                    Text("3 months").tag(90)
                }
            } header: {
                Text("Project Folders")
            } footer: {
                Text(roots.isEmpty ? "Add the folders where you keep code to find node_modules and other build folders." : "Spare looks for build folders up to six levels inside these.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                HStack {
                    Label(shared.fullDiskAccess ? "Full Disk Access is on" : "Full Disk Access is off",
                          systemImage: shared.fullDiskAccess ? "checkmark.circle.fill" : "lock")
                    Spacer()
                    Button("Open Settings…") { Permissions.openFullDiskAccessSettings() }
                }
            }
            Section {
                Toggle("Check for updates automatically", isOn: $updates.automatic)
                Button("Check Now") { updates.check() }
            } header: {
                Text("Updates")
            } footer: {
                // As in Strand and Dice: who makes it, which version this is, and where releases live.
                HStack(alignment: .bottom) {
                    Text("© \(String(Calendar.current.component(.year, from: Date()))) opyuii\nOpen source under the MIT License.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Version \(version) (\(build))").foregroundStyle(.secondary).textSelection(.enabled)
                        HStack(spacing: 10) {
                            Link("GitHub", destination: URL(string: "https://github.com/lumen-xx/spare")!)
                            Link("opyuii.com", destination: URL(string: "https://opyuii.com")!)
                        }
                    }
                }
                .font(.footnote)
                .padding(.top, 14)
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)
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
        for url in panel.urls where !roots.contains(url) { roots.append(url) }
        save()
    }

    private func save() { Preferences.projectRoots = roots }
}
