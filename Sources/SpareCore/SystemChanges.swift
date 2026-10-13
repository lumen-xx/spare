import Foundation

/// A change to how the Mac is set up rather than a file: accounts installers created, printers, VPN
/// configurations, configuration profiles, and privacy permissions given to apps.
public struct SystemChange: Identifiable, Sendable, Hashable {
    public enum Kind: String, CaseIterable, Sendable {
        case account = "Accounts", printer = "Printers", vpn = "VPN", profile = "Profiles", privacy = "Privacy"
    }

    /// What Spare can do about it.
    public enum Action: Sendable, Hashable {
        /// Delete a hidden account an installer created (needs an administrator).
        case deleteAccount(String)
        /// Remove an added printer (needs an administrator).
        case deletePrinter(String)
        /// Forget a privacy decision, so the app has to ask again.
        case resetPrivacy(service: String, client: String)
        /// Only System Settings can change it.
        case settings(String)
    }

    public let kind: Kind
    public let id: String
    public var name: String
    public var detail: String?
    public var state: String?
    /// The app it belongs to.
    public var owner: String?
    /// Its app is no longer on this Mac.
    public var ownerGone = false
    public var origin: Origin
    public var action: Action

    public var removable: Bool {
        switch action {
        case .settings: false
        default: origin.removable
        }
    }

    public init(kind: Kind, id: String, name: String, detail: String? = nil, state: String? = nil, owner: String? = nil,
                ownerGone: Bool = false, origin: Origin = .thirdParty, action: Action) {
        self.kind = kind; self.id = id; self.name = name; self.detail = detail; self.state = state; self.owner = owner
        self.ownerGone = ownerGone; self.origin = origin; self.action = action
    }
}

public enum SystemChanges {
    public static let usersSettings = "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
    public static let networkSettings = "x-apple.systempreferences:com.apple.Network-Settings.extension"
    public static let profilesSettings = "x-apple.systempreferences:com.apple.Profiles-Settings.extension"

    // MARK: Accounts

