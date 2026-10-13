import Foundation

/// Something installed into macOS beyond apps: drivers, system extensions, plug-ins, fonts, input methods and the like.
public struct Extension: Identifiable, Sendable, Hashable {
    public enum Category: String, CaseIterable, Sendable {
        case system = "System Extensions"
        case kernel = "Kernel Extensions"
        case audioDrivers = "Audio Drivers"
        case audioPlugIns = "Audio Plug-ins"
        case camera = "Camera Plug-ins"
        case printers = "Printers and Scanners"
        case input = "Input Methods and Keyboards"
        case quickLook = "Quick Look and Spotlight"
        case panes = "Settings Panes"
        case screenSavers = "Screen Savers"
        case fonts = "Fonts"
        case services = "Services and Workflows"
        case internet = "Internet Plug-ins"
        case colorPickers = "Color Pickers"
        case receipts = "Installer Packages"

        public var symbol: String {
            switch self {
            case .system: "puzzlepiece.extension"
            case .kernel: "cpu"
            case .audioDrivers: "hifispeaker"
            case .audioPlugIns: "waveform"
            case .camera: "web.camera"
            case .printers: "printer"
            case .input: "keyboard"
            case .quickLook: "eye"
            case .panes: "gearshape"
            case .screenSavers: "sparkles.tv"
            case .fonts: "textformat"
            case .services: "gearshape.2"
            case .internet: "globe"
            case .colorPickers: "eyedropper"
            case .receipts: "shippingbox"
            }
        }

        public var explanation: String {
            switch self {
            case .system: "Drivers, network filters, VPNs and virtual cameras apps add to macOS. They go away when you uninstall their app."
            case .kernel: "Older-style drivers that load into macOS's core. Removing one takes effect after a restart."
            case .audioDrivers: "Virtual and device audio drivers, such as loopback devices and equalisers. Removing one restarts the audio system."
            case .audioPlugIns: "Effects and instruments for music apps: Audio Units, VST and VST3."
            case .camera: "Older-style virtual camera drivers."
            case .printers: "Printer and scanner drivers."
            case .input: "Extra input methods and keyboard layouts."
            case .quickLook: "Previews and search importers for file types."
            case .panes: "Panes added to System Settings."
            case .screenSavers: "Screen savers you added."
            case .fonts: "Fonts installed for you or for every account."
            case .services: "Quick Actions and Automator workflows in the Services menu."
            case .internet: "Browser plug-ins from before browsers stopped using them."
            case .colorPickers: "Extra panels for the system colour picker."
            case .receipts: "Installers that put files around the system. Spare lists them so you know what was installed; the files are listed in the other groups."
            }
        }

        /// Folders this kind of thing lives in, from the home folder ("~/") or the root.
        public var folders: [String] {
            switch self {
            case .system, .receipts: []
            case .kernel: ["/Library/Extensions"]
            case .audioDrivers: ["/Library/Audio/Plug-Ins/HAL"]
            case .audioPlugIns: ["~/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/Components", "~/Library/Audio/Plug-Ins/VST",
                                 "/Library/Audio/Plug-Ins/VST", "~/Library/Audio/Plug-Ins/VST3", "/Library/Audio/Plug-Ins/VST3"]
            case .camera: ["/Library/CoreMediaIO/Plug-Ins/DAL"]
            case .printers: ["/Library/Printers", "/Library/Image Capture/Devices"]
            case .input: ["~/Library/Input Methods", "/Library/Input Methods", "~/Library/Keyboard Layouts", "/Library/Keyboard Layouts"]
            case .quickLook: ["~/Library/QuickLook", "/Library/QuickLook", "~/Library/Spotlight", "/Library/Spotlight"]
            case .panes: ["~/Library/PreferencePanes", "/Library/PreferencePanes"]
            case .screenSavers: ["~/Library/Screen Savers", "/Library/Screen Savers"]
            case .fonts: ["~/Library/Fonts", "/Library/Fonts"]
            case .services: ["~/Library/Services"]
            case .internet: ["~/Library/Internet Plug-Ins", "/Library/Internet Plug-Ins"]
            case .colorPickers: ["~/Library/ColorPickers", "/Library/ColorPickers"]
            }
        }
    }

    public let category: Category
    public let name: String
    public let url: URL?
    public var detail: String?
    public var origin: Origin
    /// In /Library: shared by every account, removing it needs an administrator password.
    public var forAllUsers: Bool
    /// For system extensions: what macOS says about it, such as "activated enabled".
    public var state: String?
    /// The app it belongs to, for things removed by uninstalling that app.
    public var owner: String?
    public var bytes: Int64?
    public var id: String { category.rawValue + ":" + (url?.path ?? name) }

    /// Spare can move it to the Trash itself. System extensions and installer receipts are removed another way.
    public var removable: Bool { origin.removable && url != nil && category != .system && category != .receipts }

    public init(category: Category, name: String, url: URL?, detail: String? = nil, origin: Origin, forAllUsers: Bool,
                state: String? = nil, owner: String? = nil, bytes: Int64? = nil) {
        self.category = category; self.name = name; self.url = url; self.detail = detail; self.origin = origin
        self.forAllUsers = forAllUsers; self.state = state; self.owner = owner; self.bytes = bytes
    }
}

