import SwiftUI
import SpareCore

struct AppsView: View {
    enum Mode: String, CaseIterable { case installed = "Installed", leftovers = "Leftovers" }
    enum Order: String, CaseIterable { case size = "Size", name = "Name", lastOpened = "Last Opened" }

    @ObservedObject var model = AppsModel.shared
    @AppStorage("appsMode") private var mode = Mode.installed
    @AppStorage("appsOrder") private var order = Order.size
    @State private var search = ""

    var body: some View {
        Group {
            switch mode {
            case .installed: installed
            case .leftovers: LeftoversView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $mode) {
                    Text("Installed").tag(Mode.installed)
                    Text(model.orphans.isEmpty ? "Leftovers" : "Leftovers (\(Bytes.text(model.orphanBytes)))").tag(Mode.leftovers)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem {
                Button { model.load() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || model.orphansLoading)
                    .help("Look Again")
            }
        }
        .onAppear { model.startIfNeeded() }
    }

    private var visible: [InstalledApp] {
        let filtered = search.isEmpty ? model.apps : model.apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
        switch order {
        case .name: return filtered
        case .size: return filtered.sorted { $0.totalBytes > $1.totalBytes }
        case .lastOpened: return filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    private var installed: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps", text: $search).textFieldStyle(.plain)
                    Menu {
                        Picker("Sort by", selection: $order) { ForEach(Order.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.inline)
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Sort by \(order.rawValue.lowercased())")
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(12)
                List(selection: $model.selection) {
                    ForEach(visible) { app in AppRow(app: app, measured: model.measured.contains(app.id)).tag(app.id) }
                }
                .listStyle(.inset)
                .scrollIndicators(.never)
                .overlay { if model.loading && model.apps.isEmpty { ProgressView() } }
            }
            .frame(width: 330)
            Divider()
            Group {
                if let id = model.selection, let app = model.apps.first(where: { $0.id == id }) {
                    AppDetail(app: app, measured: model.measured.contains(app.id))
                } else {
                    EmptyNote(symbol: "app.dashed", title: "Choose an app",
                              text: "Spare shows what it takes up, including the files it keeps in your Library, and can move all of it to the Trash.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AppRow: View {
    let app: InstalledApp
    let measured: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppLookup.icon(for: app.url, size: 30)).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(app.lastUsed.map { "Opened \($0.ago)" } ?? "No opening recorded")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if measured { SizeText(bytes: app.totalBytes) } else { ProgressView().controlSize(.mini) }
        }
        .padding(.vertical, 2)
    }
}

struct AppDetail: View {
    let app: InstalledApp
    let measured: Bool
    @ObservedObject var model = AppsModel.shared
    @State private var confirming = false

    private var chosen: [Leftover] { app.leftovers.filter { !model.kept.contains($0.id) } }
    private var chosenBytes: Int64 { app.size.bytes + chosen.reduce(0) { $0 + $1.usage.bytes } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image(nsImage: AppLookup.icon(for: app.url, size: 64)).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.system(size: 22, weight: .bold))
                        Text([app.version.map { "Version \($0)" }, app.fromAppStore ? "App Store" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(app.bundleID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                HStack(spacing: 28) {
                    fact("App", measured ? Bytes.text(app.size.bytes) : "…")
                    fact("Its files", measured ? Bytes.text(app.dataBytes) : "…")
                    fact("Last opened", app.lastUsed?.ago ?? "Not recorded")
                }
                if app.isApple {
                    Label("Comes with macOS or from Apple. Spare leaves it alone.", systemImage: "apple.logo")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Goes to the Trash").font(.system(size: 14, weight: .semibold))
                        Panel {
                            row(url: app.url, kind: "The app", bytes: app.size.bytes, state: .on, toggle: nil)
                            ForEach(app.leftovers) { leftover in
                                Divider().padding(.leading, 40)
                                row(url: leftover.url, kind: leftover.kind, bytes: leftover.usage.bytes,
                                    state: model.kept.contains(leftover.id) ? .off : .on) {
                                    if model.kept.contains(leftover.id) { model.kept.remove(leftover.id) } else { model.kept.insert(leftover.id) }
                                }
                            }
                        }
                        Text(app.leftovers.isEmpty && measured
                             ? "No files of its own were found in your Library."
                             : "Only files named after this app's identifier or its exact name are listed. Shared folders are never included.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button(role: .destructive) { confirming = true } label: {
                            Label("Uninstall \(app.name)…", systemImage: "trash").padding(.horizontal, 4)
                        }
                        .controlSize(.large)
                        .disabled(!measured || model.working)
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .alert("Uninstall \(app.name)?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { Task { await model.uninstall(app) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(app.name)\(chosen.isEmpty ? "" : " and \(chosen.count == 1 ? "1 of its files" : "\(chosen.count) of its files")") (\(Bytes.text(chosenBytes))) go to the Trash. \(isOpen ? "Spare quits it first. " : "")History can put everything back.")
        }
    }

    private var isOpen: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
        }
    }

    private func row(url: URL, kind: String, bytes: Int64, state: CheckState, toggle: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            CheckBox(state: state) { toggle?() }.disabled(toggle == nil).opacity(toggle == nil ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind).font(.system(size: 12.5, weight: .medium))
                Text(Catalog.tilde(url, home: home)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            SizeText(bytes: bytes)
            RevealButton(url: url)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct LeftoversView: View {
    @ObservedObject var model = AppsModel.shared
    @State private var expanded: Set<String> = []
    @State private var confirming = false

    private var chosenBytes: Int64 { model.orphans.filter { model.orphanSelection.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 0) {
            if model.orphansLoading && model.orphans.isEmpty {
                ProgressView("Looking for leftovers…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.orphans.isEmpty {
                EmptyNote(symbol: "checkmark.seal", title: "No leftovers",
                          text: "Nothing in your Library is named after an app that's gone.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Files named after apps that are no longer on this Mac. Keep the ones for apps you'll reinstall, or that live on another drive.")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Panel {
                            selectAllRow
                            ForEach(model.orphans) { orphan in
                                Divider().padding(.leading, 40)
                                orphanRow(orphan)
                            }
                        }
                    }
                    .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 90)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text(model.orphanSelection.isEmpty ? "Nothing selected" : "\(Bytes.text(chosenBytes)) selected")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button { confirming = true } label: { Label("Move to Trash…", systemImage: "trash") }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.orphanSelection.isEmpty || model.working)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .modifier(FloatingSurface())
                    .padding(.horizontal, 20).padding(.bottom, 14)
                    .frame(maxWidth: 820)
                }
            }
        }
        .alert("Move the leftovers of \(model.orphanSelection.count == 1 ? "1 app" : "\(model.orphanSelection.count) apps") to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { Task { await model.removeSelectedOrphans() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(Bytes.text(chosenBytes)). History can put them back until you empty the Trash.")
        }
    }

    private var allState: CheckState {
        let chosen = model.orphans.filter { model.orphanSelection.contains($0.id) }.count
        return chosen == 0 ? .off : chosen == model.orphans.count ? .on : .mixed
    }

    private var selectAllRow: some View {
        HStack(spacing: 10) {
            CheckBox(state: allState) { toggleAll() }
            Text(allState == .on ? "All \(model.orphans.count) selected" : "Select all \(model.orphans.count)")
                .font(.system(size: 12.5, weight: .medium))
            Spacer()
            SizeText(bytes: model.orphanBytes, weight: .regular).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { toggleAll() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func toggleAll() {
        model.orphanSelection = allState == .on ? [] : Set(model.orphans.map(\.id))
    }

    private func orphanRow(_ orphan: Orphan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                CheckBox(state: model.orphanSelection.contains(orphan.id) ? .on : .off) {
                    if model.orphanSelection.contains(orphan.id) { model.orphanSelection.remove(orphan.id) } else { model.orphanSelection.insert(orphan.id) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(orphan.bundleID).font(.system(size: 12.5, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(([Array(Set(orphan.leftovers.map(\.kind))).sorted().joined(separator: ", ")]
                          + [orphan.newest.map { "changed \($0.ago)" }].compactMap { $0 }).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                SizeText(bytes: orphan.bytes)
                Button {
                    if expanded.contains(orphan.id) { expanded.remove(orphan.id) } else { expanded.insert(orphan.id) }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expanded.contains(orphan.id) ? 90 : 0))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if expanded.contains(orphan.id) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(orphan.leftovers) { leftover in
                        HStack(spacing: 8) {
                            Text(Catalog.tilde(leftover.url, home: home)).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            SizeText(bytes: leftover.usage.bytes)
                            RevealButton(url: leftover.url)
                        }
                    }
                }
                .padding(.leading, 28).padding(.top, 6)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