    /// Accounts other than macOS's own (those have ids below 500) and the person's. `read` returns
    /// `dscl . -read /Users/<name>` for an account.
    public static func accounts(list: String, me: String, read: (String) -> String) -> [SystemChange] {
        list.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, let uid = Int(fields[fields.count - 1]), uid >= 500 else { return nil }
            let name = String(fields[0])
            guard name != me else { return nil }
            let record = parseRecord(read(name))
            let home = record["NFSHomeDirectory"] ?? ""
            let shell = record["UserShell"] ?? ""
            let realName = record["RealName"].flatMap { $0.isEmpty ? nil : $0 }
            // Installers create hidden service accounts: an underscore name, no home and no shell.
            let service = name.hasPrefix("_") && (home == "/var/empty" || home.isEmpty || shell == "/usr/bin/false")
            return SystemChange(kind: .account, id: "account:" + name, name: realName ?? name,
                                detail: service ? "Hidden account “\(name)” an installer created" : "\(name) · another person's account",
                                state: service ? "Hidden" : "Person", owner: nil, origin: .thirdParty,
                                action: service ? .deleteAccount(name) : .settings(usersSettings))
        }
    }

    /// `dscl . -read` output: "Key: value", or the key on its own line with the value indented below.
    static func parseRecord(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var pending: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(" "), let key = pending {
                result[key] = (result[key].map { $0.isEmpty ? "" : $0 + " " } ?? "") + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
            pending = value.isEmpty ? key : nil
        }
        return result
    }

    // MARK: Printers

    /// `lpstat -v` ("device for NAME: URI") and `lpstat -p` ("printer NAME is idle. …").
    public static func printers(devices: String, states: String) -> [SystemChange] {
        var status: [String: String] = [:]
        for line in states.split(separator: "\n") where line.hasPrefix("printer ") {
            let parts = line.dropFirst("printer ".count).components(separatedBy: " is ")
            if parts.count >= 2 { status[parts[0]] = parts[1].components(separatedBy: ".").first?.capitalized }
        }
        return devices.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("device for "), let colon = line.range(of: ": ") else { return nil }
            let queue = String(line[line.index(line.startIndex, offsetBy: "device for ".count)..<colon.lowerBound])
            let uri = String(line[colon.upperBound...])
            let connection = uri.hasPrefix("dnssd") || uri.hasPrefix("ipp") ? "On the network" : uri.hasPrefix("usb") ? "USB" : uri.components(separatedBy: ":").first ?? ""
            return SystemChange(kind: .printer, id: "printer:" + queue,
                                name: queue.replacingOccurrences(of: "_", with: " ").split(separator: " ").joined(separator: " "),
                                detail: connection, state: status[queue], action: .deletePrinter(queue))
        }
    }

    // MARK: VPN

    /// `scutil --nc list`: `* (Connected)  UUID VPN (io.vendor.app) "Name"  [VPN:io.vendor.app]`.
    public static func vpns(_ text: String, appName: (String) -> String?) -> [SystemChange] {
        text.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close,
                  let quoteStart = line.firstIndex(of: "\""), let quoteEnd = line.lastIndex(of: "\""), quoteStart < quoteEnd else { return nil }
            let state = String(line[line.index(after: open)..<close])
            let name = String(line[line.index(after: quoteStart)..<quoteEnd])
            let middle = line[line.index(after: close)..<quoteStart]
            let bundle = middle.firstIndex(of: "(").flatMap { start in
                middle.firstIndex(of: ")").map { String(middle[middle.index(after: start)..<$0]) }
            }
            let owner = bundle.flatMap(appName)
            return SystemChange(kind: .vpn, id: "vpn:" + name + (bundle ?? ""), name: name, detail: bundle,
                                state: state, owner: owner, ownerGone: bundle != nil && owner == nil, action: .settings(networkSettings))
        }
    }

    // MARK: Profiles

    /// `profiles list`: lines such as "_computerlevel[1] attribute: profileIdentifier: com.vendor.profile".
    public static func profiles(_ text: String) -> [SystemChange] {
        text.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "profileIdentifier: ") else { return nil }
            let identifier = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let computer = line.contains("_computerlevel")
            return SystemChange(kind: .profile, id: "profile:" + identifier, name: identifier,
                                detail: computer ? "For the whole Mac" : "For your account",
                                origin: identifier.hasPrefix("com.apple.") ? .apple : .thirdParty, action: .settings(profilesSettings))
        }
    }

    // MARK: Privacy

    /// Plain names for the privacy services in macOS's permission database.
    public static let services: [String: String] = [
        "kTCCServiceCamera": "Camera", "kTCCServiceMicrophone": "Microphone", "kTCCServiceScreenCapture": "Screen & System Audio Recording",
        "kTCCServiceAccessibility": "Accessibility", "kTCCServiceSystemPolicyAllFiles": "Full Disk Access",
        "kTCCServiceSystemPolicyDocumentsFolder": "Documents folder", "kTCCServiceSystemPolicyDesktopFolder": "Desktop folder",
        "kTCCServiceSystemPolicyDownloadsFolder": "Downloads folder", "kTCCServiceSystemPolicyNetworkVolumes": "Network volumes",
        "kTCCServiceSystemPolicyRemovableVolumes": "Removable volumes", "kTCCServiceSystemPolicyAppData": "Other apps' data",
        "kTCCServiceSystemPolicyAppBundles": "App Management", "kTCCServiceAppleEvents": "Automation", "kTCCServiceListenEvent": "Input Monitoring",
        "kTCCServicePostEvent": "Controlling the keyboard and mouse", "kTCCServicePhotos": "Photos", "kTCCServiceAddressBook": "Contacts",
        "kTCCServiceCalendar": "Calendars", "kTCCServiceReminders": "Reminders", "kTCCServiceMediaLibrary": "Media & Apple Music",
        "kTCCServiceSpeechRecognition": "Speech Recognition", "kTCCServiceBluetoothAlways": "Bluetooth", "kTCCServiceDeveloperTool": "Developer Tools",
        "kTCCServiceFileProviderDomain": "Files in cloud storage", "kTCCServiceUbiquity": "iCloud Drive", "kTCCServiceLiverpool": "iCloud",
        "kTCCServiceFocusStatus": "Focus", "kTCCServiceUserTracking": "Tracking", "kTCCServiceSystemPolicySysAdminFiles": "Administration files",
        "kTCCServiceEndpointSecurityClient": "Endpoint security", "kTCCServiceWillow": "Home", "kTCCServiceMotion": "Motion & Fitness"
    ]

    /// Rows of `select service, client, client_type, auth_value, last_modified from access`, separated by "|".
    /// macOS's own clients are left out: their permissions come with the system.
    public static func privacy(_ rows: String, scope: String, appName: (String) -> String?, exists: (String) -> Bool) -> [SystemChange] {
        rows.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, let type = Int(fields[2]), let value = Int(fields[3]) else { return nil }
            let service = fields[0], client = fields[1]
            if client.hasPrefix("com.apple.") || client.hasPrefix("/System/") || client.hasPrefix("/usr/libexec/") || client.hasPrefix("/usr/sbin/") { return nil }
            let byPath = type == 1
            let owner = byPath ? URL(fileURLWithPath: client).lastPathComponent : appName(client)
            let gone = byPath ? !exists(client) : owner == nil
            let state = value == 2 ? "Allowed" : value == 3 ? "Limited" : value == 0 ? "Denied" : "Asked"
            let permission = services[service] ?? service.replacingOccurrences(of: "kTCCService", with: "")
            let modified = fields.count > 4 ? TimeInterval(fields[4]).map { Date(timeIntervalSince1970: $0) } : nil
            return SystemChange(kind: .privacy, id: "privacy:\(scope):\(service):\(client)", name: owner ?? client,
                                detail: [permission, byPath ? client : (owner == nil ? nil : client), modified.map { "decided " + Catalog.ago($0, from: Date()) }]
                                    .compactMap { $0 }.joined(separator: " · "),
                                state: state, owner: owner, ownerGone: gone,
                                // tccutil only knows apps by bundle identifier; paths are changed in Privacy & Security settings.
                                action: byPath ? .settings("x-apple.systempreferences:com.apple.preference.security?Privacy")
                                    : .resetPrivacy(service: service.replacingOccurrences(of: "kTCCService", with: ""), client: client))
        }
    }
}
