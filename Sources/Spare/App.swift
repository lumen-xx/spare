import SwiftUI
import SpareCore

@main
enum Entry {
    static func main() {
        // A plain-text report of what a cleanup would find, for checking Spare from Terminal. It only reads.
        if CommandLine.arguments.contains("--report") { Report.run(); exit(0) }
        if CommandLine.arguments.contains("--inventory") { Report.inventory(); exit(0) }
        #if DEBUG
        // Checks that commands and their arguments reach the session script intact, without asking for a password.
        if CommandLine.arguments.contains("--check-privileged") {
            MainActor.assumeIsolated {
                let first = Privileged.call("printf '%s' \"it's $((20 + 22))\"", prompt: "unused", privileged: false)
                let second = Privileged.call("printf second", prompt: "unused", privileged: false)
                print(first.output == "it's 42" && second.output == "second" ? "PASS session script runs commands" : "FAIL \(first) \(second)")
            }
            exit(0)
        }
        #endif
        SpareApp.main()
    }
}

struct SpareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        #if DEBUG
        // Sample data goes in before any window exists, so no page starts reading the Mac.
        if Demo.isOn { MainActor.assumeIsolated { Demo.show() } }
        #endif
    }

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
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { Navigation.shared.page = .settings }.keyboardShortcut(",")
            }
            CommandMenu("Scan") {
                Button("Scan Again") { CleanupModel.shared.scan() }.keyboardShortcut("r")
                Divider()
                Button("Empty Trash…") { Shared.shared.emptyTrash() }.keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Updates.shared.start() }
        #if DEBUG
        // Shows a sample message, to check how messages look and leave.
        if UserDefaults.standard.bool(forKey: "previewBanner") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Shared.shared.banner = .init(title: "The Trash wasn't emptied", detail: "Sample message", failed: true)
            }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Coming back from System Settings may mean Full Disk Access changed, and the disk certainly may have.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { Shared.shared.refreshSpace() }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case cleanup = "Cleanup", space = "Space", snapshots = "Snapshots", macOSDownloads = "macOS Downloads"
    case apps = "Apps", leftovers = "Leftovers", packages = "Packages", toolchains = "Toolchains", commandLineTools = "Command-Line Tools"
    case loginItems = "Login Items", background = "Background Items"
    case systemExtensions = "System Extensions", drivers = "Drivers", plugIns = "Plug-ins", fonts = "Fonts", inputMethods = "Input Methods"
    case installerPackages = "Installer Packages", searchPaths = "Search Paths"
    case accounts = "Accounts", printers = "Printers", vpn = "VPN", profiles = "Profiles", privacy = "Privacy"
    case hiddenItems = "Hidden Items", sharedFolder = "Shared Folder"
    case history = "History", settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .cleanup: "sparkles"
        case .space: "chart.bar.doc.horizontal"
        case .snapshots: "clock.badge.checkmark"
        case .macOSDownloads: "arrow.down.app"
        case .apps: "app.dashed"
        case .leftovers: "tray.full"
        case .packages: "shippingbox"
        case .toolchains: "hammer"
        case .commandLineTools: "terminal"
        case .loginItems: "power"
        case .background: "gearshape.2"
        case .systemExtensions: "puzzlepiece.extension"
        case .drivers: "cpu"
        case .plugIns: "powerplug"
        case .fonts: "textformat"
        case .inputMethods: "keyboard"
        case .installerPackages: "archivebox"
        case .searchPaths: "point.topleft.down.to.point.bottomright.curvepath"
        case .accounts: "person.2"
        case .printers: "printer"
        case .vpn: "network.badge.shield.half.filled"
        case .profiles: "checkmark.shield"
        case .privacy: "hand.raised"
        case .hiddenItems: "eye.slash"
        case .sharedFolder: "folder.badge.person.crop"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    static let sections: [(String, [Page])] = [
        ("Free Up Space", [.cleanup, .space, .snapshots, .macOSDownloads]),
        ("Apps & Software", [.apps, .leftovers, .packages, .toolchains, .commandLineTools]),
        ("Startup", [.loginItems, .background]),
        ("System Additions", [.systemExtensions, .drivers, .plugIns, .fonts, .inputMethods, .installerPackages, .searchPaths]),
        ("System Changes", [.accounts, .printers, .vpn, .profiles, .privacy]),
        ("Home Folder", [.hiddenItems, .sharedFolder])
    ]

    /// Kinds of drivers and extensions each System Additions page shows.
    var extensionCategories: [Extension.Category] {
        switch self {
        case .systemExtensions: [.system]
        case .drivers: [.kernel, .audioDrivers, .camera, .printers]
        case .plugIns: [.audioPlugIns, .quickLook, .internet, .panes, .screenSavers, .services, .colorPickers]
        case .fonts: [.fonts]
        case .inputMethods: [.input]
        case .installerPackages: [.receipts]
        case .searchPaths: [.searchPaths]
        default: []
        }
    }
}