public enum Extensions {
    /// Everything in the folders of a category. Folders that only hold macOS's own furniture (PPDs, icons) are skipped.
    public static func scan(_ category: Extension.Category, home: URL) -> [Extension] {
        var entries: [(URL, Bool)] = []
        for folder in category.folders {
            let url = folder.hasPrefix("~/") ? home.appendingPathComponent(String(folder.dropFirst(2))) : URL(fileURLWithPath: folder)
            for entry in Catalog.list(url) where !ignored.contains(entry.lastPathComponent) { entries.append((entry, !folder.hasPrefix("~/"))) }
        }
        var found = [Extension?](repeating: nil, count: entries.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: entries.count) { index in
            let (entry, allUsers) = entries[index]
            // Installers put things in /Library; what's in a home folder was copied there, so its receipt isn't looked up.
            let origin: Origin = allUsers ? Origins.origin(of: entry) : (Origins.signedByApple(entry) ? .apple : .thirdParty)
            let version = Bundle(url: entry)?.infoDictionary?["CFBundleShortVersionString"] as? String
            let kind = folderKinds[entry.pathExtension.lowercased()]
            let detail = [kind, version.map { "Version " + $0 }].compactMap { $0 }.joined(separator: " · ")
            let item = Extension(category: category, name: entry.deletingPathExtension().lastPathComponent, url: entry,
                                 detail: detail.isEmpty ? nil : detail, origin: origin, forAllUsers: allUsers, bytes: DiskUsage.measure(entry).bytes)
            lock.lock(); found[index] = item; lock.unlock()
        }
        return found.compactMap { $0 }
    }

    /// Entries that are part of the folder structure rather than something installed.
    static let ignored: Set<String> = [".localized", "PPDs", "Icons", "ExtensionsCache", "plugins-info.txt", "Desktop Pictures"]

    static let folderKinds: [String: String] = [
        "kext": "Kernel extension", "driver": "Driver", "plugin": "Plug-in", "component": "Audio Unit", "vst": "VST", "vst3": "VST3",
        "app": "App", "bundle": "Bundle", "qlgenerator": "Quick Look", "mdimporter": "Spotlight", "prefpane": "Settings pane",
        "saver": "Screen saver", "workflow": "Workflow", "ttf": "TrueType font", "otf": "OpenType font", "ttc": "Font collection",
        "keylayout": "Keyboard layout", "colorpicker": "Color picker", "inputmethod": "Input method"
    ]

    /// `systemextensionsctl list`: a header per kind, then tab-separated rows.
    public static func systemExtensions(_ text: String) -> [Extension] {
        var found: [Extension] = []
        var kind = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("--- ") {
                let id = line.dropFirst(4).split(separator: " ").first.map(String.init) ?? ""
                kind = [
                    "com.apple.system_extension.cmio": "Camera extension",
                    "com.apple.system_extension.network_extension": "Network extension",
                    "com.apple.system_extension.driver_extension": "Driver",
                    "com.apple.system_extension.endpoint_security": "Security extension"
                ][id] ?? "System extension"
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { String($0) }
            guard fields.count >= 6, fields[2] != "teamID" else { continue }
            let identifier = fields[3]
            let bundleID = identifier.components(separatedBy: " (").first ?? identifier
            let version = identifier.range(of: "(").map { String(identifier[$0.upperBound...]).replacingOccurrences(of: ")", with: "") }
            let state = fields[5].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            let name = fields[4].isEmpty ? bundleID : fields[4]
            found.append(Extension(category: .system, name: name, url: nil,
                                   detail: [kind, version.map { "Version " + ($0.components(separatedBy: "/").first ?? $0) }, bundleID].compactMap { $0 }.joined(separator: " · "),
                                   origin: bundleID.hasPrefix("com.apple.") ? .macOS : .thirdParty, forAllUsers: true, state: state))
        }
        return found
    }

    /// Installer packages other than Apple's, from `pkgutil --pkgs`.
    public static func receipts(_ text: String) -> [Extension] {
        text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("com.apple.") && !$0.isEmpty }.map { id in
            Extension(category: .receipts, name: id, url: nil, detail: nil, origin: .thirdParty, forAllUsers: true)
        }
    }
}

/// Time Machine's local snapshots: hourly copies of the disk kept while the backup disk is away.
public struct LocalSnapshot: Identifiable, Sendable, Hashable {
    public let name: String
    public let date: Date?
    /// macOS has already given its space back; only the record remains.
    public let dataless: Bool
    public var id: String { name }
    /// The form `tmutil deletelocalsnapshots` takes: "2026-10-12-134623".
    public var stamp: String? {
        let parts = name.components(separatedBy: ".")
        return parts.first { $0.count == 17 && $0.filter { $0 == "-" }.count == 3 }
    }
}

public enum Snapshots {
    /// `tmutil listlocalsnapshots /`.
    public static func parse(_ text: String) -> [LocalSnapshot] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("com.apple.") else { return nil }
            let name = trimmed.components(separatedBy: " ").first ?? trimmed
            let snapshot = LocalSnapshot(name: name, date: nil, dataless: trimmed.contains("(dataless)"))
            return LocalSnapshot(name: name, date: snapshot.stamp.flatMap { formatter.date(from: $0) }, dataless: snapshot.dataless)
        }
    }
}
