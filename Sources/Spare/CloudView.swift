import SwiftUI
import UniformTypeIdentifiers
import SpareCore

/// Files iCloud Drive and other cloud apps downloaded to this Mac while keeping them online. Removing a download, as
/// Finder's Remove Download does, leaves the file in the cloud and in its folder; it downloads again when opened.
@MainActor
final class CloudModel: ObservableObject {
    static let shared = CloudModel()
    @Published private(set) var providers: [CloudDownloads.Provider] = []
    @Published private(set) var loading = false
    /// The provider or folder whose downloads are being removed.
    @Published private(set) var removing: String?
    private var started = false
    private var cancel = Cancellation()

    func startIfNeeded() { if !started { load() } }
    func reloadIfStarted() { if started { load() } }

    var total: Int64 { providers.reduce(0) { $0 + $1.bytes } }
    var complete: Bool { providers.allSatisfy(\.complete) }

    func load() {
        #if DEBUG
        if Demo.isOn { return }
        #endif
        started = true
        loading = true
        cancel.cancel()
        let cancel = Cancellation()
        self.cancel = cancel
        Task {
            let found = await background { CloudDownloads.scan(home: home, cancel: cancel) }
            guard !cancel.isCancelled else { return }
            self.providers = found
            self.loading = false
        }
    }

    /// Removes the downloads under `url`, then says what came back and what stayed, and why.
    func removeDownloads(_ name: String, at url: URL, id: String) {
        guard removing == nil else { return }
        #if DEBUG
        if Demo.isOn { Demo.pretend("Spare would have removed these downloads."); return }
        #endif
        removing = id
        Task {
            let removal = await background { CloudDownloads.removeDownloads(under: url, cancel: Cancellation()) }
            removing = nil
            if removal.files > 0 {
                Shared.shared.banner = .init(title: "Removed \(Bytes.text(removal.bytes)) of downloads",
                                             detail: "\(name) is still online and downloads again when you open it.",
                                             problems: removal.problems)
            } else {
                Shared.shared.banner = .init(title: "Nothing was removed from \(name)",
                                             detail: removal.problems.first ?? "Its files are already online only.",
                                             problems: removal.problems.count > 1 ? removal.problems : [], failed: !removal.problems.isEmpty)
            }
            Shared.shared.refreshSpace()
            load()
        }
    }

    #if DEBUG
    func showDemo(_ demo: [CloudDownloads.Provider]) {
        started = true
        providers = demo
    }
    #endif
}

struct CloudView: View {
    @ObservedObject var model = CloudModel.shared
    @State private var confirming: Target?
    @Environment(\.reduceMotion) private var reduceMotion

    /// What a removal is about to touch, for the confirmation.
    struct Target: Identifiable {
        let id: String
        let name: String
        let provider: String
        let url: URL
        let bytes: Int64
    }

    var body: some View {
        Group {
            if model.providers.isEmpty && !model.loading {
                EmptyState(doodle: .cloud, title: "Nothing downloaded from the cloud",
                           text: "When iCloud Drive, OneDrive, Google Drive or Dropbox keep a downloaded copy of a file that's also online, it's listed here. Files you chose to keep on this Mac never are.")
            } else {
                PageScroll(replay: model.providers.isEmpty) {
                    header.arrives(0)
                    ForEach(Array(model.providers.enumerated()), id: \.element.id) { index, provider in
                        section(provider).arrives(index + 1)
                    }
                    Text("Only files that are fully uploaded and have no conflicts are removed. Removing a download is what Finder's Remove Download does: the file keeps its place, and you need to be online to open it again.")
                        .font(.spare(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .arrives(model.providers.count + 1)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Refresh.everything() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || model.removing != nil).help("Look Again")
            }
        }
        .alert(item: $confirming) { target in
            Alert(title: Text("Remove the downloads in “\(target.name)”?"),
                  message: Text("\(Bytes.text(target.bytes)) comes back. The files stay in \(target.provider) and in their folders, and download again when you open them."),
                  primaryButton: .default(Text("Remove Downloads")) { model.removeDownloads(target.name, at: target.url, id: target.id) },
                  secondaryButton: .cancel())
        }
        .onAppear { model.startIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(model.loading ? "Looking through cloud folders" : model.removing != nil ? "Removing downloads" : "Downloaded, and also online")
                    .contentTransition(.opacity)
                if model.loading || model.removing != nil { ThinkingDots().transition(.opacity) }
            }
            .font(.spare(size: 13, weight: .medium)).foregroundStyle(.secondary)
            .animation(Motion.gentle(Motion.settle, reduceMotion: reduceMotion), value: model.loading)
            Text((model.complete ? "" : "At least ") + Bytes.text(model.total))
                .font(.spare(size: 46, weight: .bold))
                .contentTransition(.numericText())
                .animation(Motion.count.delay(Beat.settle), value: model.total)
            Text(model.complete ? "Remove a download to get its space back. The file stays in the cloud."
                                : "Some folders took too long to count, so there may be more.")
                .font(.spare(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func section(_ provider: CloudDownloads.Provider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: provider.name,
                           subtitle: "\(provider.files == 1 ? "1 file" : "\(provider.files.formatted()) files") downloaded") {
                HStack(spacing: 10) {
                    SizeText(bytes: provider.bytes, weight: .regular).foregroundStyle(.secondary)
                    if model.removing == provider.id { ThinkingDots() }
                    Button("Remove All…") {
                        confirming = Target(id: provider.id, name: provider.name, provider: provider.name, url: provider.root, bytes: provider.bytes)
                    }
                    .spareButton(.secondary)
                    .controlSize(.small)
                    .disabled(model.removing != nil)
                }
            }
            if !provider.places.isEmpty {
                Card(hoverRows: true) {
                    ForEach(Array(provider.places.prefix(12).enumerated()), id: \.element.id) { index, place in
                        if index > 0 { RowDivider().padding(.leading, 44).padding(.trailing, 12) }
                        PlaceRow(place: place, provider: provider.name, largest: provider.places.first?.bytes ?? 1) {
                            confirming = Target(id: place.id, name: place.name, provider: provider.name, url: place.url, bytes: place.bytes)
                        }
                    }
                }
            }
        }
    }
}

private struct PlaceRow: View {
    let place: CloudDownloads.Place
    let provider: String
    let largest: Int64
    let remove: () -> Void
    @ObservedObject var model = CloudModel.shared
    @State private var hovering = false

    /// The folder's own icon, such as an app's for its iCloud folder; a plain folder when it can't be read.
    private var icon: NSImage {
        FileManager.default.fileExists(atPath: place.url.path) ? AppLookup.icon(for: place.url, size: 20) : NSWorkspace.shared.icon(for: .folder)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(place.name).font(.spare(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(place.files == 1 ? "1 file" : "\(place.files.formatted()) files").font(.spare(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            UsageBar(fraction: Double(place.bytes) / Double(max(largest, 1))).frame(width: 110)
            SizeText(bytes: place.bytes).frame(width: 70, alignment: .trailing)
            if model.removing == place.id {
                ThinkingDots().frame(width: 64)
            } else {
                Button("Remove…", action: remove)
                    .spareButton(.quiet)
                    .controlSize(.small)
                    .disabled(model.removing != nil)
                    .opacity(hovering ? 1 : 0.0001)
                    .accessibilityLabel("Remove downloads in \(place.name)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
        .hoverWash()
        .hoverLag($hovering)
        .padding(.horizontal, RowWash.inset).padding(.vertical, 1)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([place.url]) }
            Button("Remove Downloads…", action: remove)
        }
    }
}
