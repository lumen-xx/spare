import SwiftUI
import SpareCore

struct CleanupView: View {
    @ObservedObject var model = CleanupModel.shared
    @ObservedObject var shared = Shared.shared
    @State private var confirming = false
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        PageScroll {
            header.arrives(0)
            FullDiskAccessNote().arrives(1)
            ForEach(Array(Rule.Group.allCases.enumerated()), id: \.element) { index, group in
                section(group).arrives(index + 2)
            }
            footer.arrives(Rule.Group.allCases.count + 2)
        }
        .toolbar {
            ToolbarItem {
                Button { Refresh.everything() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                    .disabled(model.isScanning || model.moving)
                    .help("Scan Again (⌘R)")
            }
        }
        .alert(confirmTitle, isPresented: $confirming) {
            Button("Move to Trash") { Task { await model.moveSelectedToTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can put everything back from History until you empty the Trash. The space is freed once the Trash is emptied.")
        }
        .onAppear { model.startIfNeeded() }
        .onChange(of: model.isScanning) { _, scanning in
            guard !scanning, model.scannedAt != nil else { return }
            Feedback.announce("Scan finished. Found \(Bytes.text(model.foundBytes)); \(Bytes.text(model.selectedBytes)) selected.")
        }
    }

    private var confirmTitle: String {
        let count = model.selectedItems.count
        return "Move \(count == 1 ? "1 item" : "\(count) items") (\(Bytes.text(model.selectedBytes))) to the Trash?"
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(model.isScanning ? "Looking around" : model.moving ? "Moving to the Trash" : "Selected to clean")
                        .contentTransition(.opacity)
                    if model.isScanning || model.moving { ThinkingDots().transition(.opacity) }
                }
                .font(.spare(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .animation(Motion.gentle(Motion.settle, reduceMotion: reduceMotion), value: model.isScanning)
                .animation(Motion.gentle(Motion.settle, reduceMotion: reduceMotion), value: model.moving)
                Text(Bytes.text(model.selectedBytes))
                    .font(.spare(size: 46, weight: .bold))
                    .contentTransition(.numericText())
                    .animation(Motion.count.delay(Beat.settle), value: model.selectedBytes)
                Text(summary).font(.spare(size: 12)).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(Motion.settle, value: summary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                if Ask.beforeTrash { confirming = true } else { Task { await model.moveSelectedToTrash() } }
            } label: {
                Label(Ask.trashTitle, systemImage: "trash").padding(.horizontal, 2)
            }
            .spareButton(.primary)
            .controlSize(.large)
            .disabled(model.selected.isEmpty || model.moving)
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private var summary: String {
        if model.isScanning && model.findings.isEmpty { return "Measuring caches, build folders and leftovers." }
        let found = "\(Bytes.text(model.foundBytes)) found"
        guard let date = model.scannedAt else { return found + " so far" }
        return found + " · checked \(date.ago)"
    }

    @ViewBuilder
    private func section(_ group: Rule.Group) -> some View {
        let rules = Catalog.rules.filter { $0.group == group }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: group.rawValue, subtitle: group == .review ? "Never selected for you" : nil) {
                SizeText(bytes: model.bytes(in: group), weight: .regular).foregroundStyle(.secondary)
            }
            Card(hoverRows: true) {
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 { RowDivider().padding(.leading, 62).padding(.trailing, 14) }
                    FindingRow(rule: rule)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised").foregroundStyle(.secondary)
            Text("Spare never deletes anything itself. Everything goes to the Trash, and History can put it back. macOS's own files, your documents, photos, mail and messages are never touched. Sizes are space on disk; files shared with other folders through hard links aren't counted as freed.")
                .font(.spare(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

struct FindingRow: View {
    let rule: Rule
    @ObservedObject var model = CleanupModel.shared
    @ObservedObject var shared = Shared.shared
    @Environment(\.reduceMotion) private var reduceMotion

    private var finding: Finding? { model.findings[rule.id] }
    private var locked: Bool { rule.needsFullDiskAccess && !shared.fullDiskAccess }
    private var pending: Bool { model.pending.contains(rule.id) }
    private var empty: Bool { !pending && !locked && (finding?.items.isEmpty ?? true) }
    private var expanded: Bool { model.expanded.contains(rule.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                CheckBox(state: model.state(finding)) { if let finding { model.toggle(finding) } }
                    .disabled(empty || locked || pending)
                    .opacity(empty || locked ? 0.35 : 1)
                    .accessibilityLabel(rule.title)
                SymbolTile(symbol: rule.symbol, tint: empty ? .secondary : rule.safety.color)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(rule.title).font(.spare(size: 13, weight: .semibold))
                            .foregroundStyle(empty ? .secondary : .primary)
                        if !empty && !locked && !pending { SafetyPill(safety: rule.safety).transition(.opacity) }
                    }
                    Text(locked ? "Needs Full Disk Access to look." : empty ? "Nothing here." : rule.about)
                        .font(.spare(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 11).padding(.vertical, empty || locked ? 8 : 11)
            .contentShape(Rectangle())
            .hoverWash()
            .onTapGesture { if !empty && !locked && !pending { toggleExpanded() } }
            .padding(.horizontal, RowWash.inset).padding(.vertical, 1)

            if expanded, let finding, !finding.items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Label(rule.afterwards, systemImage: "arrow.uturn.backward.circle")
                        .font(.spare(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    LazyVStack(spacing: 0) {
                        ForEach(finding.items) { item in ItemRow(item: item) }
                    }
                }
                .padding(.leading, 62).padding(.trailing, 14).padding(.bottom, 12)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
            }
        }
        // A rule that finishes looking settles from the dots into its result, a beat later and each at its own pace.
        .animation(reduceMotion ? Motion.calm : Motion.varied(Motion.settle, Int(truncatingIfNeeded: Jitter.seed(rule.id))).delay(Beat.settle),
                   value: pending)
    }

    @ViewBuilder private var trailing: some View {
        if pending {
            ThinkingDots().transition(.opacity)
        } else if let finding, !finding.items.isEmpty {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    SizeText(bytes: finding.bytes, weight: .semibold)
                    Text(selectionText(finding)).font(.spare(size: 11)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.count.delay(Beat.tick), value: selectionText(finding))
                }
                Button { toggleExpanded() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .spareButton(.icon)
                .controlSize(.small)
                .help(expanded ? "Hide items" : "Show items")
                .accessibilityLabel(expanded ? "Hide items" : "Show items")
            }
            .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 6)))
        }
    }

    private func selectionText(_ finding: Finding) -> String {
        let chosen = finding.items.filter { model.selected.contains($0.id) }.count
        let total = finding.items.count
        if chosen == 0 { return total == 1 ? "1 item" : "\(total) items" }
        return chosen == total ? (total == 1 ? "selected" : "all \(total) selected") : "\(chosen) of \(total) selected"
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? Motion.calm : Motion.expand) {
            if expanded { model.expanded.remove(rule.id) } else { model.expanded.insert(rule.id) }
        }
    }
}

struct ItemRow: View {
    let item: Item
    @ObservedObject var model = CleanupModel.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(state: model.selected.contains(item.id) && item.inUseBy == nil ? .on : .off) { model.toggle(item) }
                .disabled(item.inUseBy != nil).opacity(item.inUseBy == nil ? 1 : 0.35)
                .accessibilityLabel(item.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.spare(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(item.inUseBy == nil ? .primary : .secondary)
                if let user = item.inUseBy {
                    Text("In use by \(user) right now. Quit it to clean this.")
                        .font(.spare(size: 11)).foregroundStyle(Ink.warm).lineLimit(1)
                } else if let detail = item.detail {
                    Text(detail).font(.spare(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if item.usage.shared > 0 {
                Text("+\(Bytes.text(item.usage.shared)) shared")
                    .font(.spare(size: 11)).foregroundStyle(.tertiary)
                    .help("Hard-linked from somewhere else too, such as a pnpm store, so moving this copy doesn't free it.")
            }
            if item.usage.unreadable > 0 {
                Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help("Some folders inside couldn't be read, so it may be larger.")
                    .accessibilityLabel("Partly unreadable")
            }
            SizeText(bytes: item.usage.bytes)
            if let first = item.urls.first {
                RevealButton(url: item.urls.count == 1 ? first : first.deletingLastPathComponent())
                    .opacity(hovering ? 1 : 0.0001)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .contentShape(Rectangle())
        .hoverWash(radius: 7)
        .hoverLag($hovering)
        .onTapGesture { model.toggle(item) }
        .fileMenu(item.urls)
        .padding(.horizontal, -6)
        .help(item.urls.count == 1 ? item.urls[0].path : "\(item.urls.count) files in \(item.urls[0].deletingLastPathComponent().path)")
    }
}
