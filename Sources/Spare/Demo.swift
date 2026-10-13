#if DEBUG
import AppKit
import SpareCore

/// Sample data for marketing screenshots, shown with `-demo YES` in development builds. Nothing here comes from the
/// Mac it runs on, apart from the icons of a few well-known apps.
@MainActor
enum Demo {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "demo") }

    static func show() {
        let gb: Int64 = 1_000_000_000, mb: Int64 = 1_000_000
        Shared.shared.showDemo(space: Volume.Space(total: 494 * gb, free: 61 * gb, available: 83 * gb))
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func item(_ label: String, _ path: String, _ bytes: Int64, _ detail: String? = nil, suggested: Bool = true, shared: Int64 = 0) -> Item {
            Item(urls: [URL(fileURLWithPath: path)], label: label, detail: detail, usage: Usage(bytes: bytes, shared: shared, files: 1000), suggested: suggested)
        }
        func finding(_ id: String, _ items: [Item]) -> Finding? { Catalog.rule(id).map { Finding(rule: $0, items: items) } }
        let findings: [Finding?] = [
            finding("xcode", [item("Atlas", "/Users/you/Library/Developer/Xcode/DerivedData/Atlas-abc", 2_140 * mb, "Last built 3 weeks ago"),
                              item("Weather Kit Demo", "/Users/you/Library/Developer/Xcode/DerivedData/Weather-def", 1_380 * mb, "Last built 2 months ago"),
                              item("SwiftUI previews", "/Users/you/Library/Developer/Xcode/UserData/Previews", 820 * mb),
                              item("Simulator caches", "/Users/you/Library/Developer/CoreSimulator/Caches", 640 * mb)]),
            finding("device-support", [item("iOS 18.6 (22G86)", "/Users/you/Library/Developer/Xcode/iOS DeviceSupport/18.6", 4_210 * mb, "Copied 5 months ago"),
                                       item("iOS 17.5 (21F79)", "/Users/you/Library/Developer/Xcode/iOS DeviceSupport/17.5", 3_870 * mb, "Copied 1 year ago"),
                                       item("watchOS 11.5 (22T572)", "/Users/you/Library/Developer/Xcode/watchOS DeviceSupport/11.5", 1_120 * mb, "Copied 6 months ago")]),
            finding("projects", [item("api · target", "/Users/you/code/api/target", 1_930 * mb, "~/code/api · touched 2 months ago · Rebuilt by cargo build"),
                                 item("app · node_modules", "/Users/you/code/app/node_modules", 905 * mb, "~/code/app · touched 2 days ago · Install packages again to restore", suggested: false),
                                 item("portfolio · node_modules", "/Users/you/code/portfolio/node_modules", 812 * mb, "~/code/portfolio · touched 4 months ago · Install packages again to restore"),
                                 item("shop · node_modules", "/Users/you/code/shop/node_modules", 640 * mb, "~/code/shop · touched 3 months ago · Install packages again to restore", shared: 410 * mb),
                                 item("landing · .next", "/Users/you/code/landing/.next", 220 * mb, "~/code/landing · touched 5 months ago · Rebuilt by Next.js")]),
            finding("package-caches", [item("npm", "/Users/you/.npm/_cacache", 1_820 * mb, "~/.npm/_cacache"),
                                       item("pnpm store", "/Users/you/Library/pnpm/store", 1_240 * mb, "~/Library/pnpm/store"),
                                       item("Homebrew", "/Users/you/Library/Caches/Homebrew", 940 * mb, "~/Library/Caches/Homebrew"),
                                       item("Playwright browsers", "/Users/you/Library/Caches/ms-playwright", 610 * mb, "~/Library/Caches/ms-playwright"),
                                       item("Cargo", "/Users/you/.cargo/registry", 450 * mb, "~/.cargo/registry")]),
            finding("app-caches", [item("Spotify", "/Users/you/Library/Caches/com.spotify.client", 1_120 * mb),
                                   item("Google Chrome", "/Users/you/Library/Caches/Google", 760 * mb),
                                   item("Slack", "/Users/you/Library/Caches/com.tinyspeck.slackmacgap", 420 * mb),
                                   item("Figma", "/Users/you/Library/Caches/com.figma.Desktop", 380 * mb, "Open now. Quit it first to clean this.", suggested: false),
                                   item("Discord", "/Users/you/Library/Caches/com.hnc.Discord", 260 * mb)]),
            finding("logs", [item("Adobe", "/Users/you/Library/Logs/Adobe", 96 * mb, "Last written 2 weeks ago"),
                             item("Zoom", "/Users/you/Library/Logs/zoom.us", 48 * mb, "Last written 3 months ago")]),
            finding("crash-reports", [item("38 reports", "/Users/you/Library/Logs/DiagnosticReports/x.ips", 14 * mb, "~/Library/Logs/DiagnosticReports")]),
            finding("downloads", [item("Xcode_16.4.xip", "/Users/you/Downloads/Xcode_16.4.xip", 4_310 * mb, "Installer · opened 4 months ago", suggested: false),
                                  item("Screen Recording 2026-03-02.mov", "/Users/you/Downloads/rec.mov", 1_270 * mb, "opened 7 months ago", suggested: false)]),
            finding("ios-backups", [item("iPhone", "/Users/you/Library/Application Support/MobileSync/Backup/1", 18_200 * mb, "Backed up 1 year ago · iOS 18.2", suggested: false)]),
            finding("xcode-archives", []),
            finding("ai-models", [item("Ollama models", "/Users/you/.ollama/models", 9_600 * mb, "Remove single models with “ollama rm”", suggested: false)])
        ]
        CleanupModel.shared.showDemo(findings.compactMap { $0 }, expanded: ["projects"])

        // A few well-known apps for their icons; sizes and dates are made up.
        func app(_ name: String, _ id: String, version: String, appBytes: Int64, opened: Double?, leftovers: [(String, String, Int64)] = []) -> InstalledApp {
            let url = URL(fileURLWithPath: "/Applications/\(name).app")
            var made = InstalledApp(url: url, bundleID: id, name: name, version: version, isApple: false, fromAppStore: false, lastUsed: opened.map(ago))
            made.size = Usage(bytes: appBytes)
            made.leftovers = leftovers.map { Leftover(url: URL(fileURLWithPath: "/Users/you/Library/" + $0.1), kind: $0.0, usage: Usage(bytes: $0.2)) }
            return made
        }
        let apps = [
            app("Blender", "org.blenderfoundation.blender", version: "4.5.1", appBytes: 1_210 * mb, opened: 94,
                leftovers: [("Support files", "Application Support/Blender", 2_140 * mb), ("Caches", "Caches/org.blenderfoundation.blender", 486 * mb),
                            ("Saved windows", "Saved Application State/org.blenderfoundation.blender.savedState", 120_000), ("Settings", "Preferences/org.blenderfoundation.blender.plist", 4_000)]),
            app("Google Chrome", "com.google.Chrome", version: "141.0", appBytes: 1_430 * mb, opened: 0.1, leftovers: [("Caches", "Caches/Google", 760 * mb)]),
            app("Discord", "com.hnc.Discord", version: "0.0.351", appBytes: 520 * mb, opened: 2, leftovers: [("Support files", "Application Support/discord", 1_150 * mb)]),
            app("Spotify", "com.spotify.client", version: "1.2.71", appBytes: 380 * mb, opened: 0.5, leftovers: [("Caches", "Caches/com.spotify.client", 1_120 * mb)]),
            app("Zed", "dev.zed.Zed", version: "0.205", appBytes: 410 * mb, opened: 5, leftovers: [("Support files", "Application Support/Zed", 230 * mb)]),
            app("Affinity", "com.canva.affinity", version: "3.0", appBytes: 1_620 * mb, opened: 40),
            app("Framer", "com.framer.electron", version: "2026.9", appBytes: 610 * mb, opened: nil, leftovers: [("Support files", "Application Support/Framer", 920 * mb)])
        ]
        AppsModel.shared.showDemo(apps.sorted { $0.name < $1.name }, selected: apps[0].id)

        func row(_ name: String, app: String?, kind: String, runs: String, state: StartupState, from: String, place: String, note: String) -> StartupRow {
            StartupRow(id: name + place, source: .helper(URL(fileURLWithPath: "/Library/LaunchAgents/\(name).plist")), name: name,
                       appURL: app.map { URL(fileURLWithPath: "/Applications/\($0).app") }, kind: kind, schedule: runs, state: state,
                       from: from, place: place, origin: .thirdParty, note: note)
        }
        StartupModel.shared.showDemo([
            row("GoogleUpdater", app: "Google Chrome", kind: "Background agent", runs: "Every hour", state: .waiting, from: "Google Chrome", place: "Your Account",
                note: "Google's updater for Chrome and its other apps."),
            row("Zoom", app: nil, kind: "Background agent", runs: "At login", state: .leftBehind, from: "—", place: "Your Account", note: "us.zoom.ZoomDaemon · the program it starts is gone"),
            row("Homebrew: postgresql@16", app: nil, kind: "Background agent", runs: "Always running", state: .running, from: "Homebrew", place: "Your Account",
                note: "A Homebrew service. Stop it with “brew services stop”."),
            row("Docker helper", app: nil, kind: "Helper tool", runs: "Never", state: .leftBehind, from: "—", place: "System", note: "com.docker.vmnetd · nothing starts it any more"),
            row("Adobe Creative Cloud", app: nil, kind: "Background agent", runs: "At login", state: .notAllowed, from: "Adobe", place: "Every Account",
                note: "Part of Adobe Creative Cloud: its updater, sync or licensing."),
            row("Microsoft AutoUpdate", app: nil, kind: "System service", runs: "Every 2 hours", state: .turnedOff, from: "Microsoft", place: "System",
                note: "Keeps Office, Teams and Edge up to date."),
            row("Discord", app: "Discord", kind: "Background agent", runs: "When needed", state: .waiting, from: "Discord", place: "Your Account", note: "com.hnc.Discord.helper"),
            row("Spotify", app: "Spotify", kind: "Background agent", runs: "When needed", state: .off, from: "Spotify", place: "Your Account", note: "com.spotify.webhelper")
        ])

        let brew = Data("""
            {"formulae": [
              {"name": "node", "desc": "JavaScript runtime", "dependencies": ["icu4c", "openssl@3", "brotli"], "installed": [{"version": "24.9.0", "installed_on_request": true}]},
              {"name": "postgresql@16", "desc": "Object-relational database system", "dependencies": ["icu4c", "openssl@3"], "installed": [{"version": "16.10", "installed_on_request": true}]},
              {"name": "ffmpeg", "desc": "Play, record, convert, and stream audio and video", "dependencies": ["libvpx", "openssl@3", "x264"], "installed": [{"version": "8.0", "installed_on_request": true}]},
              {"name": "openssl@3", "desc": "Cryptography and SSL/TLS Toolkit", "dependencies": ["ca-certificates"], "installed": [{"version": "3.5.4", "installed_on_request": false}]},
              {"name": "icu4c", "desc": "C/C++ and Java libraries for Unicode", "dependencies": [], "installed": [{"version": "77.1", "installed_on_request": false}]},
              {"name": "ca-certificates", "desc": "Mozilla CA certificate store", "dependencies": [], "installed": [{"version": "2026-09-23", "installed_on_request": false}]},
              {"name": "libvpx", "desc": "VP8/VP9 video codec", "dependencies": [], "installed": [{"version": "1.15.2", "installed_on_request": false}]},
              {"name": "x264", "desc": "H.264/AVC encoder", "dependencies": [], "installed": [{"version": "r3222", "installed_on_request": false}]},
              {"name": "brotli", "desc": "Generic-purpose lossless compression algorithm", "dependencies": [], "installed": [{"version": "1.1.0", "installed_on_request": false}]},
              {"name": "gh", "desc": "GitHub command-line tool", "dependencies": [], "installed": [{"version": "2.81.0", "installed_on_request": true}]},
              {"name": "ripgrep", "desc": "Search tool like grep and The Silver Searcher", "dependencies": [], "installed": [{"version": "14.1.1", "installed_on_request": true}]}
            ], "casks": [
              {"token": "visual-studio-code", "name": ["Microsoft Visual Studio Code"], "desc": "Open-source code editor", "installed": "1.105.0"},
              {"token": "raycast", "name": ["Raycast"], "desc": "Control your tools with a few keystrokes", "installed": "1.103.2"}
            ]}
            """.utf8)
        var packages = PackageParsing.homebrew(brew, prefix: "/opt/homebrew")
        packages += [Package(manager: .npm, name: "typescript", kind: "Global package", version: "5.9.3"),
                     Package(manager: .npm, name: "vercel", kind: "Global package", version: "48.2.0"),
                     Package(manager: .bun, name: "@openai/codex", kind: "Global package", version: "0.91.0")]
        let sizes: [String: Int64] = ["node": 98 * mb, "postgresql@16": 76 * mb, "ffmpeg": 54 * mb, "openssl@3": 34 * mb, "icu4c": 81 * mb,
                                      "ca-certificates": 220_000, "libvpx": 4 * mb, "x264": 6 * mb, "brotli": 2 * mb, "gh": 48 * mb, "ripgrep": 6 * mb,
                                      "visual-studio-code": 610 * mb, "raycast": 290 * mb, "typescript": 23 * mb, "vercel": 61 * mb, "@openai/codex": 330 * mb]
        PackagesModel.shared.showDemo(packages.map { PackageRow(package: $0, bytes: sizes[$0.name]) }, managers: [.homebrew, .npm, .bun], unused: [])

        // A comfortable size for screenshots.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
            window.setContentSize(NSSize(width: 1240, height: 800))
            window.center()
        }
    }
}
#endif
