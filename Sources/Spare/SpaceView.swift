import SwiftUI
import SpareCore

struct SpaceView: View {
    @ObservedObject var model = SpaceModel.shared
    @ObservedObject var shared = Shared.shared
    @State private var selection: SpaceModel.Entry.ID?
    @State private var confirming: SpaceModel.Entry?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.entries.isEmpty && model.measuring == 0 {
                EmptyNote(symbol: "folder", title: "Nothing in this folder", text: "Or Spare isn't allowed to look inside it.")
            } else {
                List(selection: $selection) {
                    ForEach(model.entries) { entry in
                        SpaceRow(entry: entry, largest: model.largest)
                            .tag(entry.id)
                            .contextMenu { menu(for: entry) }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .scrollIndicators(.never)
                .contextMenu(forSelectionType: SpaceModel.Entry.ID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let entry = model.entries.first(where: { $0.id == id }) { open(entry) }
                }
                .onKeyPress(.return) {
                    guard let id = selection, let entry = model.entries.first(where: { $0.id == id }) else { return .ignored }
                    open(entry); return .handled
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseFolder() } label: { Label("Choose Folder…", systemImage: "folder.badge.plus") }
                    .help("Look at another folder or disk")
                Button { model.reload() } label: { Label("Measure Again", systemImage: "arrow.clockwise") }
                    .disabled(model.measuring > 0)
                    .help("Measure Again")
            }
        }
        .alert(item: $confirming) { entry in
            Alert(title: Text("Move “\(entry.name)” to the Trash?"),
                  message: Text("\(entry.bytes.map(Bytes.text) ?? "It") will be freed once you empty the Trash. History can put it back until then."),
                  primaryButton: .destructive(Text("Move to Trash")) { Task { await model.moveToTrash(entry) } },
                  secondaryButton: .cancel())
        }
        .onAppear { model.startIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(model.trail.enumerated()), id: \.offset) { index, url in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary) }
                    Button { model.go(to: index) } label: {
                        Text(index > 0 ? url.lastPathComponent : url == home ? "Home" : Catalog.tilde(url, home: home))
                            .font(.system(size: 12, weight: index == model.trail.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == model.trail.count - 1 ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == model.trail.count - 1)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.currentBytes.map(Bytes.text) ?? "Measuring…")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.currentBytes)
                Text("in \(FileManager.default.displayName(atPath: model.current.path))").foregroundStyle(.secondary)
                Spacer()
                if model.measuring > 0 {
                    ProgressView().controlSize(.small)
                    Text("\(model.measuring) to go").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            if !shared.fullDiskAccess && model.entries.contains(where: \.locked) {
                FullDiskAccessNote(compact: true)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private func open(_ entry: SpaceModel.Entry) {
        if entry.isFolder && !entry.locked { model.open(entry.url) }
        else if !entry.isFolder { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    }

    @ViewBuilder
    private func menu(for entry: SpaceModel.Entry) -> some View {
        if entry.isFolder && !entry.locked { Button("Open") { model.open(entry.url) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.url.path, forType: .string)
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { confirming = entry }
            .disabled(entry.locked)
    }
}

struct SpaceRow: View {
    let entry: SpaceModel.Entry
    let largest: Int64

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppLookup.icon(for: entry.url, size: 20))
                .frame(width: 20, height: 20)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(entry.locked ? .secondary : .primary)
            if entry.locked {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help("Needs Full Disk Access")
            } else if entry.unreadable > 0 {
                Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help("Some folders inside couldn't be read, so it may be larger.")
            }
            Spacer(minLength: 12)
            bar.frame(width: 160, height: 6)
            Group {
                if entry.bytes == nil && !entry.locked { ProgressView().controlSize(.mini) }
                else { SizeText(bytes: entry.bytes) }
            }
            .frame(width: 80, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary).opacity(entry.isFolder && !entry.locked ? 1 : 0)
        }
        .padding(.vertical, 3)
    }

    private var bar: some View {
        GeometryReader { geometry in
            let fraction = largest > 0 ? CGFloat(Double(entry.bytes ?? 0) / Double(largest)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.75), Color.accentColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(fraction > 0 ? 4 : 0, geometry.size.width * fraction))
            }
        }
    }
}
