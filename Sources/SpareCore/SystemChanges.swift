import Foundation

/// A change to how the Mac is set up rather than a file: accounts installers created, printers, VPN
/// configurations, configuration profiles, and privacy permissions given to apps.
public struct SystemChange: Identifiable, Sendable, Hashable {
    public enum Kind: String, CaseIterable, Sendable {
        case account = "Accounts", printer = "Printers", vpn = "VPN", profile = "Profiles", privacy = "Permissions"
    }

    /// What Spare can do about it.
    public enum Action: Sendable, Hashable {
        /// Delete a hidden account an installer created (needs an administrator).
        case deleteAccount(String)
        /// Remove an added printer (needs an administrator).
        case deletePrinter(String)
        /// Remove a privacy decision from macOS's permission database: for the whole Mac (`systemWide`, needs an
        /// administrator) or this account. `client` is a bundle identifier.
        case resetPrivacy(service: String, client: String, systemWide: Bool)
        /// Remove a configuration profile Spare installed (needs an administrator).
        case removeProfile(String)
        /// Remove a VPN configuration from Network settings by its name (needs an administrator).
        case removeConfiguration(String)
        /// Stop a VPN's own background service and move its launchd file to the Trash. `scope` is where the file is.
        case removeService(label: String, plist: String, scope: LaunchItem.Scope)
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
    /// How Spare connects and disconnects it, for a VPN it can.
    public var control: Control?
    /// Connected right now, when that's known.
    public var connected: Bool?

    /// Ways of connecting and disconnecting a VPN.
    public enum Control: Sendable, Hashable {
        /// A configuration macOS knows, by name: `scutil --nc start` and `stop`.
        case configuration(String)
        /// The VPN app's own command-line tool.
        case tool(path: String, connect: [String], disconnect: [String])
    }

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

