import SwiftUI
import SpareCore

extension LaunchItem.Scope {
    var explanation: String {
        switch self {
        case .user: "Runs while you're logged in. Removing one needs no password."
        case .allUsers: "Runs for everyone who logs in to this Mac. Removing one asks for an administrator password."
        case .system: "Runs as the system, even before anyone logs in. Removing one asks for an administrator password."
        case .app: "Registered by the app itself. Switch them off in Login Items settings; they go when the app is uninstalled."
        }
    }
}

struct BackgroundView: View {
    @ObservedObject var model = BackgroundModel.shared
    /// What is waiting for confirmation. One alert for both kinds: a second alert modifier on the same view
    /// silently replaces the first, so Remove did nothing for background items.
    enum Pending: Identifiable {
        case row(BackgroundModel.Row)
        case helper(BackgroundModel.Helper)
        var id: String {
            switch self {
            case .row(let row): "row:" + row.id
            case .helper(let helper): "helper:" + helper.id
            }
        }
    }
    @State private var pending: Pending?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Programs that start on their own: at login, at startup or on a schedule. Removing one stops it for good. Its app may stop updating or syncing, so keep the ones you rely on.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items Settings…") { Permissions.openLoginItemsSettings() }
                        .controlSize(.small)
                }
                if model.loading && model.rows.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
                ForEach(LaunchItem.Scope.allCases, id: \.self) { scope in
                    let rows = model.rows.filter { $0.item.scope == scope }
                    if !rows.isEmpty { section(scope, rows) }
                }
                if !model.helpers.isEmpty { helperSection }
            }
            .padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 90)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.top)
        .toolbar {
            ToolbarItem {
                Button { model.load() } label: { Label("Look Again", systemImage: "arrow.clockwise") }
                    .disabled(model.loading).help("Look Again")
            }
        }
        .alert(item: $pending) { pending in
            switch pending {
            case .row(let row):
                Alert(title: Text("Remove \(row.title)?"),
                      message: Text("It stops now and won't start again. \(row.item.scope == .user ? "" : "macOS asks for an administrator password. ")The file goes to the Trash, and History can put it back."),
                      primaryButton: .destructive(Text("Remove")) { Task { await model.remove(row) } },
                      secondaryButton: .cancel())
            case .helper(let helper):
                Alert(title: Text("Remove \(helper.url.lastPathComponent)?"),
                      message: Text("Nothing starts this helper any more. macOS asks for an administrator password. History can put it back."),
                      primaryButton: .destructive(Text("Remove")) { Task { await model.remove(helper) } },
                      secondaryButton: .cancel())
            }
        }
        .onAppear { model.startIfNeeded() }
    }

    private func section(_ scope: LaunchItem.Scope, _ rows: [BackgroundModel.Row]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scope.rawValue).font(.system(size: 15, weight: .semibold))
                Text(scope.explanation).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Panel {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 56) }
                    BackgroundRow(row: row) { pending = .row(row) }
                }
            }
        }
    }

    private var helperSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Leftover Helper Tools").font(.system(size: 15, weight: .semibold))
                Text("Programs in /Library/PrivilegedHelperTools that no background item starts any more, usually left by an app that was removed.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Panel {
                ForEach(Array(model.helpers.enumerated()), id: \.element.id) { index, helper in
                    if index > 0 { Divider().padding(.leading, 56) }
                    HStack(spacing: 12) {
                        SymbolTile(symbol: "wrench.and.screwdriver", tint: .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(helper.url.lastPathComponent).font(.system(size: 13, weight: .medium))
                            Text(helper.url.path).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        RevealButton(url: helper.url)
                        Button("Remove…") { pending = .helper(helper) }.controlSize(.small)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
    }
}

struct BackgroundRow: View {
    let row: BackgroundModel.Row
    let remove: () -> Void

    private var item: LaunchItem { row.item }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let url = row.ownerURL {
                Image(nsImage: AppLookup.icon(for: url, size: 30)).frame(width: 30, height: 30)
            } else {
                SymbolTile(symbol: item.programExists ? "gearshape.2" : "questionmark.folder", tint: item.programExists ? .secondary : .orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    status
                }
                Text("\(item.programName) · \(item.schedule)\(row.guessed ? " · from the maker of \(row.title)" : "")")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !item.programExists {
                    Label("Left behind: the program it starts is gone.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                } else if let note = item.note {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                if let program = item.program, item.programExists {
                    Button("Show Program in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: program)]) }
                }
                Button("Copy Label") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.label, forType: .string)
                }
                if item.scope == .app {
                    Divider()
                    Button("Open Login Items Settings…") { Permissions.openLoginItemsSettings() }
                } else {
                    Divider()
                    Button("Remove…", role: .destructive, action: remove)
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .help(item.label)
    }

    @ViewBuilder private var status: some View {
        let (text, color): (String, Color) = {
            if let pid = row.status?.pid, pid > 0 { return ("Running", .green) }
            if row.status?.loaded == true { return ("Waiting", .blue) }
            return ("Off", .secondary)
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .help(text == "Running" ? "Running now" : text == "Waiting" ? "Loaded, waiting for its next start" : "Not loaded right now")
    }
}

extension BackgroundModel.Row: Equatable {
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}
