#if DEBUG
import AppKit
import SpareCore

/// Sample data for marketing screenshots, shown with `-demo YES` in development builds. Nothing here comes from the
/// Mac it runs on, apart from the icons of a few well-known apps.
@MainActor
enum Demo {
    nonisolated static var isOn: Bool { UserDefaults.standard.bool(forKey: "demo") }

    /// Nothing on the Mac changes in demo mode: an action only says what it would have done.
    static func pretend(_ what: String) {
        Shared.shared.banner = .init(title: "Nothing was changed", detail: "Demo mode. " + what)
    }

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
            finding("app-support-caches", [item("Slack", "/Users/you/Library/Application Support/Slack/Cache", 690 * mb),
                                           item("Visual Studio Code", "/Users/you/Library/Application Support/Code/CachedData", 540 * mb),
                                           item("Discord", "/Users/you/Library/Application Support/discord/Cache", 310 * mb),
                                           item("Brave Browser", "/Users/you/Library/Application Support/BraveSoftware/Brave-Browser/Default/Service Worker/CacheStorage", 280 * mb)]),
            finding("mail-downloads", [item("212 attachments", "/Users/you/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", 436 * mb,
                                            "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]),
            finding("logs", [item("Adobe", "/Users/you/Library/Logs/Adobe", 96 * mb, "Last written 2 weeks ago"),
                             item("Zoom", "/Users/you/Library/Logs/zoom.us", 48 * mb, "Last written 3 months ago")]),
            finding("crash-reports", [item("38 reports", "/Users/you/Library/Logs/DiagnosticReports/x.ips", 14 * mb, "~/Library/Logs/DiagnosticReports")]),
            finding("downloads", [item("Xcode_16.4.xip", "/Users/you/Downloads/Xcode_16.4.xip", 4_310 * mb, "Installer · opened 4 months ago", suggested: false),
                                  item("Screen Recording 2026-03-02.mov", "/Users/you/Downloads/rec.mov", 1_270 * mb, "opened 7 months ago", suggested: false)]),
            finding("messages-attachments", [item("IMG_4127.MOV", "/Users/you/Library/Messages/Attachments/4a/10/IMG_4127.MOV", 612 * mb, "From 8 months ago", suggested: false),
                                             item("Holiday.zip", "/Users/you/Library/Messages/Attachments/7c/02/Holiday.zip", 248 * mb, "From 1 year ago", suggested: false),
                                             item("IMG_3381.HEIC", "/Users/you/Library/Messages/Attachments/b1/0e/IMG_3381.HEIC", 9 * mb, "From 3 weeks ago", suggested: false)]),
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

        // What macOS could clear by itself, and three of Time Machine's hourly snapshots.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let hours = [1.2, 2.2, 3.2].map { "com.apple.TimeMachine.\(stamp.string(from: now.addingTimeInterval(-$0 * 3_600))).local" }
        PurgeableModel.shared.showDemo(services: [CacheDelete.Service.purgeableFiles.rawValue: 2_240 * mb,
                                                  CacheDelete.Service.macOSDownloads.rawValue: 1_180 * mb,
                                                  CacheDelete.Service.timeMachine.rawValue: 6_420 * mb,
                                                  CacheDelete.Service.cloudCopies.rawValue: 3_910 * mb,
                                                  CacheDelete.Service.containerCaches.rawValue: 820 * mb,
                                                  CacheDelete.Service.spotlight.rawValue: 310 * mb,
                                                  CacheDelete.Service.thumbnails.rawValue: 140 * mb,
                                                  "com.apple.demo.other": 95 * mb],
                                       snapshots: Snapshots.parse(hours.joined(separator: "\n")), backupDisk: "Backup Disk")

        // macOS's own downloads, with Apple Intelligence as `-demoIntelligence on|off|releasing` asks.
        let intelligence = UserDefaults.standard.string(forKey: "demoIntelligence") ?? "on"
        let siri = intelligence == "on" ? "en-US" : "de-DE"
        let assetsRoot = URL(fileURLWithPath: "/System/Library/AssetsV2")
        func asset(_ feature: SystemAsset.Feature, _ folder: String, _ bytes: Int64) -> SystemAsset {
            SystemAsset(feature: feature, folders: [assetsRoot.appendingPathComponent(folder)], bytes: bytes)
        }
        var assets = [asset(.siriSpeech, "com_apple_MobileAsset_UAF_Siri_Understanding", 4_970 * mb),
                      asset(.voices, "com_apple_MobileAsset_VoiceServicesVocalizerVoice", 955 * mb),
                      asset(.photos, "com_apple_MobileAsset_UAF_Photos_MediaAnalysis", 845 * mb),
                      asset(.languageData, "com_apple_MobileAsset_LinguisticData", 737 * mb),
                      asset(.metal, "com_apple_MobileAsset_MetalToolchain", 715 * mb),
                      asset(.dictionaries, "com_apple_MobileAsset_DictionaryServices_dictionaryOSX", 212 * mb),
                      asset(.other, "com_apple_MobileAsset_TimeZoneUpdate", 64 * mb)]
        if intelligence != "off" { assets.append(asset(.appleIntelligence, "com_apple_MobileAsset_UAF_FM_GenerativeModels", 7_840 * mb)) }
        MacDownloadsModel.shared.showDemo(
            assets: assets,
            leftovers: UpdateLeftovers.Found(items: [UpdateLeftovers.folder.appendingPathComponent("SU")], bytes: 3_350 * mb, downloaded: ago(41),
                                             product: "macOS Tahoe installer (26.6)", isLeftover: true),
            unused: 1_180 * mb,
            status: AppleIntelligence.evaluate(systemLanguage: "en-US", siriLanguage: siri, siriEnabled: true,
                                               eligibilityAnswer: intelligence == "on" ? 4 : 2, modelsSelected: intelligence != "off",
                                               savedBySpare: intelligence == "off", isVirtualMachine: false),
            holders: [.appleIntelligence: "Kept for Apple Intelligence's handwriting, summaries and safety checks.",
                      .siriSpeech: "Kept for Siri in \(intelligence == "on" ? "English" : "German and English"), even with Siri off.",
                      .voices: "Kept for Siri's voices in English.",
                      .languageData: "Kept for spelling and typing suggestions in English and German.",
                      .dictionaries: "Kept for 3 dictionaries in the Dictionary app.",
                      .photos: "Kept for Photos."].filter { intelligence != "off" || $0.key != .appleIntelligence },
            offLanguage: "de-DE", savedLanguage: intelligence == "off" ? "en-US" : nil)

        let mobile = URL(fileURLWithPath: "/Users/you/Library/Mobile Documents")
        let storage = URL(fileURLWithPath: "/Users/you/Library/CloudStorage")
        func place(_ name: String, _ folder: String, in root: URL, _ bytes: Int64, _ files: Int) -> CloudDownloads.Place {
            CloudDownloads.Place(name: name, url: root.appendingPathComponent(folder), bytes: bytes, files: files)
        }
        let icloud = [place("Projects", "com~apple~CloudDocs/Projects", in: mobile, 2_870 * mb, 1_204),
                      place("Photos to Sort", "com~apple~CloudDocs/Photos to Sort", in: mobile, 1_460 * mb, 388),
                      place("Obsidian", "iCloud~md~obsidian", in: mobile, 312 * mb, 2_915),
                      place("Pages", "com~apple~Pages", in: mobile, 96 * mb, 41)]
        let onedrive = [place("Shared Reports", "OneDrive-Personal/Shared Reports", in: storage, 1_120 * mb, 210),
                        place("Music Sessions", "OneDrive-Personal/Music Sessions", in: storage, 640 * mb, 58)]
        let simulators = URL(fileURLWithPath: "/Users/you/Library/Developer/CoreSimulator/Devices")
        func device(_ name: String, _ runtime: String, _ bytes: Int64, booted days: Double?, available: Bool = true) -> Simulators.Device {
            let udid = UUID().uuidString
            return Simulators.Device(udid: udid, name: name, runtime: runtime, state: "Shutdown", isAvailable: available,
                                     problem: available ? nil : "runtime profile not found", lastBooted: days.map(ago),
                                     dataURL: simulators.appendingPathComponent(udid), bytes: bytes)
        }
        SimulatorsModel.shared.showDemo(
            devices: [device("iPhone 17 Pro", "iOS 26.0", 3_420 * mb, booted: 2), device("iPad Air 13-inch (M3)", "iOS 26.0", 1_870 * mb, booted: 19),
                      device("iPhone 16", "iOS 18.6", 2_310 * mb, booted: 64), device("Apple Watch Series 10 (46mm)", "watchOS 11.5", 640 * mb, booted: nil),
                      device("iPhone 15 Pro", "iOS 17.5", 1_150 * mb, booted: 290, available: false),
                      device("iPhone SE (3rd generation)", "iOS 17.5", 420 * mb, booted: nil, available: false)],
            runtimes: [Simulators.Runtime(identifier: "A1", name: "iOS 26.0", build: "23A343", bytes: 8_910 * mb, deletable: true, lastUsed: ago(2), kind: "Disk Image"),
                       Simulators.Runtime(identifier: "A2", name: "iOS 18.6", build: "22G86", bytes: 8_120 * mb, deletable: true, lastUsed: ago(64), kind: "Disk Image"),
                       Simulators.Runtime(identifier: "A3", name: "watchOS 11.5", build: "22T572", bytes: 4_230 * mb, deletable: true, lastUsed: nil, kind: "Disk Image")])

        DockerModel.shared.showDemo(
            disks: [Docker.DiskImage(app: "Docker Desktop", url: URL(fileURLWithPath: "/Users/you/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
                                     bytes: 23_600 * mb)],
            usage: [Docker.Usage(kind: "Images", count: 31, active: 6, bytes: 14_300 * mb, reclaimable: 9_820 * mb),
                    Docker.Usage(kind: "Containers", count: 9, active: 3, bytes: 1_210 * mb, reclaimable: 760 * mb),
                    Docker.Usage(kind: "Local Volumes", count: 7, active: 4, bytes: 3_640 * mb, reclaimable: 1_100 * mb),
                    Docker.Usage(kind: "Build Cache", count: 214, active: 0, bytes: 4_480 * mb, reclaimable: 4_480 * mb)])

        let chrome = URL(fileURLWithPath: "/Users/you/Library/Application Support/Google/Chrome/Default/Extensions")
        func addOn(_ browser: BrowserExtension.Browser, _ profile: String?, _ name: String, _ version: String, _ bytes: Int64,
                   everySite: Bool, store: Bool? = true, on: Bool? = true) -> BrowserExtension {
            let id = String(Jitter.seed(name), radix: 26).map { Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(String($0), radix: 26)!)) }.prefix(32)
            return BrowserExtension(browser: browser, profile: profile, extensionID: String(id), name: name, version: version,
                                    url: chrome.appendingPathComponent(String(id)), bytes: bytes, enabled: on, fromStore: store, allSites: everySite)
        }
        BrowserExtensionsModel.shared.showDemo([
            addOn(.chrome, "Personal", "Password Manager", "4.12.0", 38 * mb, everySite: true),
            addOn(.chrome, "Personal", "Ad Blocker", "1.62.0", 21 * mb, everySite: true),
            addOn(.chrome, "Personal", "Color Picker", "2.3.1", 2 * mb, everySite: false),
            addOn(.chrome, "Work", "Screen Recorder", "7.4.2", 64 * mb, everySite: true, on: false),
            addOn(.chrome, "Work", "Internal Tools", "0.9.3", 1 * mb, everySite: false, store: false),
            addOn(.firefox, nil, "Reader View Plus", "3.1", 4 * mb, everySite: true),
            addOn(.safari, nil, "Translate", "2.0", 12 * mb, everySite: false)
        ])

        CloudModel.shared.showDemo([
            CloudDownloads.Provider(name: "iCloud Drive", root: mobile, places: icloud, bytes: 4_812 * mb, files: 4_590, complete: true),
            CloudDownloads.Provider(name: "OneDrive (Personal)", root: storage.appendingPathComponent("OneDrive-Personal"), places: onedrive,
                                    bytes: 1_760 * mb, files: 268, complete: true)
        ])

        // A comfortable size for screenshots.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
            window.setContentSize(NSSize(width: 1240, height: 800))
            window.center()
        }
    }
}
#endif