/// Which page is showing, shared so menu commands such as Settings… can switch it.
@MainActor
final class Navigation: ObservableObject {
    static let shared = Navigation()
    // Plain published state saved on change: an @AppStorage selection could stop updating the detail column after
    // the preference changed outside the app. `-section Apps` on the command line still picks the first page.
    @Published var page = Page(rawValue: UserDefaults.standard.string(forKey: "section") ?? "") ?? .cleanup {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "section") }
    }
}

struct ContentView: View {
    @ObservedObject private var navigation = Navigation.shared
    @ObservedObject private var shared = Shared.shared
    @ObservedObject private var cleanup = CleanupModel.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.page }, set: { if let value = $0 { navigation.page = value } })) {
                ForEach(Page.sections, id: \.0) { title, pages in
                    Section(title) { ForEach(pages) { row($0) } }
                }
                Section { row(.history); row(.settings) }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 290)
            // With many pages the list scrolls; the disk summary keeps its own backing so rows don't show through it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                DiskSummary().padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
            }
        } detail: {
            Group {
                switch navigation.page {
                case .cleanup: CleanupView()
                case .space: SpaceView()
                case .snapshots: SystemDataView(part: .snapshots)
                case .macOSDownloads: SystemDataView(part: .downloads)
                case .apps: AppsView()
                case .leftovers: LeftoversView()
                case .packages: PackagesView(part: .managers)
                case .toolchains: PackagesView(part: .toolchains)
                case .commandLineTools: PackagesView(part: .manual)
                case .loginItems: StartupView(part: .login)
                case .background: StartupView(part: .background)
                case .systemExtensions, .drivers, .plugIns, .fonts, .inputMethods, .installerPackages, .searchPaths:
                    ExtensionsView(page: navigation.page).id(navigation.page)
                case .accounts: ChangesView(kind: .account).id(navigation.page)
                case .printers: ChangesView(kind: .printer).id(navigation.page)
                case .vpn: ChangesView(kind: .vpn).id(navigation.page)
                case .profiles: ChangesView(kind: .profile).id(navigation.page)
                case .privacy: ChangesView(kind: .privacy).id(navigation.page)
                case .hiddenItems: HomeView(place: .home).id(navigation.page)
                case .sharedFolder: HomeView(place: .shared).id(navigation.page)
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .navigationTitle(navigation.page.rawValue)
        }
        .overlay(alignment: .bottom) {
            BannerView().animation(.snappy, value: shared.banner)
        }
    }

    private func row(_ page: Page) -> some View {
        Label(page.rawValue, systemImage: page.symbol)
            .badge(badge(for: page))
            .tag(page)
    }

    private func badge(for page: Page) -> Text? {
        guard page == .cleanup, !cleanup.isScanning, cleanup.scannedAt != nil, cleanup.foundBytes > 0 else { return nil }
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
    /// What has been added to this Mac: startup items, packages, extensions and macOS's own data.
    static func inventory() {
        var started = Date()
        func lap(_ title: String) { print("  (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)\n"); started = Date(); print(title) }
        print("Login & Background")
        for row in StartupModel.collect().sorted(by: { $0.name < $1.name }) {
            print("  \(row.state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(row.kind.padding(toLength: 20, withPad: " ", startingAt: 0)) \(row.name) — from \(row.from), \(row.place)\(row.origin == .thirdParty ? "" : " [\(row.origin.label)]")")
        }
        lap("Packages")
        let (packages, managers) = PackagesModel.collect()
        print("  managers: \(managers.map(\.rawValue).joined(separator: ", "))")
        for manager in managers { print("  \(manager.rawValue): \(packages.filter { $0.manager == manager }.count)") }
        for package in packages.filter({ !$0.neededBy.isEmpty }).prefix(6) { print("  \(package.name) needed by \(package.neededBy.joined(separator: ", "))\(package.requested ? "" : " (dependency)")") }
        lap("Drivers & Extensions")
        let extensions = ExtensionsModel.collect()
        for category in Extension.Category.allCases {
            let items = extensions.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            let origins = Dictionary(grouping: items, by: \.origin).map { "\($0.value.count) \($0.key.label)" }.sorted().joined(separator: ", ")
            print("  \(category.rawValue): \(origins). e.g. \(items.prefix(3).map { $0.name + ($0.owner.map { " (in \($0))" } ?? "") }.joined(separator: "; "))")
        }
        for item in extensions where item.category == .receipts || item.category == .system {
            print("    \(item.name) [\(item.state ?? "")]: \(item.note ?? "")")
            for part in item.parts { print("      would move \(part.path)") }
        }
        lap("Toolchains and hand-installed tools")
        for package in packages where package.manager == .toolchain || package.manager == .manual {
            print("  [\(package.manager.rawValue)] \(package.name) — \(package.kind)\(package.origin == .thirdParty ? "" : " [\(package.origin.label)]") \(package.summary ?? "") \(package.note ?? "")")
        }
        lap("Search paths")
        for item in extensions where item.category == .searchPaths {
            print("  \(item.name) [\(item.origin.label)] \(item.detail ?? "") \(item.note ?? "")")
        }
        lap("Leftovers for every account")
        let apps = Apps.installed(home: home)
        let running = NSWorkspace.shared.runningApplications
        for orphan in AppsModel.collectOrphans(installed: Set(apps.map(\.bundleID)), names: apps.map(\.name), running: Set(running.compactMap(\.bundleIdentifier)),
                                               runningNames: running.compactMap(\.localizedName), fullDiskAccess: Permissions.fullDiskAccess()) where orphan.forAllUsers {
            print("  \(orphan.bundleID): \(Bytes.text(orphan.bytes)) — \(orphan.leftovers.map { $0.url.path }.joined(separator: ", "))")
        }
        lap("System changes")
        for change in SystemChangesModel.collect(fullDiskAccess: Permissions.fullDiskAccess()) {
            print("  [\(change.kind.rawValue)] \(change.name) — \(change.detail ?? "") · \(change.state ?? "") · \(change.removable ? "removable" : "settings")\(change.ownerGone ? " · app gone" : "")")
        }
        lap("Home folder")
        let items = HomeItems.hidden(home: home, appInstalled: { AppLookup.url(for: $0) != nil }, toolFound: { Shell.which($0) != nil },
                                     appNamed: HomeModel.appNamed()) + HomeItems.shared()
        for item in items where item.ownerGone || item.sensitive || item.place == .shared {
            print("  [\(item.place.rawValue)] \(item.name) — \(item.owner ?? "?") \(item.kind)\(item.sensitive ? " · keys" : "")\(item.ownerGone ? " · owner gone" : "")\(item.origin == .macOS ? " [macOS]" : "")")
        }
        print("  \(items.filter { $0.place == .home }.count) hidden items in home")
        lap("System Data")
        print("  snapshots: \(Snapshots.parse(Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output).map(\.name))")
        for asset in SystemAssets.measure() { print("  \(asset.feature.rawValue): \(Bytes.text(asset.bytes)) in \(asset.folders.count) folders") }
        lap("done")
    }

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
        let open = OpenFiles.snapshot()
        for rule in Catalog.rules where fullDiskAccess || !rule.needsFullDiskAccess {
            let ruleStart = Date()
            let items = OpenFiles.mark(rule.find(context, Cancellation()), with: open).sorted { $0.usage.bytes > $1.usage.bytes }
            let bytes = items.reduce(Int64(0)) { $0 + $1.usage.bytes }
            total += bytes
            if rule.safety != .review { suggested += items.filter(\.suggested).reduce(0) { $0 + $1.usage.bytes } }
            print("\n\(rule.title): \(Bytes.text(bytes)) in \(items.count) (\(String(format: "%.1f", Date().timeIntervalSince(ruleStart))) s)")
            for item in items.prefix(8) {
                print("  \(item.suggested ? "[x]" : "[ ]") \(Bytes.text(item.usage.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.label)\(item.inUseBy.map { " — in use by " + $0 } ?? item.detail.map { " — " + $0 } ?? "")\(item.usage.shared > 0 ? " (+\(Bytes.text(item.usage.shared)) shared)" : "")")
            }
            if items.count > 8 { print("  … and \(items.count - 8) more") }
        }
        print("\nFound \(Bytes.text(total)); selected by default \(Bytes.text(suggested)). Took \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
    }
}
