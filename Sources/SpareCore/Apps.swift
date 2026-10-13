import Foundation
import CoreServices

/// An app in /Applications or ~/Applications.
public struct InstalledApp: Identifiable, Sendable {
    public let url: URL
    public let bundleID: String
    public let name: String
    public let version: String?
    /// Comes with macOS or from Apple; Spare doesn't offer to remove these.
    public let isApple: Bool
    public let fromAppStore: Bool
    public var lastUsed: Date?
    public var size = Usage()
    public var leftovers: [Leftover] = []
    public var id: String { url.path }

    public init(url: URL, bundleID: String, name: String, version: String?, isApple: Bool, fromAppStore: Bool, lastUsed: Date? = nil) {
        self.url = url; self.bundleID = bundleID; self.name = name; self.version = version
        self.isApple = isApple; self.fromAppStore = fromAppStore; self.lastUsed = lastUsed
    }
    public var dataBytes: Int64 { leftovers.reduce(0) { $0 + $1.usage.bytes } }
    public var totalBytes: Int64 { size.bytes + dataBytes }
}

/// Something an app keeps in ~/Library.
public struct Leftover: Identifiable, Sendable, Hashable {
    public let url: URL
    public let kind: String
    public var usage = Usage()
    public var id: String { url.path }
}

/// Files in ~/Library named after an app that is no longer installed.
public struct Orphan: Identifiable, Sendable {
    public let bundleID: String
    public var leftovers: [Leftover]
    public var newest: Date?
    /// In /Library, shared by every account: removing it needs an administrator password.
    public var forAllUsers = false
    public var id: String { (forAllUsers ? "all:" : "") + bundleID }
    public var bytes: Int64 { leftovers.reduce(0) { $0 + $1.usage.bytes } }
}

