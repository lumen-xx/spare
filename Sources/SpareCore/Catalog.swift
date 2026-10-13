import Foundation
import CoreServices

/// One thing Spare can clean, explained in plain words.
public struct Rule: Identifiable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case developer = "Developer"
        case caches = "Caches and Logs"
        case review = "Your Call"
    }

    /// What removing it costs. Spare preselects only the first three, and never anything someone else might miss.
    public enum Safety: Sendable {
        /// Recreated automatically as you use the app.
        case rebuilds
        /// Downloaded or built again, which takes time or bandwidth.
        case redownloads
        /// Nothing uses it any more.
        case disposable
        /// Possibly wanted: only you can tell.
        case review
    }

    public let id: String
    public let title: String
    public let symbol: String
    public let group: Group
    public let safety: Safety
    /// What it is.
    public let about: String
    /// What happens once it's gone.
    public let afterwards: String
    /// It lives where macOS lets Spare look only with Full Disk Access.
    public let needsFullDiskAccess: Bool
    public let find: @Sendable (ScanContext, Cancellation) -> [Item]
}

/// One file or folder (or a small bundle of them) that can go to the Trash.
public struct Item: Identifiable, Sendable, Hashable {
    public let urls: [URL]
    public var label: String
    public var detail: String?
    public var usage: Usage
    /// Spare would select it to begin with.
    public var suggested: Bool
    /// A running program has files open inside. Moving it would leave that program writing into the Trash, which
    /// Finder then can't empty, so it can't be selected.
    public var inUseBy: String?
    public var id: String { urls.map(\.path).joined(separator: "\n") }

    public init(urls: [URL], label: String, detail: String? = nil, usage: Usage = Usage(), suggested: Bool) {
        self.urls = urls; self.label = label; self.detail = detail; self.usage = usage; self.suggested = suggested
    }
}

public struct Finding: Identifiable, Sendable {
    public let rule: Rule
    public var items: [Item]
    public var id: String { rule.id }
    public var bytes: Int64 { items.reduce(0) { $0 + $1.usage.bytes } }
    public init(rule: Rule, items: [Item]) { self.rule = rule; self.items = items }
}

/// What a scan needs from the app around it.
public struct ScanContext: Sendable {
    public var home: URL
    public var projectRoots: [URL]
    /// Projects untouched this long are suggested for cleaning.
    public var inactiveAfter: TimeInterval
    public var fullDiskAccess: Bool
    public var now: Date
    /// An app's name from its bundle identifier, if it's installed.
    public var appName: @Sendable (String) -> String?
    /// Whether the app a cache folder belongs to is open. Gets the folder's name.
    public var isOpen: @Sendable (String) -> Bool

    public init(home: URL, projectRoots: [URL], inactiveAfter: TimeInterval, fullDiskAccess: Bool, now: Date = Date(),
                appName: @escaping @Sendable (String) -> String? = { _ in nil }, isOpen: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.home = home; self.projectRoots = projectRoots; self.inactiveAfter = inactiveAfter
        self.fullDiskAccess = fullDiskAccess; self.now = now; self.appName = appName; self.isOpen = isOpen
    }

    func path(_ relative: String) -> URL { home.appendingPathComponent(relative) }
}

