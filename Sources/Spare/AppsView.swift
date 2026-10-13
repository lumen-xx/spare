import SwiftUI
import SpareCore

struct AppsView: View {
    enum Order: String, CaseIterable { case size = "Size", name = "Name", lastOpened = "Last Opened" }

    @ObservedObject var model = AppsModel.shared
    @AppStorage("appsOrder") private var order = Order.size
    @State private var search = ""

    var body: some View {
        installed
            .arrivalStage(replay: model.apps.isEmpty)
            .toolbar {
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
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    SearchField(prompt: "Search apps", text: $search)
                    Menu {
                        Picker("Sort by", selection: $order) { ForEach(Order.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.inline)
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Sort by \(order.rawValue.lowercased())")
                    .accessibilityLabel("Sort by \(order.rawValue.lowercased())")
                }
                .padding(.horizontal, 18).padding(.top, 14)
                .arrives(0)
                TableCard {
                    List(selection: $model.selection) {
                        ForEach(visible) { app in AppRow(app: app, measured: model.measured.contains(app.id)).tag(app.id) }
                    }
                    .listStyle(.inset)
                    .overlay {
                        if model.loading && model.apps.isEmpty {
                            VStack(spacing: 8) { ThinkingDots(); Text("Finding apps").font(.spare(size: 12)).foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(.bottom, 18)
                .arrives(1)
            }
            .frame(width: 350)
            Group {
                if let id = model.selection, let app = model.apps.first(where: { $0.id == id }) {
                    AppDetail(app: app, measured: model.measured.contains(app.id)).id(app.id)
                } else {
                    EmptyState(doodle: .magnifier, title: "Choose an app",
                               text: "Spare shows what it takes up, including the files it keeps in your Library, and can move all of it to the Trash.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .arrives(2)
        }
    }
}

struct AppRow: View {
    let app: InstalledApp
    let measured: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppLookup.icon(for: app.url, size: 30)).frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.spare(size: 13, weight: .medium)).lineLimit(1)
                Text(app.lastUsed.map { "Opened \($0.ago)" } ?? "No opening recorded")
                    .font(.spare(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if measured { SizeText(bytes: app.totalBytes).transition(.opacity) } else { ThinkingDots() }
        }
        .padding(.vertical, 2)
        .animation(Motion.settle, value: measured)
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
        PageScroll(maxWidth: 680, spacing: 22) {
            HStack(spacing: 16) {
                Image(nsImage: AppLookup.icon(for: app.url, size: 64)).frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.spare(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Text([app.version.map { "Version \($0)" }, app.fromAppStore ? "App Store" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.spare(size: 12)).foregroundStyle(.secondary)
                    Text(app.bundleID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
            .arrives(0)
            HStack(spacing: 28) {
                fact("App", measured ? Bytes.text(app.size.bytes) : nil)
                fact("Its files", measured ? Bytes.text(app.dataBytes) : nil)
                fact("Last opened", app.lastUsed?.ago ?? "Not recorded")
            }
            .arrives(1)
            if app.isApple {
                Label("Comes with macOS or from Apple. Spare leaves it alone.", systemImage: "apple.logo")
                    .font(.spare(size: 12.5)).foregroundStyle(.secondary)
                    .arrives(2)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(title: "Goes to the Trash")
                    Card {
                        row(url: app.url, kind: "The app", bytes: app.size.bytes, state: .on, toggle: nil)
                        ForEach(app.leftovers) { leftover in
                            RowDivider().padding(.leading, 42).padding(.trailing, 12)
                            row(url: leftover.url, kind: leftover.kind, bytes: leftover.usage.bytes,
                                state: model.kept.contains(leftover.id) ? .off : .on) {
                                if model.kept.contains(leftover.id) { model.kept.remove(leftover.id) } else { model.kept.insert(leftover.id) }
                            }
                        }
                    }
                    Text(app.leftovers.isEmpty && measured
                         ? "No files of its own were found in your Library."
                         : "Only files named after this app's identifier or its exact name are listed. Shared folders are never included.")
                        .font(.spare(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .arrives(2)
                HStack {
                    Spacer()
                    Button(role: .destructive) { confirming = true } label: {
                        Label("Uninstall \(app.name)…", systemImage: "trash")
                    }
                    .spareButton(.secondary)
                    .controlSize(.large)
                    .disabled(!measured || model.working)
                }
                .arrives(3)
            }
        }
        .alert("Uninstall \(app.name)?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { Task { await model.uninstall(app) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(app.name)\(chosen.isEmpty ? "" : " and \(chosen.count == 1 ? "1 of its files" : "\(chosen.count) of its files")") (\(Bytes.text(chosenBytes))) go to the Trash. \(isOpen ? "Spare quits it first. " : "")History can put everything back.")
        }
    }

    private var isOpen: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty }

    private func fact(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.spare(size: 11)).foregroundStyle(.secondary)
            if let value {
                Text(value).font(.spare(size: 15, weight: .semibold).monospacedDigit()).transition(.opacity)
            } else {
                ThinkingDots().frame(height: 18)
            }
        }
        .animation(Motion.settle, value: value)
        .accessibilityElement(children: .combine)
    }

    private func row(url: URL, kind: String, bytes: Int64, state: CheckState, toggle: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            CheckBox(state: state) { toggle?() }
                .disabled(toggle == nil).opacity(toggle == nil ? 0.5 : 1)
                .accessibilityLabel(kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind).font(.spare(size: 12.5, weight: .medium))
                Text(Catalog.tilde(url, home: home)).font(.spare(size: 11)).foregroundStyle(.secondary)
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
    @Environment(\.reduceMotion) private var reduceMotion

    private var chosenBytes: Int64 { model.orphans.filter { model.orphanSelection.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        Group {
            if (model.orphansLoading || model.loading) && model.orphans.isEmpty {
                VStack(spacing: 10) {
                    ThinkingDots()
                    Text("Looking for leftovers").font(.spare(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.orphans.isEmpty {
                EmptyState(doodle: .sprout, title: "No leftovers", text: "Nothing in your Library is named after an app that's gone.")
            } else {
                PageScroll(maxWidth: 820, spacing: 14) {
                    Text("Files named after apps that are no longer on this Mac. Keep the ones for apps you'll reinstall, or that live on another drive.")
                        .font(.spare(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .arrives(0)
                    Card {
                        selectAllRow
                        ForEach(model.orphans.filter { !$0.forAllUsers }) { orphan in
                            RowDivider().padding(.leading, 42).padding(.trailing, 12)
                            orphanRow(orphan)
                        }
                    }
                    .arrives(1)
                    let everyone = model.orphans.filter(\.forAllUsers)
                    if !everyone.isEmpty {
                        SectionHeading(title: "For Every Account",
                                       subtitle: "In /Library, named after software that isn't on this Mac any more. Removing these asks for an administrator password once.")
                            .padding(.top, 10)
                            .arrives(2)
                        Card {
                            ForEach(Array(everyone.enumerated()), id: \.element.id) { index, orphan in
                                if index > 0 { RowDivider().padding(.leading, 42).padding(.trailing, 12) }
                                orphanRow(orphan)
                            }
                        }
                        .arrives(3)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    FloatingTray {
                        Text(model.orphanSelection.isEmpty ? "Nothing selected" : "\(Bytes.text(chosenBytes)) selected")
                            .font(.spare(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(Motion.count.delay(Beat.tick), value: chosenBytes)
                        Spacer()
                        if model.working { ThinkingDots() }
                        Button { confirming = true } label: { Label("Move to Trash…", systemImage: "trash") }
                            .spareButton(.primary)
                            .disabled(model.orphanSelection.isEmpty || model.working)
                    }
                    .frame(maxWidth: 820)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { model.load() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || model.orphansLoading).help("Look Again")
            }
        }
        .onAppear { model.startIfNeeded() }
        .alert("Move the leftovers of \(model.orphanSelection.count == 1 ? "1 app" : "\(model.orphanSelection.count) apps") to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { Task { await model.removeSelectedOrphans() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(Bytes.text(chosenBytes)).\(model.orphans.contains { $0.forAllUsers && model.orphanSelection.contains($0.id) } ? " Some are shared by every account, so macOS asks for an administrator password once." : "") History can put them back until you empty the Trash.")
        }
    }

    private var allState: CheckState {
        let chosen = model.orphans.filter { model.orphanSelection.contains($0.id) }.count
        return chosen == 0 ? .off : chosen == model.orphans.count ? .on : .mixed
    }

    private var selectAllRow: some View {
        HStack(spacing: 10) {
            CheckBox(state: allState) { toggleAll() }
                .accessibilityLabel("Select all")
            Text(allState == .on ? "All \(model.orphans.count) selected" : "Select all \(model.orphans.count)")
                .font(.spare(size: 12.5, weight: .medium))
            Spacer()
            SizeText(bytes: model.orphanBytes, weight: .regular).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { toggleAll() }
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
                .accessibilityLabel(orphan.bundleID)
                VStack(alignment: .leading, spacing: 2) {
                    Text(orphan.bundleID).font(.system(size: 12.5, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(([Array(Set(orphan.leftovers.map(\.kind))).sorted().joined(separator: ", ")]
                          + [orphan.newest.map { "changed \($0.ago)" }].compactMap { $0 }).joined(separator: " · "))
                        .font(.spare(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                SizeText(bytes: orphan.bytes)
                Button {
                    withAnimation(reduceMotion ? Motion.calm : Motion.expand) {
                        if expanded.contains(orphan.id) { expanded.remove(orphan.id) } else { expanded.insert(orphan.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold))
                        .rotationEffect(.degrees(expanded.contains(orphan.id) ? 90 : 0))
                }
                .spareButton(.icon)
                .controlSize(.small)
                .accessibilityLabel(expanded.contains(orphan.id) ? "Hide files" : "Show files")
            }
            if expanded.contains(orphan.id) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(orphan.leftovers) { leftover in
                        HStack(spacing: 8) {
                            Text(Catalog.tilde(leftover.url, home: home)).font(.spare(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            SizeText(bytes: leftover.usage.bytes)
                            RevealButton(url: leftover.url)
                        }
                    }
                }
                .padding(.leading, 30).padding(.top, 6)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
