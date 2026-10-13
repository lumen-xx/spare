import SwiftUI
import SpareCore

struct CleanupView: View {
    @ObservedObject var model = CleanupModel.shared
    @ObservedObject var shared = Shared.shared
    @State private var confirming = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if !shared.fullDiskAccess { FullDiskAccessNote() }
                ForEach(Rule.Group.allCases, id: \.self) { group in section(group) }
                footer
            }
            .padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 90)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.top)
        .toolbar {
            ToolbarItem {
                Button { model.scan() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
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
    }

    private var confirmTitle: String {
        let count = model.selectedItems.count
        return "Move \(count == 1 ? "1 item" : "\(count) items") (\(Bytes.text(model.selectedBytes))) to the Trash?"
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isScanning ? "Looking around…" : "Selected to clean")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Text(Bytes.text(model.selectedBytes))
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.selectedBytes)
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                if model.moving { ProgressView().controlSize(.small) }
                Button { confirming = true } label: {
                    Label("Move to Trash…", systemImage: "trash").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selected.isEmpty || model.moving)
                .keyboardShortcut(.delete, modifiers: .command)
            }
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
            HStack(alignment: .firstTextBaseline) {
                Text(group.rawValue).font(.system(size: 15, weight: .semibold))
                if group == .review {
                    Text("Never selected for you").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                SizeText(bytes: model.bytes(in: group), weight: .regular).foregroundStyle(.secondary)
            }
            Panel {
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 { Divider().padding(.leading, 60) }
                    FindingRow(rule: rule)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised").foregroundStyle(.secondary)
            Text("Spare never deletes anything itself. Everything goes to the Trash, and History can put it back. macOS's own files, your documents, photos, mail and messages are never touched. Sizes are space on disk; files shared with other folders through hard links aren't counted as freed.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FindingRow: View {
    let rule: Rule
    @ObservedObject var model = CleanupModel.shared
    @ObservedObject var shared = Shared.shared

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
                SymbolTile(symbol: rule.symbol, tint: empty ? .secondary : rule.safety.color)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(rule.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(empty ? .secondary : .primary)
                        if !empty && !locked { SafetyPill(safety: rule.safety) }
                    }
                    Text(locked ? "Needs Full Disk Access to look." : empty ? "Nothing here." : rule.about)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 14).padding(.vertical, empty || locked ? 10 : 13)
            .contentShape(Rectangle())
            .onTapGesture { if !empty && !locked && !pending { toggleExpanded() } }

            if expanded, let finding, !finding.items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Label(rule.afterwards, systemImage: "arrow.uturn.backward.circle")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    LazyVStack(spacing: 0) {
                        ForEach(finding.items) { item in ItemRow(item: item) }
                    }
                }
                .padding(.leading, 60).padding(.trailing, 14).padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if pending {
            ProgressView().controlSize(.small)
        } else if let finding, !finding.items.isEmpty {
            VStack(alignment: .trailing, spacing: 2) {
                SizeText(bytes: finding.bytes, weight: .semibold)
                Text(selectionText(finding)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { toggleExpanded() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(expanded ? "Hide items" : "Show items")
        }
    }

    private func selectionText(_ finding: Finding) -> String {
        let chosen = finding.items.filter { model.selected.contains($0.id) }.count
        let total = finding.items.count
        if chosen == 0 { return total == 1 ? "1 item" : "\(total) items" }
        return chosen == total ? (total == 1 ? "selected" : "all \(total) selected") : "\(chosen) of \(total) selected"
    }

    private func toggleExpanded() {
        withAnimation(.snappy(duration: 0.22)) {
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
            CheckBox(state: model.selected.contains(item.id) ? .on : .off) { model.toggle(item) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if item.usage.shared > 0 {
                Text("+\(Bytes.text(item.usage.shared)) shared")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .help("Hard-linked from somewhere else too, such as a pnpm store, so moving this copy doesn't free it.")
            }
            if item.usage.unreadable > 0 {
                Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help("Some folders inside couldn't be read, so it may be larger.")
            }
            SizeText(bytes: item.usage.bytes)
            if let first = item.urls.first { RevealButton(url: item.urls.count == 1 ? first : first.deletingLastPathComponent()).opacity(hovering ? 1 : 0.0001) }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.toggle(item) }
        .help(item.urls.count == 1 ? item.urls[0].path : "\(item.urls.count) files in \(item.urls[0].deletingLastPathComponent().path)")
    }
}