public enum Catalog {
    public static let rules: [Rule] = [
        Rule(id: "xcode", title: "Xcode build data", symbol: "hammer", group: .developer, safety: .rebuilds,
             about: "Intermediate files Xcode keeps for every project it has built, plus its preview and simulator caches.",
             afterwards: "Xcode recreates them. The next build of each project takes longer.",
             needsFullDiskAccess: false, find: findXcode),
        Rule(id: "device-support", title: "Device support files", symbol: "iphone", group: .developer, safety: .redownloads,
             about: "Debug symbols Xcode copied from each iPhone, iPad, Watch or Vision Pro version you've connected.",
             afterwards: "Xcode copies them again the next time you connect a device running that version.",
             needsFullDiskAccess: false, find: findDeviceSupport),
        Rule(id: "projects", title: "Project build folders", symbol: "shippingbox", group: .developer, safety: .redownloads,
             about: "node_modules, Rust targets, Swift .build folders and the like. Projects you haven't touched in a while are selected.",
             afterwards: "Installing or building the project again brings them back.",
             needsFullDiskAccess: false, find: findProjects),
        Rule(id: "package-caches", title: "Package manager caches", symbol: "archivebox", group: .developer, safety: .redownloads,
             about: "Copies of every package npm, pnpm, Homebrew, pip, Cargo and others have downloaded, kept in case they're needed again.",
             afterwards: "Packages download again the next time something installs them.",
             needsFullDiskAccess: false, find: findPackageCaches),
        Rule(id: "app-caches", title: "App caches", symbol: "square.stack.3d.up", group: .caches, safety: .rebuilds,
             about: "Files apps keep to load things faster. macOS's own caches are left alone; it manages them itself.",
             afterwards: "Apps fill them again as you use them, and may feel slower at first. Caches of open apps aren't selected.",
             needsFullDiskAccess: false, find: findAppCaches),
        Rule(id: "app-support-caches", title: "Browser and app caches", symbol: "globe", group: .caches, safety: .rebuilds,
             about: "Caches Chromium browsers and Electron apps such as Slack, Discord and VS Code keep beside their data, which other cleaners miss.",
             afterwards: "They fill again as you use them. Logins, history and saved data aren't caches and stay.",
             needsFullDiskAccess: false, find: findAppSupportCaches),
        Rule(id: "mail-downloads", title: "Mail attachments you opened", symbol: "paperclip", group: .caches, safety: .rebuilds,
             about: "Copies Mail saves when you open an attachment. The messages keep their attachments.",
             afterwards: "Mail makes a new copy the next time you open one.",
             needsFullDiskAccess: true, find: findMailDownloads),
        Rule(id: "logs", title: "Logs", symbol: "doc.text", group: .caches, safety: .disposable,
             about: "Records apps write about what they did, for troubleshooting.",
             afterwards: "Nothing you'd notice. Apps start new ones.",
             needsFullDiskAccess: false, find: findLogs),
        Rule(id: "crash-reports", title: "Crash reports", symbol: "exclamationmark.triangle", group: .caches, safety: .disposable,
             about: "Reports macOS saved when an app crashed or hung.",
             afterwards: "Only matters if you were about to send one to a developer.",
             needsFullDiskAccess: false, find: findCrashReports),
        Rule(id: "downloads", title: "Old downloads", symbol: "arrow.down.circle", group: .review, safety: .review,
             about: "Installers in Downloads, and large files there you haven't opened in two months.",
             afterwards: "They're gone unless you download them again.",
             needsFullDiskAccess: true, find: findDownloads),
        Rule(id: "messages-attachments", title: "Messages attachments", symbol: "message", group: .review, safety: .review,
             about: "Photos, videos and files from your conversations, largest first. Only ones of 5 MB or more are listed.",
             afterwards: "The message stays, but the file is gone from this Mac. History can put it back until you empty the Trash.",
             needsFullDiskAccess: true, find: findMessagesAttachments),
        Rule(id: "ios-backups", title: "iPhone and iPad backups", symbol: "iphone.gen3", group: .review, safety: .review,
             about: "Complete local backups made with Finder. iCloud backups aren't here and aren't affected.",
             afterwards: "That device can no longer be restored from this backup.",
             needsFullDiskAccess: true, find: findDeviceBackups),
        Rule(id: "xcode-archives", title: "Xcode archives", symbol: "archivebox.fill", group: .review, safety: .review,
             about: "A copy of every build you archived for release, with its debug symbols.",
             afterwards: "Those builds can't be exported again, and their crash reports can't be read.",
             needsFullDiskAccess: false, find: findArchives),
        Rule(id: "ai-models", title: "Downloaded AI models", symbol: "cpu", group: .review, safety: .review,
             about: "Models fetched by Ollama, LM Studio, Hugging Face and Whisper.",
             afterwards: "Each one downloads again, often several gigabytes, the next time it's used.",
             needsFullDiskAccess: false, find: findModels)
    ]