    /// `scutil --nc list`: `* (Connected)  UUID VPN (io.vendor.app) "Name"  [VPN:io.vendor.app]`. Each can be connected
    /// and disconnected. One that came with macOS (no app named) or whose app is gone can be removed here; an app's own
    /// goes with the app, or in Network settings.
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
            let builtIn = bundle == nil || bundle!.hasPrefix("com.apple.")
            let gone = !builtIn && owner == nil
            var row = SystemChange(kind: .vpn, id: "vpn:" + name + (bundle ?? ""), name: name, detail: bundle,
                                   state: state, owner: builtIn ? "macOS" : owner, ownerGone: gone,
                                   action: builtIn || gone ? .removeConfiguration(name) : .settings(networkSettings))
            row.control = .configuration(name)
            row.connected = state == "Connected"
            return row
        }
    }

    /// Words in the label or program of a VPN app's own background service: VPNs that run their own tunnel rather
    /// than a configuration in Network settings, such as Mullvad's.
    public static let vpnServiceMarkers = [
        "mullvad", "openvpn", "wireguard", "tunnelblick", "viscosity", "nordvpn", "expressvpn", "protonvpn", "surfshark",
        "privateinternetaccess", "windscribe", "cyberghost", "ipvanish", "hotspotshield", "purevpn", "vyprvpn", "astrill",
        "anyconnect", "vpnagentd", "globalprotect", "paloaltonetworks", "forticlient", "fortinet", "pulsesecure", "ivanti",
        "zerotier", "cloudflare.1dot1dot1dot1", "warp-svc", "tailscaled", "netbird", "nebula", "zscaler", "twingate",
        "hamachi", "softether", "strongswan", "openconnect", "netextender", "perimeter81", "checkpoint.vpn"
    ]

    /// VPN apps' command-line tools: where the tool sits in the app, how it connects and disconnects, and how it
    /// reports. Its first line of `status` starts with "Connected" when it is.
    public static let vpnTools: [(label: String, path: String, connect: [String], disconnect: [String], status: [String])] = [
        ("net.mullvad.", "Contents/Resources/mullvad", ["connect"], ["disconnect"], ["status"])
    ]

    /// VPN apps' own background services among launchd jobs. `running` says whether a job's process is running,
    /// `status` runs a VPN tool with arguments and returns what it printed, and `appName` names the app at a URL.
    public static func vpnServices(_ jobs: [LaunchItem], running: (LaunchItem) -> Bool, status: (String, [String]) -> String?,
                                   appName: (URL) -> String?) -> [SystemChange] {
        jobs.compactMap { job in
            let text = ([job.label, job.program ?? ""] + job.associatedBundleIDs).joined(separator: " ").lowercased()
            guard vpnServiceMarkers.contains(where: { text.contains($0) }) else { return nil }
            let app = job.programApp
            let owner = app.flatMap(appName)
            var row = SystemChange(kind: .vpn, id: "vpn-service:" + job.label, name: owner ?? job.label,
                                   detail: "Its own background service, \(job.label)", state: running(job) ? "Running" : "Not running",
                                   owner: owner, ownerGone: !job.programExists,
                                   action: .removeService(label: job.label, plist: job.url.path, scope: job.scope))
            if let app, let tool = vpnTools.first(where: { job.label.hasPrefix($0.label) }) {
                let path = app.appendingPathComponent(tool.path).path
                row.control = .tool(path: path, connect: tool.connect, disconnect: tool.disconnect)
                if let reply = status(path, tool.status)?.split(separator: "\n").first.map(String.init) {
                    row.connected = reply.hasPrefix("Connected")
                    row.state = row.connected == true ? "Connected" : reply.hasPrefix("Disconnected") ? "Disconnected" : reply
                }
            }
            return row
        }
    }

    // MARK: Profiles

    /// `profiles list`: lines such as "_computerlevel[1] attribute: profileIdentifier: com.vendor.profile".
    public static func profiles(_ text: String) -> [SystemChange] {
        text.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "profileIdentifier: ") else { return nil }
            let identifier = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let computer = line.contains("_computerlevel")
            if identifier == Debloat.profileIdentifier {
                return SystemChange(kind: .profile, id: "profile:" + identifier, name: "Spare Privacy",
                                    detail: "Made by Spare. Keeps what you switched off under Privacy & Debloat switched off.",
                                    state: "Installed", origin: .spare, action: .removeProfile(identifier))
            }
            return SystemChange(kind: .profile, id: "profile:" + identifier, name: identifier,
                                detail: computer ? "For the whole Mac" : "For your account",
                                origin: identifier.hasPrefix("com.apple.") ? .apple : .thirdParty, action: .settings(profilesSettings))
        }
    }

    /// `system_profiler -xml SPConfigurationProfileDataType`, which lists profiles for the whole Mac as well as the
    /// person's, without a password; `profiles list` shows only the person's unless run as root.
    public static func profiles(systemProfiler data: Data) -> [SystemChange] {
        guard let sections = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]] else { return [] }
        var rows: [SystemChange] = []
        for section in sections {
            for group in section["_items"] as? [[String: Any]] ?? [] {
                let computer = (group["_name"] as? String)?.contains("device") == true
                for profile in group["_items"] as? [[String: Any]] ?? [] {
                    guard let identifier = profile["spconfigprofile_profile_identifier"] as? String else { continue }
                    let name = profile["spconfigprofile_profile_name"] as? String ?? profile["_name"] as? String ?? identifier
                    let installed = (profile["spconfigprofile_install_date"] as? String).flatMap(installDate)
                    let when = installed.map { " · Installed " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
                    if identifier == Debloat.profileIdentifier {
                        // Spare's marker payload lists what it locks: tweaks = "analytics,siri,…".
                        let marker = (profile["_items"] as? [[String: Any]] ?? []).compactMap { $0["spconfigprofile_payload_data"] as? String }
                            .first { $0.contains(Debloat.profileIdentifier) }
                        let locked = marker.flatMap { text -> Int? in
                            guard let start = text.range(of: "tweaks = \""), let end = text[start.upperBound...].firstIndex(of: "\"") else { return nil }
                            return text[start.upperBound..<end].split(separator: ",").count
                        }
                        rows.append(SystemChange(kind: .profile, id: "profile:" + identifier, name: "Spare Privacy",
                                                 detail: "Made by Spare to keep what you switched off under Privacy & Debloat off" + when,
                                                 state: locked.map { "\($0) switched off" } ?? "Installed", origin: .spare, action: .removeProfile(identifier)))
                        continue
                    }
                    let organization = profile["spconfigprofile_organization"] as? String
                    let scope = computer ? "For the whole Mac" : "For your account"
                    rows.append(SystemChange(kind: .profile, id: "profile:" + identifier, name: name,
                                             detail: [organization, scope].compactMap { $0 }.joined(separator: " · ") + when,
                                             state: (profile["spconfigprofile_verification_state"] as? String).map { $0 == "verified" ? "Verified" : "Unsigned" },
                                             origin: identifier.hasPrefix("com.apple.") ? .apple : .thirdParty, action: .settings(profilesSettings)))
                }
            }
        }
        return rows
    }

    /// The date inside "Wednesday, 14. October 2026 at 01:53:35 CEST (2026-10-13 23:53:35 +0000)".
    static func installDate(_ text: String) -> Date? {
        guard let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: String(text[text.index(after: open)..<close]))
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

    /// The page in Privacy & Security that lists a service's permissions.
    public static func privacyPane(_ service: String) -> String {
        let panes = ["kTCCServiceSystemPolicyAllFiles": "AllFiles", "kTCCServiceListenEvent": "ListenEvent", "kTCCServiceAccessibility": "Accessibility",
                     "kTCCServicePostEvent": "Accessibility", "kTCCServiceScreenCapture": "ScreenCapture", "kTCCServiceCamera": "Camera",
                     "kTCCServiceMicrophone": "Microphone", "kTCCServiceSystemPolicyAppBundles": "AppBundles", "kTCCServiceDeveloperTool": "DevTools",
                     "kTCCServiceAppleEvents": "Automation", "kTCCServiceSystemPolicyAppData": "AppData", "kTCCServiceBluetoothAlways": "Bluetooth"]
        return "x-apple.systempreferences:com.apple.preference.security?Privacy" + (panes[service].map { "_" + $0 } ?? "")
    }

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
            // A program known by its path is removed from the database itself, as tccutil only takes bundle
            // identifiers. The whole Mac's database is protected by System Integrity Protection, even from an
            // administrator, so those are removed in System Settings, which may change it.
            let onlyInSettings = byPath && scope == "system"
            return SystemChange(kind: .privacy, id: "privacy:\(scope):\(service):\(client)", name: owner ?? client,
                                detail: [permission, byPath ? client : (owner == nil ? nil : client), modified.map { "decided " + Catalog.ago($0, from: Date()) },
                                         onlyInSettings ? "removed only in System Settings" : nil]
                                    .compactMap { $0 }.joined(separator: " · "),
                                state: state, owner: owner, ownerGone: gone,
                                action: onlyInSettings ? .settings(privacyPane(service))
                                    : .resetPrivacy(service: service, client: client, systemWide: scope == "system"))
        }
    }
}
