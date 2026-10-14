import SwiftUI
import SpareCore

/// What Spare changed under Privacy & Debloat, as a list to tick: undone now, or before Spare uninstalls itself.
struct UndoSheet: View {
    enum Purpose { case undo, uninstall }

    let purpose: Purpose
    /// Runs after the sheet closes, with what was ticked.
    let finish: (Set<DebloatModel.UndoItem>) -> Void
    @ObservedObject var model = DebloatModel.shared
    @State private var chosen: Set<DebloatModel.UndoItem>
    /// Set once the person ticks or unticks something; until then everything that turns up is ticked.
    @State private var touched = false
    @Environment(\.dismiss) private var dismiss

    init(purpose: Purpose, finish: @escaping (Set<DebloatModel.UndoItem>) -> Void) {
        self.purpose = purpose
        self.finish = finish
        _chosen = State(initialValue: Set(DebloatModel.shared.undoItems))
    }

    private var items: [DebloatModel.UndoItem] { model.undoItems }
    /// Until Spare has looked, the list may be missing things; nothing can go ahead before then.
    private var looking: Bool { model.undoable == nil }
    /// What's ticked of what's listed now, as the list can change while the sheet is open.
    private var picked: Set<DebloatModel.UndoItem> { chosen.intersection(items) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SymbolTile(symbol: purpose == .undo ? "arrow.uturn.backward" : "trash", tint: purpose == .undo ? Ink.ink : Ink.brick, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(purpose == .undo ? "Undo what Spare changed" : "Uninstall Spare").font(.spare(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(purpose == .undo ? "Tick what to put back." : "Tick what to put back first. What you leave unticked stays as it is.")
                        .font(.spare(size: 12)).foregroundStyle(.secondary)
                }
            }
            if looking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at what Spare changed…").font(.spare(size: 12.5)).foregroundStyle(.secondary)
                }
            } else if items.isEmpty {
                Text("Spare hasn't changed anything under Privacy & Debloat, so there's nothing to undo.")
                    .font(.spare(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        CheckBox(state: picked.isEmpty ? .off : picked.count == items.count ? .on : .mixed) {
                            touched = true
                            chosen = picked.count == items.count ? [] : Set(items)
                        }
                        .accessibilityLabel("Select All")
                        Text("Select All").font(.spare(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 12)
                    ScrollView {
                        Card {
                            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                                if index > 0 { RowDivider().padding(.horizontal, 12) }
                                row(item)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if purpose == .uninstall {
                Text("Then Spare and its files go to the Trash and Spare quits. Apple apps left blocked would need Terminal to open again.")
                    .font(.spare(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.spareButton(.secondary).keyboardShortcut(.cancelAction)
                Button(primaryTitle) {
                    let picked = picked
                    dismiss()
                    finish(picked)
                }
                .spareButton(.primary).keyboardShortcut(.defaultAction)
                .disabled(looking || (purpose == .undo && picked.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(PaperBackground())
        // The list may still be read when the sheet opens.
        .onChange(of: items) { _, items in if !touched { chosen = Set(items) } }
        .onAppear { if !touched { chosen = Set(items) } }
    }

    private var primaryTitle: String {
        let count = picked.count == 1 ? "1 Change" : "\(picked.count) Changes"
        switch purpose {
        case .undo: return "Undo \(count)"
        case .uninstall: return picked.isEmpty ? "Uninstall" : "Undo \(count) and Uninstall"
        }
    }

    private func row(_ item: DebloatModel.UndoItem) -> some View {
        let toggle = {
            touched = true
            if chosen.contains(item) { chosen.remove(item) } else { chosen.insert(item) }
        }
        return HStack(spacing: 10) {
            CheckBox(state: chosen.contains(item) ? .on : .off, action: toggle).accessibilityLabel(item.title)
            Image(systemName: item.kind == .profile ? "checkmark.shield" : item.kind == .app ? "app.badge.checkmark" : "slider.horizontal.3")
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.spare(size: 12.5, weight: .medium))
                Text(item.detail).font(.spare(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
