import Foundation

/// An add-on in a web browser. One that can read and change every website sees whatever is typed into them, passwords
/// included, so it's worth knowing which ones can and whether they're still wanted.
public struct BrowserExtension: Identifiable, Sendable, Equatable {
    public enum Browser: String, CaseIterable, Sendable {
        case chrome = "Google Chrome", chromeBeta = "Chrome Beta", chromeCanary = "Chrome Canary", brave = "Brave", edge = "Microsoft Edge",
             arc = "Arc", vivaldi = "Vivaldi", opera = "Opera", chromium = "Chromium", firefox = "Firefox", safari = "Safari"

        public var bundleID: String {
            switch self {
            case .chrome: "com.google.Chrome"
            case .chromeBeta: "com.google.Chrome.beta"
            case .chromeCanary: "com.google.Chrome.canary"
            case .brave: "com.brave.Browser"
            case .edge: "com.microsoft.edgemac"
            case .arc: "company.thebrowser.Browser"
            case .vivaldi: "com.vivaldi.Vivaldi"
            case .opera: "com.operasoftware.Opera"
            case .chromium: "org.chromium.Chromium"
            case .firefox: "org.mozilla.firefox"
            case .safari: "com.apple.Safari"
            }
        }

        /// Where a Chromium browser keeps its profiles, inside Application Support.
        var chromiumData: String? {
            switch self {
            case .chrome: "Google/Chrome"
            case .chromeBeta: "Google/Chrome Beta"
            case .chromeCanary: "Google/Chrome Canary"
            case .brave: "BraveSoftware/Brave-Browser"
            case .edge: "Microsoft Edge"
            case .arc: "Arc/User Data"
            case .vivaldi: "Vivaldi"
            case .opera: "com.operasoftware.Opera"
            case .chromium: "Chromium"
            case .firefox, .safari: nil
            }
        }
    }

    public var browser: Browser
    /// The profile's name as the browser shows it; nil for a browser with one.
    public var profile: String?
    public var extensionID: String
    public var name: String
    public var version: String?
    /// The extension's folder, Firefox's .xpi, or Safari's .appex.
    public var url: URL?
    public var bytes: Int64?
    public var enabled: Bool?
    /// Installed from the browser's own store; nil when unknown.
    public var fromStore: Bool?
    /// Can read and change every website.
    public var allSites: Bool
    /// Safari: the app it came with.
    public var containingApp: URL?
    public var id: String { "\(browser.rawValue)|\(profile ?? "")|\(extensionID)" }

    public init(browser: Browser, profile: String? = nil, extensionID: String, name: String, version: String? = nil, url: URL? = nil,
                bytes: Int64? = nil, enabled: Bool? = nil, fromStore: Bool? = nil, allSites: Bool = false, containingApp: URL? = nil) {
        self.browser = browser; self.profile = profile; self.extensionID = extensionID; self.name = name; self.version = version
        self.url = url; self.bytes = bytes; self.enabled = enabled; self.fromStore = fromStore; self.allSites = allSites
        self.containingApp = containingApp
    }
}

public enum BrowserExtensions {
    // MARK: - Chromium

    /// Extensions of every profile of Chrome, Brave, Edge, Arc, Vivaldi, Opera and Chromium.
    public static func chromium(home: URL) -> [BrowserExtension] {
        let support = home.appendingPathComponent("Library/Application Support")
        var found: [BrowserExtension] = []
        for browser in BrowserExtension.Browser.allCases {
            guard let data = browser.chromiumData else { continue }
            let root = support.appendingPathComponent(data)
            let names = profileNames(root)
            var profiles = Catalog.list(root).filter { exists($0.appendingPathComponent("Preferences")) }
                .map { (folder: $0, name: Optional(names[$0.lastPathComponent] ?? $0.lastPathComponent)) }
            // Opera keeps its only profile in the top folder.
            if exists(root.appendingPathComponent("Preferences")) { profiles.insert((root, nil), at: 0) }
            for (folder, name) in profiles {
                found += extensions(in: folder, browser: browser, profileName: name)
            }
        }
        return found
    }