public enum Apps {
    public static func installed(home: URL) -> [InstalledApp] {
        var bundles: [URL] = []
        // Apps sit in folders up to a few levels deep, such as "Utilities/Adobe Creative Cloud/ACC"; never inside other apps.
        func look(in folder: URL, depth: Int) {
            for entry in Catalog.list(folder) {
                if entry.pathExtension == "app" { bundles.append(entry) }
                else if depth < 3, (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { look(in: entry, depth: depth + 1) }
            }
        }
        for folder in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] { look(in: folder, depth: 1) }
        return bundles.compactMap { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            let info = bundle.infoDictionary ?? [:]
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return InstalledApp(url: url, bundleID: id, name: name,
                                version: info["CFBundleShortVersionString"] as? String,
                                isApple: id.hasPrefix("com.apple."),
                                fromAppStore: FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path),
                                lastUsed: lastUsed(url))
        }
    }

    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Where apps keep things in ~/Library, what to call each place, and whether macOS guards it.
    struct Place {
        let folder: String
        let kind: String
        let guarded: Bool
        /// Whether an entry with this name belongs to the app: (entry, bundle identifier, names).
        let matches: (String, String, [String]) -> Bool
    }

    static func named(_ entry: String, _ names: [String]) -> Bool {
        names.contains { $0.count >= 3 && $0.caseInsensitiveCompare(entry) == .orderedSame }
    }

    static let places: [Place] = [
        Place(folder: "Library/Application Support", kind: "Support files", guarded: false) { e, id, names in e == id || e.hasPrefix(id + ".") || named(e, names) },
        Place(folder: "Library/Caches", kind: "Caches", guarded: false) { e, id, names in e == id || e.hasPrefix(id + ".") || named(e, names) },
        Place(folder: "Library/Preferences", kind: "Settings", guarded: false) { e, id, _ in e.hasSuffix(".plist") && (e == id + ".plist" || e.hasPrefix(id + ".")) },
        Place(folder: "Library/Preferences/ByHost", kind: "Settings", guarded: false) { e, id, _ in e.hasPrefix(id + ".") },
        Place(folder: "Library/Containers", kind: "App sandbox", guarded: true) { e, id, _ in e == id || e.hasPrefix(id + ".") },
        Place(folder: "Library/Saved Application State", kind: "Saved windows", guarded: false) { e, id, _ in e == id + ".savedState" },
        Place(folder: "Library/HTTPStorages", kind: "Web data", guarded: false) { e, id, _ in e == id || e == id + ".binarycookies" },
        Place(folder: "Library/WebKit", kind: "Web data", guarded: false) { e, id, _ in e == id },
        Place(folder: "Library/Cookies", kind: "Cookies", guarded: true) { e, id, _ in e == id + ".binarycookies" },
        Place(folder: "Library/Logs", kind: "Logs", guarded: false) { e, id, names in e == id || named(e, names) },
        Place(folder: "Library/Application Scripts", kind: "Scripts", guarded: false) { e, id, _ in e == id || e.hasPrefix(id + ".") },
        Place(folder: "Library/LaunchAgents", kind: "Login agent", guarded: false) { e, id, _ in e.hasSuffix(".plist") && e.hasPrefix(id) }
    ]

    /// What an app keeps in ~/Library, matched by its bundle identifier or exact name, measured.
    public static func leftovers(for app: InstalledApp, home: URL, fullDiskAccess: Bool, cancel: Cancellation) -> [Leftover] {
        var names = [app.name, app.url.deletingPathExtension().lastPathComponent]
        if let bundleName = Bundle(url: app.url)?.infoDictionary?["CFBundleName"] as? String { names.append(bundleName) }
        names = Array(Set(names))
        var found: [Leftover] = []
        for place in places where fullDiskAccess || !place.guarded {
            let folder = home.appendingPathComponent(place.folder)
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where place.matches(entry, app.bundleID, names) {
                found.append(Leftover(url: folder.appendingPathComponent(entry), kind: place.kind))
            }
        }
        // Vendors often nest: com.google.Chrome keeps "Application Support/Google/Chrome".
        let parts = app.bundleID.split(separator: ".")
        if parts.count >= 3 {
            let vendor = String(parts[1]), product = String(parts[parts.count - 1])
            let support = home.appendingPathComponent("Library/Application Support")
            for vendorFolder in (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
            where vendorFolder.caseInsensitiveCompare(vendor) == .orderedSame {
                for entry in (try? FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent(vendorFolder).path)) ?? []
                where entry.caseInsensitiveCompare(product) == .orderedSame || named(entry, names) {
                    found.append(Leftover(url: support.appendingPathComponent(vendorFolder).appendingPathComponent(entry), kind: "Support files"))
                }
            }
        }
        var unique: [Leftover] = []
        for leftover in found where !unique.contains(where: { $0.url.path == leftover.url.path }) { unique.append(leftover) }
        let usages = Catalog.measure(unique.map(\.url), cancel: cancel)
        return unique.enumerated().map { index, leftover in
            var measured = leftover
            measured.usage = usages[index]
            return measured
        }.sorted { $0.usage.bytes > $1.usage.bytes }
    }

    /// Identifier prefixes that name a code host rather than a company: "com.github.facebook.watchman" has nothing
    /// to do with GitHub Desktop, so these never tie one program to another.
    public static let hostPrefixes: Set<String> = ["com.github", "io.github", "com.gitlab", "io.gitlab", "org.sourceforge",
                                                   "net.sourceforge", "com.bitbucket", "org.bitbucket", "com.googlecode"]

    /// The company part of an identifier ("com.adobe"), or nil when that part names a code host.
    public static func company(of id: String) -> String? {
        let parts = id.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let company = parts.prefix(2).joined(separator: ".")
        return hostPrefixes.contains(company.lowercased()) ? nil : company
    }

    /// Names macOS itself uses in /Library's Application Support, Preferences, Caches and Logs.
    public static let systemNames: Set<String> = [
        "App Store", "Apple", "BTServer", "CrashReporter", "GarageBand", "Logic", "ProApps", "Script Editor", "iLifeMediaBrowser", "livefsd",
        "features.cfg", "Audio", "DirectoryService", "Logging", "OpenDirectory", "SystemConfiguration", "Xsan", "ColorSync", "Desktop Pictures",
        "DiagnosticReports", "LKDC-setup.log", "MCXTools.log", "WindowServer", "hidfw-crashlogs", "MobileSync", "iCloud", "Bluetooth",
        "AppleMediaServices", "Fonts", "Managed Preferences", "Keychains", "Printers", "PreferencePanes", "Mail", "Messages", "Photos", "Safari",
        "Siri", "Spotlight", "SoftwareUpdate", "Mobile Documents", "DiskImages", "MRT", "XProtect", "Dock", "Finder", "CoreAnalytics", "powerlog",
        "ApplePushService", "MobileDevice", "Recovery", "KernelCollections", "Developer", "Caches", "Logs", "com.apple", "AssetCache", "ARDAgent",
        "Image Capture", "Screen Savers", "Desktop Background", "Wallpaper", "PrivilegedHelperTools", "TrustedHosts", "Classic", "Documentation"
    ]

    /// Identifiers of open-source parts of macOS that don't start with com.apple.
    static let systemIdentifierPrefixes = ["org.cups.", "com.openssh.", "org.ntp.", "org.openldap.", "org.postfix.", "edu.mit.kerberos", "org.isc.", "com.vix."]

    /// Leftovers in /Library, shared by every account: files named after a bundle identifier no installed app uses
    /// (as for your own Library), and folders in Application Support, Preferences and Caches named after a company or
    /// product nothing on the Mac has.
    ///
    /// - Parameter nameInUse: whether anything installed or running goes by this name ("VMware", "Logitech").
    public static func systemLeftovers(root: URL = URL(fileURLWithPath: "/"), cancel: Cancellation, now: Date = Date(),
                                       companyInUse: (String) -> Bool, nameInUse: (String) -> Bool,
                                       origin: (URL) -> Origin, inUse: (String) -> Bool) -> [Orphan] {
        // Stricter than for your own Library: files every account shares are left alone whenever anything from the same
        // company is still installed, however long ago they changed (Adobe's licensing files while Creative Cloud is there).
        var found = orphans(home: root, fullDiskAccess: false, cancel: cancel, now: now, companyInUse: companyInUse) { id in
            inUse(id) || systemIdentifierPrefixes.contains { id.lowercased().hasPrefix($0) }
        }.filter { orphan in company(of: orphan.bundleID).map { !companyInUse($0) } ?? true }
        for folder in ["Library/Application Support", "Library/Preferences", "Library/Caches"] {
            let base = root.appendingPathComponent(folder)
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
                let bare = entry.replacingOccurrences(of: ".localized", with: "")
                guard !entry.hasPrefix("."), !entry.hasPrefix("com.apple"), identifier(in: entry) == nil, !entry.hasPrefix("regid."),
                      !systemNames.contains(bare), !systemNames.contains(entry), !nameInUse(bare) else { continue }
                let url = base.appendingPathComponent(entry)
                // Installed by macOS or Apple's own installers, such as GarageBand's loops.
                guard origin(url) == .thirdParty else { continue }
                let kind = folder.hasSuffix("Preferences") ? "Settings" : folder.hasSuffix("Caches") ? "Caches" : "Support files"
                let usage = DiskUsage.measure(url, cancel: cancel)
                if let index = found.firstIndex(where: { $0.bundleID == bare }) {
                    found[index].leftovers.append(Leftover(url: url, kind: kind, usage: usage))
                } else {
                    found.append(Orphan(bundleID: bare, leftovers: [Leftover(url: url, kind: kind, usage: usage)], newest: Catalog.modified(url)))
                }
            }
        }
        // Shortcuts in /Applications to apps that are gone, and folders holding nothing else (an uninstaller's leftovers).
        let applications = root.appendingPathComponent("Applications")
        for entry in Catalog.listIncludingLinks(applications) where entry.pathExtension != "app" {
            guard isDeadShortcut(entry) || isFolderOfDeadShortcuts(entry) else { continue }
            found.append(Orphan(bundleID: entry.lastPathComponent, leftovers: [Leftover(url: entry, kind: "Shortcuts to a removed app", usage: DiskUsage.measure(entry))],
                                newest: Catalog.modified(entry)))
        }
        return found.map { var orphan = $0; orphan.forAllUsers = true; return orphan }.sorted { $0.bytes > $1.bytes }
    }

    static func isDeadShortcut(_ url: URL) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return false }
        let absolute = target.hasPrefix("/") ? target : url.deletingLastPathComponent().appendingPathComponent(target).path
        return !FileManager.default.fileExists(atPath: absolute)
    }

    /// A folder that holds only shortcuts to missing apps, and perhaps a custom folder icon.
    static func isFolderOfDeadShortcuts(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true else { return false }
        let entries = Catalog.listIncludingLinks(url).filter { $0.lastPathComponent != "Icon\r" && $0.lastPathComponent != "Icon" }
        return !entries.isEmpty && entries.allSatisfy(isDeadShortcut)
    }

    /// Looks like a bundle identifier: three or more dot-separated parts, starting with a letter.
    static func looksLikeIdentifier(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let first = text.first, first.isLetter else { return false }
        return parts.allSatisfy { part in !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    /// The bundle identifier an entry in ~/Library is named after, if any.
    public static func identifier(in entry: String) -> String? {
        var name = entry
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        guard looksLikeIdentifier(name), !name.hasPrefix("com.apple."), !name.hasPrefix("group."), !name.hasPrefix("systemgroup."),
              !name.hasPrefix("regid.") else { return nil }
        return name
    }

    /// Entries in ~/Library named after a bundle identifier that no installed app, helper or running process has.
    /// Folders named after an app's display name can't be tied to an app reliably and are never listed.
    ///
    /// - Parameter inUse: whether an identifier belongs to something on this Mac. Called with the identifier and
    ///   each shorter prefix of three or more parts, so "com.vendor.app.helper" is kept while "com.vendor.app" exists.
    /// - Parameter companyInUse: whether something on this Mac comes from the company prefix ("com.adobe"). Files of
    ///   such a company that changed in the last month are left out: its other software is probably still using them.
    public static func orphans(home: URL, fullDiskAccess: Bool, cancel: Cancellation, now: Date = Date(),
                               companyInUse: (String) -> Bool = { _ in false }, inUse: (String) -> Bool) -> [Orphan] {
        // Caches of command-line tools, such as SwiftPM's, are listed under package caches instead.
        let tools = Set(Catalog.packageCaches.map { home.appendingPathComponent($0.1).path })
        var groups: [String: [Leftover]] = [:]
        var verdicts: [String: Bool] = [:]
        func owned(_ id: String) -> Bool {
            if let known = verdicts[id] { return known }
            var parts = id.split(separator: ".").map(String.init)
            var result = false
            while parts.count >= 3 {
                if inUse(parts.joined(separator: ".")) { result = true; break }
                parts.removeLast()
            }
            verdicts[id] = result
            return result
        }
        for place in places where (fullDiskAccess || !place.guarded) && place.folder != "Library/LaunchAgents" {
            let folder = home.appendingPathComponent(place.folder)
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard let id = identifier(in: entry), !owned(id), !tools.contains(folder.appendingPathComponent(entry).path) else { continue }
                // ByHost settings carry the Mac's hardware UUID after the identifier.
                var key = id
                if place.folder.hasSuffix("ByHost"), let range = key.range(of: ".", options: .backwards) { key = String(key[..<range.lowerBound]) }
                groups[key, default: []].append(Leftover(url: folder.appendingPathComponent(entry), kind: place.kind))
            }
        }
        // Settings and support files of one app often go by slightly different identifiers ("com.x.app" and
        // "com.x.app.helper"); file each under the shortest one that is also orphaned.
        let ids = groups.keys.sorted { $0.count < $1.count }
        var merged: [String: [Leftover]] = [:]
        for id in ids {
            let parent = merged.keys.first { id.hasPrefix($0 + ".") }
            merged[parent ?? id, default: []] += groups[id] ?? []
        }
        let all = merged.flatMap { id, leftovers in leftovers.map { (id, $0) } }
        let usages = Catalog.measure(all.map(\.1.url), cancel: cancel)
        var measured: [String: [Leftover]] = [:]
        for (index, pair) in all.enumerated() {
            var leftover = pair.1
            leftover.usage = usages[index]
            measured[pair.0, default: []].append(leftover)
        }
        return measured.map { id, leftovers in
            Orphan(bundleID: id, leftovers: leftovers.sorted { $0.usage.bytes > $1.usage.bytes },
                   newest: leftovers.compactMap { Catalog.modified($0.url) }.max())
        }.filter { orphan in
            guard let company = company(of: orphan.bundleID) else { return true }
            let recent = orphan.newest.map { now.timeIntervalSince($0) < 30 * 86_400 } ?? false
            return !(recent && companyInUse(company))
        }.sorted { $0.bytes > $1.bytes }
    }
}
