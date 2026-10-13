import SwiftUI
import SpareCore

@main
enum Entry {
    static func main() {
        // A plain-text report of what a cleanup would find, for checking Spare from Terminal. It only reads.
        if CommandLine.arguments.contains("--report") { Report.run(); exit(0) }
        SpareApp.main()
    }
}

struct SpareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Spare", id: "main") {
            ContentView()
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.check() }
                    .disabled(!Updates.shared.available)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan Again") { CleanupModel.shared.scan() }.keyboardShortcut("r")
                Divider()
                Button("Empty Trash…") { Shared.shared.emptyTrash() }.keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
        }
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Updates.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Coming back from System Settings may mean Full Disk Access changed, and the disk certainly may have.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { Shared.shared.refreshSpace() }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case cleanup = "Cleanup", space = "Space", apps = "Apps", background = "Background Items", history = "History"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .cleanup: "sparkles"
        case .space: "chart.bar.doc.horizontal"
        case .apps: "app.dashed"
        case .background: "gearshape.2"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct ContentView: View {
    @AppStorage("section") private var section = Page.cleanup
    @ObservedObject private var shared = Shared.shared
    @ObservedObject private var cleanup = CleanupModel.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { section }, set: { if let value = $0 { section = value } })) {
                ForEach(Page.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol)
                        .badge(badge(for: item))
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) { DiskSummary().padding(14) }
        } detail: {
            Group {
                switch section {
                case .cleanup: CleanupView()
                case .space: SpaceView()
                case .apps: AppsView()
                case .background: BackgroundView()
                case .history: HistoryView()
                }
            }
            .navigationTitle(section.rawValue)
        }
        .overlay(alignment: .bottom) {
            BannerView().animation(.snappy, value: shared.banner)
        }
    }

    private func badge(for item: Page) -> Text? {
        guard item == .cleanup, !cleanup.isScanning, cleanup.scannedAt != nil, cleanup.foundBytes > 0 else { return nil }
        return Text(Bytes.text(cleanup.foundBytes))
    }
}

/// The disk at a glance, under the sidebar.
struct DiskSummary: View {
    @ObservedObject var shared = Shared.shared

    var body: some View {
        if let space = shared.space {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary)
                    Text(shared.volumeName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                GeometryReader { geometry in
                    let used = space.total > 0 ? CGFloat(Double(space.used) / Double(space.total)) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.09))
                        Capsule().fill(used > 0.9 ? Color.orange : Color.accentColor).frame(width: geometry.size.width * used)
                    }
                }
                .frame(height: 6)
                Text("\(Bytes.text(space.free)) free of \(Bytes.text(space.total))")
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                if space.purgeable > 1_000_000_000 {
                    Text("+ \(Bytes.text(space.purgeable)) macOS can clear itself")
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
                        .help("Purgeable space: local Time Machine snapshots, iCloud files that are also online, and caches macOS manages. macOS removes them on its own when it needs room.")
                }
                if let trash = shared.trashBytes, trash > 0 {
                    HStack {
                        Text("Trash: \(Bytes.text(trash))").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Empty…") { shared.emptyTrash() }.buttonStyle(.borderless).font(.system(size: 11))
                    }
                }
            }
        }
    }
}

/// Prints what Spare would find, without changing anything.
enum Report {
    static func run() {
        let fullDiskAccess = Permissions.fullDiskAccess()
        let context = ScanContext(home: home, projectRoots: Preferences.projectRoots, inactiveAfter: Double(Preferences.inactiveDays) * 86_400,
                                  fullDiskAccess: fullDiskAccess,
                                  appName: { folder in Apps.identifier(in: folder).flatMap { AppLookup.name(for: $0) } },
                                  isOpen: AppLookup.openCheck())
        let started = Date()
        print("Full Disk Access: \(fullDiskAccess ? "yes" : "no")")
        print("Project folders: \(context.projectRoots.map { Catalog.tilde($0, home: home) }.joined(separator: ", "))")
        var total: Int64 = 0, suggested: Int64 = 0
        for rule in Catalog.rules where fullDiskAccess || !rule.needsFullDiskAccess {
            let ruleStart = Date()
            let items = rule.find(context, Cancellation()).sorted { $0.usage.bytes > $1.usage.bytes }
            let bytes = items.reduce(Int64(0)) { $0 + $1.usage.bytes }
            total += bytes
            if rule.safety != .review { suggested += items.filter(\.suggested).reduce(0) { $0 + $1.usage.bytes } }
            print("\n\(rule.title): \(Bytes.text(bytes)) in \(items.count) (\(String(format: "%.1f", Date().timeIntervalSince(ruleStart))) s)")
            for item in items.prefix(8) {
                print("  \(item.suggested ? "[x]" : "[ ]") \(Bytes.text(item.usage.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.label)\(item.detail.map { " — " + $0 } ?? "")\(item.usage.shared > 0 ? " (+\(Bytes.text(item.usage.shared)) shared)" : "")")
            }
            if items.count > 8 { print("  … and \(items.count - 8) more") }
        }
        print("\nFound \(Bytes.text(total)); selected by default \(Bytes.text(suggested)). Took \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
    }
}