    /// Profile folder → the name the browser shows, from `Local State`.
    static func profileNames(_ root: URL) -> [String: String] {
        guard let state = json(root.appendingPathComponent("Local State")),
              let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (folder, info) in cache {
            if let name = (info as? [String: Any])?["name"] as? String, !name.isEmpty { names[folder] = name }
        }
        return names
    }

    static func extensions(in profile: URL, browser: BrowserExtension.Browser, profileName: String?) -> [BrowserExtension] {
        var settings: [String: Any] = [:]
        // Chrome keeps most extension settings in Secure Preferences, other browsers in Preferences.
        for file in ["Preferences", "Secure Preferences"] {
            let entries = ((json(profile.appendingPathComponent(file))?["extensions"] as? [String: Any])?["settings"] as? [String: Any]) ?? [:]
            settings.merge(entries) { $1 }
        }
        var found: [BrowserExtension] = []
        for folder in Catalog.list(profile.appendingPathComponent("Extensions")) {
            let id = folder.lastPathComponent
            guard !id.hasPrefix("."), id != "Temp" else { continue }
            // Each update gets its own folder, "1.2.3_0"; the newest is the one in use.
            let versions = Catalog.list(folder).filter { exists($0.appendingPathComponent("manifest.json")) }
            guard let newest = versions.max(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }),
                  let manifest = json(newest.appendingPathComponent("manifest.json")),
                  let name = displayName(manifest, folder: newest) else { continue }
            let setting = settings[id] as? [String: Any]
            found.append(BrowserExtension(browser: browser, profile: profileName, extensionID: id, name: name,
                                          version: manifest["version"] as? String, url: folder, bytes: DiskUsage.measure(folder).bytes,
                                          enabled: setting.map(enabled), fromStore: fromStore(manifest, setting: setting),
                                          allSites: allSites(manifest), containingApp: nil))
        }
        return found
    }

    /// The manifest's name, with "__MSG_extName__" looked up in the extension's translations. nil for helpers without one.
    static func displayName(_ manifest: [String: Any], folder: URL) -> String? {
        for key in ["name", "short_name"] {
            guard let raw = manifest[key] as? String, !raw.isEmpty else { continue }
            guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__"), raw.count > 8 else { return raw }
            let message = String(raw.dropFirst(6).dropLast(2)).lowercased()
            let preferred = [manifest["default_locale"] as? String, "en", "en_US", "en_GB"].compactMap { $0 }
            let locales = folder.appendingPathComponent("_locales")
            let others = Catalog.list(locales).map(\.lastPathComponent).filter { !preferred.contains($0) }
            for locale in preferred + others {
                guard let messages = json(locales.appendingPathComponent(locale).appendingPathComponent("messages.json")) else { continue }
                // Keys are matched without regard to case, as browsers do.
                if let entry = messages.first(where: { $0.key.lowercased() == message })?.value as? [String: Any],
                   let text = entry["message"] as? String, !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// From the extension's settings: disable reasons, or the older on/off state. Listed without either means on.
    static func enabled(_ setting: [String: Any]) -> Bool {
        switch setting["disable_reasons"] {
        case let reasons as [Any]: return reasons.isEmpty
        case let reasons as NSNumber: return reasons.intValue == 0
        default: break
        }
        if let state = setting["state"] as? NSNumber { return state.intValue == 1 }
        return true
    }

    /// Hosts of the stores' update servers. An extension from elsewhere names its own, or none.
    static let storeHosts: Set<String> = ["clients2.google.com", "edge.microsoft.com", "extension-updates.opera.com"]

    static func fromStore(_ manifest: [String: Any], setting: [String: Any]?) -> Bool? {
        if let update = manifest["update_url"] as? String, let host = URL(string: update)?.host?.lowercased() { return storeHosts.contains(host) }
        if let store = setting?["from_webstore"] as? Bool { return store }
        // Loaded unpacked, from a folder on disk.
        if (setting?["location"] as? NSNumber)?.intValue == 4 { return false }
        return nil
    }

    static func allSites(_ manifest: [String: Any]) -> Bool {
        var patterns = (manifest["permissions"] as? [Any] ?? []) + (manifest["host_permissions"] as? [Any] ?? [])
        for case let script as [String: Any] in manifest["content_scripts"] as? [Any] ?? [] { patterns += script["matches"] as? [Any] ?? [] }
        return patterns.contains { ($0 as? String).map(isEverySite) == true }
    }

    /// "<all_urls>", "*://*/*", "https://*/*": patterns that match every website.
    static func isEverySite(_ pattern: String) -> Bool {
        if pattern == "<all_urls>" { return true }
        guard let range = pattern.range(of: "://") else { return false }
        let scheme = pattern[..<range.lowerBound], rest = pattern[range.upperBound...]
        return ["*", "http", "https"].contains(scheme) && rest.prefix { $0 != "/" } == "*"
    }

    // MARK: - Firefox

    /// Extensions people added to each Firefox profile. Firefox's own built-in ones are left out.
    public static func firefox(home: URL) -> [BrowserExtension] {
        let support = home.appendingPathComponent("Library/Application Support/Firefox")
        let names = firefoxProfileNames(support.appendingPathComponent("profiles.ini"))
        var found: [BrowserExtension] = []
        for profile in Catalog.list(support.appendingPathComponent("Profiles")) {
            guard let addons = json(profile.appendingPathComponent("extensions.json"))?["addons"] as? [[String: Any]] else { continue }
            let folder = profile.lastPathComponent
            // "x1y2z3.default-release" is shown as default-release when profiles.ini doesn't name it.
            let profileName = names[folder] ?? folder.split(separator: ".", maxSplits: 1).last.map(String.init) ?? folder
            for addon in addons where addon["type"] as? String == "extension" && addon["location"] as? String == "app-profile" {
                guard let id = addon["id"] as? String else { continue }
                let name = ((addon["defaultLocale"] as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
                let url = (addon["path"] as? String).map { URL(fileURLWithPath: $0) }
                let origins = (addon["userPermissions"] as? [String: Any])?["origins"] as? [String] ?? []
                found.append(BrowserExtension(browser: .firefox, profile: profileName, extensionID: id, name: name,
                                              version: addon["version"] as? String, url: url, bytes: url.flatMap(allocated),
                                              enabled: addon["active"] as? Bool, fromStore: firefoxFromStore(addon),
                                              allSites: origins.contains(where: isEverySite), containingApp: nil))
            }
        }
        return found
    }

    /// Where it was installed from, else whether Mozilla signed it after review.
    static func firefoxFromStore(_ addon: [String: Any]) -> Bool? {
        if let source = (addon["installTelemetryInfo"] as? [String: Any])?["source"] as? String, source != "unknown" {
            return source == "amo" || source == "disco"
        }
        return (addon["signedState"] as? NSNumber).map { $0.intValue == 2 }
    }

    /// Profile folder → name, from profiles.ini.
    static func firefoxProfileNames(_ file: URL) -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var names: [String: String] = [:]
        var name: String?, path: String?
        func finish() {
            if let name, let path, let folder = path.split(separator: "/").last { names[String(folder)] = name }
            name = nil; path = nil
        }
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { finish(); continue }
            if line.hasPrefix("Name=") { name = String(line.dropFirst(5)) }
            if line.hasPrefix("Path=") { path = String(line.dropFirst(5)) }
        }
        finish()
        return names
    }

    // MARK: - Safari

    /// Safari's extensions from `pluginkit -mAvvv -p com.apple.Safari.web-extension` (and com.apple.Safari.extension,
    /// com.apple.Safari.content-blocker). A leading "+" means it was switched on, "-" off; nothing, no choice recorded.
    public static func safari(pluginkit: String) -> [BrowserExtension] {
        var found: [BrowserExtension] = []
        var header: (marker: Character?, id: String, version: String?)?
        var fields: [String: String] = [:]
        func finish() {
            defer { header = nil; fields = [:] }
            guard let header else { return }
            found.append(safariExtension(id: header.id, version: header.version, marker: header.marker, fields: fields))
        }
        for line in pluginkit.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { finish(); continue }
            // "\t    Display Name = Bitwarden"
            if let separator = trimmed.range(of: " = ") {
                fields[String(trimmed[..<separator.lowerBound])] = String(trimmed[separator.upperBound...])
                continue
            }
            finish()
            var rest = Substring(line)
            let marker = rest.first.flatMap { "+-!=?".contains($0) ? $0 : nil }
            if marker != nil { rest = rest.dropFirst() }
            let entry = rest.trimmingCharacters(in: .whitespaces)
            // " (5 plug-ins)" closes the list.
            guard !entry.hasPrefix("("), let open = entry.lastIndex(of: "("), entry.hasSuffix(")") else { continue }
            let id = String(entry[..<open])
            guard !id.isEmpty else { continue }
            header = (marker, id, String(entry[entry.index(after: open)..<entry.index(before: entry.endIndex)]))
        }
        finish()
        // The same extension can be registered from several copies of its app; the newest counts.
        var newest: [String: BrowserExtension] = [:]
        var order: [String] = []
        for item in found {
            if let known = newest[item.extensionID] {
                if (item.version ?? "").compare(known.version ?? "", options: .numeric) == .orderedDescending { newest[item.extensionID] = item }
            } else {
                newest[item.extensionID] = item
                order.append(item.extensionID)
            }
        }
        return order.compactMap { newest[$0] }
    }

    /// Names that say nothing, such as an Xcode template's "Extension".
    static let genericNames: Set<String> = ["extension", "safari extension", "web extension", "safari web extension", "mac extension"]

    static func safariExtension(id: String, version: String?, marker: Character?, fields: [String: String]) -> BrowserExtension {
        let appex = fields["Path"].map { URL(fileURLWithPath: $0) }
        let parent = fields["Parent Bundle"].map { URL(fileURLWithPath: $0) }
        let resources = appex?.appendingPathComponent("Contents/Resources")
        let manifest = resources.flatMap { json($0.appendingPathComponent("manifest.json")) }
        var name = fields["Display Name"] ?? ""
        if genericNames.contains(name.lowercased()) || name.isEmpty {
            name = manifest.flatMap { manifest in resources.flatMap { displayName(manifest, folder: $0) } } ?? ""
        }
        if genericNames.contains(name.lowercased()) || name.isEmpty { name = fields["Parent Name"] ?? fields["Short Name"] ?? id }

        var everySite = false
        switch fields["SDK"] {
        case "com.apple.Safari.web-extension": everySite = manifest.map(allSites) ?? false
        case "com.apple.Safari.extension":
            // Older Safari app extensions say in their Info.plist which websites they may use.
            let info = appex.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) as? [String: Any] }
            let access = ((info?["NSExtension"] as? [String: Any])?["SFSafariWebsiteAccess"] as? [String: Any])?["Level"] as? String
            everySite = access == "All"
        default: break   // Content blockers only hand Safari a list of rules.
        }
        var fromStore: Bool?
        if let parent, exists(parent) { fromStore = exists(parent.appendingPathComponent("Contents/_MASReceipt/receipt")) }
        return BrowserExtension(browser: .safari, profile: nil, extensionID: id, name: name, version: version, url: appex,
                                bytes: appex.flatMap { exists($0) ? DiskUsage.measure($0).bytes : nil },
                                enabled: marker == "+" ? true : marker == "-" ? false : nil, fromStore: fromStore,
                                allSites: everySite, containingApp: parent)
    }

    // MARK: - Helpers

    static func json(_ url: URL) -> [String: Any]? {
        guard var data = FileManager.default.contents(atPath: url.path) else { return nil }
        // Some translation files start with a byte order mark, which JSON doesn't allow.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func allocated(_ url: URL) -> Int64? {
        var stats = stat()
        return lstat(url.path, &stats) == 0 ? Int64(stats.st_blocks) * 512 : nil
    }
}