    public static func rule(_ id: String) -> Rule? { rules.first { $0.id == id } }

    // MARK: - Developer

    @Sendable static func findXcode(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        let derived = context.path("Library/Developer/Xcode/DerivedData")
        var items = children(of: derived, cancel: cancel) { url in
            if url.lastPathComponent == "ModuleCache.noindex" { return ("Shared module cache", nil) }
            // Folders are named after the project with a hash appended: "Voidamp-adkfjhqwe".
            let name = url.lastPathComponent
            let project = name.range(of: "-", options: .backwards).map { String(name[..<$0.lowerBound]) } ?? name
            return (project, modified(url).map { "Last built " + ago($0, from: context.now) })
        }
        for (relative, label) in [("Library/Developer/Xcode/UserData/Previews", "SwiftUI previews"),
                                  ("Library/Developer/CoreSimulator/Caches", "Simulator caches"),
                                  ("Library/Caches/com.apple.dt.Xcode", "Xcode's own cache")] {
            items += single(context.path(relative), label: label, cancel: cancel)
        }
        return items.map { var item = $0; item.suggested = true; return item }
    }

    @Sendable static func findDeviceSupport(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        var items: [Item] = []
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            let folder = context.path("Library/Developer/Xcode/\(platform) DeviceSupport")
            items += children(of: folder, cancel: cancel) { url in
                // "iPhone15,2 17.5 (21F79)" or "17.5 (21F79)": keep the version and build.
                let parts = url.lastPathComponent.split(separator: " ")
                let version = parts.first?.contains(",") == true ? parts.dropFirst().joined(separator: " ") : url.lastPathComponent
                return ("\(platform) \(version)", modified(url).map { "Copied " + ago($0, from: context.now) })
            }
        }
        return items.map { var item = $0; item.suggested = true; return item }
    }

    @Sendable static func findProjects(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        let found = Projects.artifacts(in: context.projectRoots, cancel: cancel)
        return measure(found.map { $0.folder }, cancel: cancel).enumerated().map { index, usage in
            let artifact = found[index]
            let touched = DiskUsage.lastTouched(artifact.project, ignoring: Projects.ignoredWhenDating)
            let idle = touched.map { context.now.timeIntervalSince($0) >= context.inactiveAfter } ?? true
            let place = tilde(artifact.project, home: context.home)
            let when = touched.map { "touched " + ago($0, from: context.now) } ?? "never touched"
            return Item(urls: [artifact.folder], label: "\(artifact.project.lastPathComponent) · \(artifact.folder.lastPathComponent)",
                        detail: "\(place) · \(when) · \(artifact.kind.restore)", usage: usage, suggested: idle)
        }
    }

    /// Package caches: (tool, path from home). Cache folders in ~/Library/Caches listed here are kept out of App caches.
    static let packageCaches: [(String, String)] = [
        ("npm", ".npm/_cacache"), ("pnpm store", "Library/pnpm/store"), ("pnpm", "Library/Caches/pnpm"),
        ("Yarn", "Library/Caches/Yarn"), ("Bun", ".bun/install/cache"), ("Bun", "Library/Caches/bun"),
        ("Homebrew", "Library/Caches/Homebrew"), ("pip", "Library/Caches/pip"), ("uv", ".cache/uv"),
        ("Poetry", "Library/Caches/pypoetry"), ("CocoaPods", "Library/Caches/CocoaPods"),
        ("Swift packages", "Library/Caches/org.swift.swiftpm"), ("Gradle", ".gradle/caches"), ("Maven", ".m2/repository"),
        ("Cargo", ".cargo/registry"), ("Go modules", "go/pkg/mod"), ("Go build cache", "Library/Caches/go-build"),
        ("Composer", "Library/Caches/composer"), ("Composer", ".composer/cache"), ("Deno", "Library/Caches/deno"),
        ("Playwright browsers", "Library/Caches/ms-playwright"), ("Puppeteer browsers", ".cache/puppeteer"),
        ("node-gyp", "Library/Caches/node-gyp"), ("Electron", "Library/Caches/electron"), ("TypeScript", "Library/Caches/typescript"),
        ("Node versions (Corepack)", "Library/Caches/node/corepack")
    ]

    @Sendable static func findPackageCaches(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        let existing = packageCaches.filter { exists(context.path($0.1)) }
        return measure(existing.map { context.path($0.1) }, cancel: cancel).enumerated().compactMap { index, usage in
            guard usage.bytes + usage.shared > 0 else { return nil }
            let (tool, relative) = existing[index]
            return Item(urls: [context.path(relative)], label: tool, detail: "~/" + relative, usage: usage, suggested: true)
        }
    }

    // MARK: - Caches and logs

    /// Folders in ~/Library/Caches that belong to macOS without a com.apple prefix.
    static let systemCacheNames: Set<String> = ["CloudKit", "FamilyCircle", "GameKit", "GeoServices", "PassKit", "JetPackCache",
                                                "SiriTTS", "TemporaryItems", "Metadata", "INSTALLATION", "AssetsV2"]

    /// macOS's background services name their caches after themselves: "familycircled", "akd", "bird". Such names
    /// are all lowercase letters ending in "d"; apps use their bundle identifier or a capitalised name instead.
    public static func isSystemService(_ name: String) -> Bool {
        name.count <= 24 && name.hasSuffix("d") && name.allSatisfy { $0.isLowercase && $0.isLetter }
    }

    @Sendable static func findAppCaches(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        let caches = context.path("Library/Caches")
        let claimed = Set(packageCaches.map { context.path($0.1).path } + [context.path("Library/Caches/com.apple.dt.Xcode").path])
        let folders = list(caches).filter { url in
            let name = url.lastPathComponent
            return !name.hasPrefix("com.apple.") && !systemCacheNames.contains(name) && !isSystemService(name) && !claimed.contains(url.path)
        }
        let usages = measure(folders, cancel: cancel)
        var items: [Item] = []
        var small: [URL] = []
        var smallUsage = Usage()
        for (index, folder) in folders.enumerated() {
            let usage = usages[index], name = folder.lastPathComponent
            guard usage.bytes > 0 else { continue }
            if usage.bytes < 1_000_000 { small.append(folder); smallUsage = smallUsage + usage; continue }
            let open = context.isOpen(name)
            let label = context.appName(name) ?? context.appName(name.replacingOccurrences(of: ".ShipIt", with: "")).map { "\($0) updater" } ?? name
            items.append(Item(urls: [folder], label: label, detail: open ? "Open now. Quit it first to clean this." : nil, usage: usage, suggested: !open))
        }
        if smallUsage.bytes >= 1_000_000 {
            items.append(Item(urls: small, label: "\(small.count) smaller caches", detail: "Each under 1 MB", usage: smallUsage, suggested: false))
        }
        return items
    }

    /// Folders Chromium and Electron fill with caches. Everything else beside them, such as Local Storage, IndexedDB or
    /// Service Worker, is the app's data.
    static let chromiumCacheNames: Set<String> = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
                                                  "GraphiteDawnCache", "GrShaderCache", "ShaderCache", "CachedData"]

    /// Folders in Application Support that hold no app's caches and that macOS may guard with a permission prompt.
    static let guardedSupportNames: Set<String> = ["AddressBook", "CallHistoryDB", "CallHistoryTransactions", "MobileSync", "Knowledge",
                                                   "FileProvider", "CloudDocs", "FaceTime", "Dock", "DifferentialPrivacy", "Mobile Documents"]

    /// Names for folders that don't say which app they belong to.
    static let supportFolderNames = ["Google/Chrome": "Google Chrome", "Google/Chrome Beta": "Chrome Beta", "Google/Chrome Canary": "Chrome Canary",
                                     "BraveSoftware/Brave-Browser": "Brave", "BraveSoftware/Brave-Browser-Beta": "Brave Beta",
                                     "BraveSoftware/Brave-Browser-Nightly": "Brave Nightly", "Arc/User Data": "Arc", "Code": "Visual Studio Code",
                                     "Code - Insiders": "Visual Studio Code - Insiders", "com.operasoftware.Opera": "Opera"]

    /// A Chromium browser's or Electron app's own folder: only they write these files, so a folder called Cache
    /// anywhere else is never taken.
    static func isChromiumData(_ folder: URL) -> Bool {
        ["Network Persistent State", "Local State", "Network/Network Persistent State"].contains { exists(folder.appendingPathComponent($0)) }
    }

    @Sendable static func findAppSupportCaches(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        let support = context.path("Library/Application Support")
        // One app each: its name, the folder names that tell whether it's open, and the folders holding its caches.
        var apps: [(label: String, names: [String], folders: [URL])] = []
        for top in list(support) where isFolder(top) {
            guard !cancel.isCancelled else { break }
            let name = top.lastPathComponent
            guard !name.hasPrefix("."), !name.hasPrefix("com.apple."), !Apps.systemNames.contains(name), !guardedSupportNames.contains(name) else { continue }
            if isChromiumData(top) {
                // An Electron app's own folder, or a browser such as Edge whose profiles sit directly inside.
                apps.append((supportLabel(name, context), [name], chromiumFolders(in: top)))
            } else {
                // A company's folder with a browser inside: Google/Chrome, BraveSoftware/Brave-Browser, Arc/User Data.
                for child in list(top) where isFolder(child) && isChromiumData(child) {
                    let key = "\(name)/\(child.lastPathComponent)"
                    let generic = child.lastPathComponent == "User Data" || child.lastPathComponent == "Default"
                    let label = supportFolderNames[key] ?? (generic ? supportLabel(name, context) : supportLabel(child.lastPathComponent, context))
                    apps.append((label, [name, child.lastPathComponent], chromiumFolders(in: child)))
                }
            }
        }
        var items: [Item] = []
        for app in apps {
            let caches = app.folders.flatMap { folder in
                list(folder).filter { chromiumCacheNames.contains($0.lastPathComponent) && isFolder($0) }
            }
            guard !caches.isEmpty, !cancel.isCancelled else { continue }
            let usages = measure(caches, cancel: cancel)
            let kept = caches.indices.filter { usages[$0].bytes + usages[$0].shared > 0 }
            let usage = kept.map { usages[$0] }.reduce(Usage(), +)
            guard usage.bytes >= 100_000 else { continue }
            let open = app.names.contains(where: context.isOpen)
            items.append(Item(urls: kept.map { caches[$0] }, label: app.label, detail: open ? "Open now. Quit it first to clean this." : nil,
                              usage: usage, suggested: !open))
        }
        return items
    }

    /// The folder itself and its profiles: the folders directly inside that are Chromium's too, and the partitions
    /// Electron apps keep for separate sign-ins.
    static func chromiumFolders(in root: URL) -> [URL] {
        var folders = [root]
        for child in list(root) where isFolder(child) && !chromiumCacheNames.contains(child.lastPathComponent) {
            if child.lastPathComponent == "Partitions" {
                folders += list(child).filter { isFolder($0) && isChromiumData($0) }
            } else if isChromiumData(child) {
                folders.append(child)
            }
        }
        return folders
    }

    /// The app's name for a bundle identifier, a known folder's name, or the folder's own name tidied up: "discord" is Discord.
    static func supportLabel(_ folder: String, _ context: ScanContext) -> String {
        if let name = supportFolderNames[folder] ?? context.appName(folder) { return name }
        guard folder.allSatisfy({ !$0.isUppercase }) else { return folder }
        return folder.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    @Sendable static func findMailDownloads(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        guard context.fullDiskAccess else { return [] }
        let folder = context.path("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        let entries = list(folder)
        guard !entries.isEmpty else { return [] }
        let usage = measure(entries, cancel: cancel).reduce(Usage(), +)
        guard usage.files > 0 else { return [] }
        return [Item(urls: entries, label: usage.files == 1 ? "1 attachment" : "\(usage.files) attachments",
                     detail: tilde(folder, home: context.home), usage: usage, suggested: true)]
    }

    @Sendable static func findLogs(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        children(of: context.path("Library/Logs"), except: ["DiagnosticReports", "CoreSimulator", "com.apple.xpc.launchd"], cancel: cancel) { url in
            (url.deletingPathExtension().lastPathComponent, modified(url).map { "Last written " + ago($0, from: context.now) })
        }.filter { $0.usage.bytes >= 100_000 }.map { var item = $0; item.suggested = true; return item }
    }

    @Sendable static func findCrashReports(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        let reports = list(context.path("Library/Logs/DiagnosticReports"))
        guard !reports.isEmpty else { return [] }
        let usage = measure(reports, cancel: cancel).reduce(Usage(), +)
        let count = reports.filter { $0.pathExtension == "ips" || $0.pathExtension == "crash" || $0.pathExtension == "diag" }.count
        return [Item(urls: reports, label: count == 1 ? "1 report" : "\(count) reports", detail: "~/Library/Logs/DiagnosticReports", usage: usage, suggested: true)]
    }

    // MARK: - Your call

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    @Sendable static func findDownloads(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        guard context.fullDiskAccess else { return [] }
        let entries = list(context.path("Downloads"))
        let usages = measure(entries, cancel: cancel)
        return entries.enumerated().compactMap { index, url in
            let usage = usages[index]
            let used = lastUsed(url)
            let idle = used.map { context.now.timeIntervalSince($0) } ?? .infinity
            let installer = installerExtensions.contains(url.pathExtension.lowercased())
            guard (installer && idle > 7 * 86_400 && usage.bytes > 0) || (usage.bytes >= 100_000_000 && idle >= 60 * 86_400) else { return nil }
            let when = used.map { "opened " + ago($0, from: context.now) } ?? "never opened"
            return Item(urls: [url], label: url.lastPathComponent, detail: (installer ? "Installer · " : "") + when, usage: usage, suggested: false)
        }
    }

    @Sendable static func findMessagesAttachments(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        guard context.fullDiskAccess else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .totalFileAllocatedSizeKey, .creationDateKey]
        guard let walk = FileManager.default.enumerator(at: context.path("Library/Messages/Attachments"), includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var items: [Item] = []
        for case let url as URL in walk {
            guard !cancel.isCancelled else { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true || values.isPackage == true else { continue }
            // A quick look at the size first, so only the large ones are measured properly.
            if values.isRegularFile == true, (values.totalFileAllocatedSize ?? 0) < 5_000_000 { continue }
            let usage = DiskUsage.measure(url, cancel: cancel)
            guard usage.bytes >= 5_000_000 else { continue }
            items.append(Item(urls: [url], label: url.lastPathComponent, detail: values.creationDate.map { "From " + ago($0, from: context.now) },
                              usage: usage, suggested: false))
        }
        return items.sorted { $0.usage.bytes > $1.usage.bytes }
    }

    @Sendable static func findDeviceBackups(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        guard context.fullDiskAccess else { return [] }
        return children(of: context.path("Library/Application Support/MobileSync/Backup"), cancel: cancel) { url in
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            let name = info?["Device Name"] as? String ?? info?["Display Name"] as? String ?? "Unknown device"
            var detail: [String] = []
            if let date = info?["Last Backup Date"] as? Date { detail.append("Backed up " + ago(date, from: context.now)) }
            if let version = info?["Product Version"] as? String { detail.append("iOS " + version) }
            return (name, detail.isEmpty ? nil : detail.joined(separator: " · "))
        }
    }

    @Sendable static func findArchives(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        let days = list(context.path("Library/Developer/Xcode/Archives"))
        let archives = days.flatMap { list($0) }.filter { $0.pathExtension == "xcarchive" }
        return measure(archives, cancel: cancel).enumerated().map { index, usage in
            let url = archives[index]
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            let name = info?["Name"] as? String ?? url.deletingPathExtension().lastPathComponent
            let version = (info?["ApplicationProperties"] as? [String: Any])?["CFBundleShortVersionString"] as? String
            let date = info?["CreationDate"] as? Date ?? modified(url)
            let detail = [version.map { "Version " + $0 }, date.map { "Archived " + ago($0, from: context.now) }].compactMap { $0 }.joined(separator: " · ")
            return Item(urls: [url], label: name, detail: detail.isEmpty ? nil : detail, usage: usage, suggested: false)
        }
    }

    @Sendable static func findModels(_ context: ScanContext, _ cancel: Cancellation) -> [Item] {
        var items: [Item] = []
        for (label, relative, hint) in [("Ollama models", ".ollama/models", "Remove single models with “ollama rm”"),
                                        ("LM Studio models", ".lmstudio/models", nil),
                                        ("LM Studio models", ".cache/lm-studio/models", nil),
                                        ("Whisper models", ".cache/whisper", nil)] {
            items += single(context.path(relative), label: label, detail: hint, cancel: cancel)
        }
        items += children(of: context.path(".cache/huggingface/hub"), cancel: cancel) { url in
            // "models--openai--whisper-large-v3" is openai/whisper-large-v3.
            let parts = url.lastPathComponent.components(separatedBy: "--")
            return (parts.count >= 3 ? parts.dropFirst().joined(separator: "/") : url.lastPathComponent, "Hugging Face")
        }
        return items.map { var item = $0; item.suggested = false; return item }
    }

    // MARK: - Helpers

    /// Measures many items side by side; disks answer faster with a few requests in flight.
    public static func measure(_ urls: [URL], cancel: Cancellation) -> [Usage] {
        var results = [Usage](repeating: Usage(), count: urls.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            guard !cancel.isCancelled else { return }
            let usage = DiskUsage.measure(urls[index], cancel: cancel)
            lock.lock(); results[index] = usage; lock.unlock()
        }
        return results
    }

    /// Visible entries of a folder, without .DS_Store and symbolic links.
    public static func list(_ folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
        return entries.filter { url in
            url.lastPathComponent != ".DS_Store" && url.lastPathComponent != ".localized"
                && (try? url.resourceValues(forKeys: Set(keys)))?.isSymbolicLink != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Every entry of a folder, symbolic links included, without .DS_Store.
    public static func listIncludingLinks(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? [])
            .filter { $0.lastPathComponent != ".DS_Store" && $0.lastPathComponent != ".localized" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func children(of folder: URL, except: Set<String> = [], cancel: Cancellation,
                         describe: (URL) -> (String, String?)) -> [Item] {
        let entries = list(folder).filter { !except.contains($0.lastPathComponent) }
        return measure(entries, cancel: cancel).enumerated().compactMap { index, usage in
            guard usage.bytes + usage.shared > 0 else { return nil }
            let (label, detail) = describe(entries[index])
            return Item(urls: [entries[index]], label: label, detail: detail, usage: usage, suggested: false)
        }
    }

    static func single(_ url: URL, label: String, detail: String? = nil, cancel: Cancellation) -> [Item] {
        guard exists(url) else { return [] }
        let usage = DiskUsage.measure(url, cancel: cancel)
        guard usage.bytes + usage.shared > 0 else { return [] }
        return [Item(urls: [url], label: label, detail: detail, usage: usage, suggested: false)]
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }

    static func modified(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }

    /// When the person last opened it, as Spotlight recorded it; otherwise when it arrived in its folder.
    static func lastUsed(_ url: URL) -> Date? {
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { return date }
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
        return values?.addedToDirectoryDate ?? values?.contentModificationDate
    }

    public static func tilde(_ url: URL, home: URL) -> String {
        url.path.hasPrefix(home.path + "/") ? "~" + url.path.dropFirst(home.path.count) : url.path
    }

    /// "3 weeks ago", "yesterday".
    public static func ago(_ date: Date, from now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
