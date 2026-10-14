import Foundation

/// Settings that keep a Mac private and quiet: Apple Intelligence and its models, what macOS shares with Apple, the
/// Apple apps nobody asked for, and small annoyances. Every change can be undone.
///
/// Settings macOS only lets a configuration profile lock go in one profile the person approves in System Settings;
/// removing it undoes all of them. The rest are written as `defaults write` writes them, with the value from before
/// kept to put back. The catalog and the keys follow RemoveMacAI (github.com/omlahore/RemoveMacAI, MIT), which builds
/// on pared (github.com/4evy/pared, MIT).
public enum Debloat {
    public enum Group: String, CaseIterable, Sendable {
        case intelligence, sharing, apps, annoyances
    }

    /// A preference value a tweak sets.
    public enum Value: Equatable, Codable, Sendable, CustomStringConvertible {
        case bool(Bool), int(Int), double(Double), string(String)

        public var object: CFPropertyList {
            switch self {
            case .bool(let v): v as CFBoolean
            case .int(let v): v as CFNumber
            case .double(let v): v as CFNumber
            case .string(let v): v as CFString
            }
        }

        public init?(_ any: Any?) {
            switch any {
            case let text as String: self = .string(text)
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
                else if CFNumberIsFloatType(number) { self = .double(number.doubleValue) }
                else { self = .int(number.intValue) }
            default: return nil
            }
        }

        /// Whether a stored value means the same. `-bool true` and `-int 1` both happen, so they match.
        public func matches(_ stored: Any?) -> Bool {
            guard let other = Value(stored) else { return false }
            switch (self, other) {
            case (.bool(let a), .int(let b)), (.int(let b), .bool(let a)): return (b != 0) == a
            case (.double(let a), .int(let b)), (.int(let b), .double(let a)): return a == Double(b)
            default: return self == other
            }
        }

        public var description: String {
            switch self {
            case .bool(let v): v ? "true" : "false"
            case .int(let v): String(v)
            case .double(let v): String(v)
            case .string(let v): "\"\(v)\""
            }
        }
    }

    /// One setting a tweak changes.
    public enum Change: Equatable, Sendable {
        /// A restriction the profile sets to false, in com.apple.applicationaccess.
        case restriction(String)
        /// A preference the profile forces, so it can't be changed back by hand.
        case forced(domain: String, key: String, Value)
        /// A preference of the person's own.
        case pref(domain: String, key: String, Value)
        /// A launchd agent in the person's session, disabled and stopped.
        case service(String)

        public var inProfile: Bool {
            switch self {
            case .restriction, .forced: true
            case .pref, .service: false
            }
        }

        /// What it amounts to, as a command or a profile line, for the review.
        public var command: String {
            switch self {
            case .restriction(let key): "Profile: \(key) = false"
            case .forced(let domain, let key, let value): "Profile: \(domain) \(key) = \(value), locked"
            case .pref(let domain, let key, let value): "defaults write \(domain) \(key) \(value)"
            case .service(let label): "launchctl disable gui/$UID/\(label)"
            }
        }
    }

    public struct Tweak: Identifiable, Sendable {
        public let id: String
        public let group: Group
        public let title: String
        public let detail: String
        public var caveat: String? = nil
        public let changes: [Change]
        /// Apple Intelligence model sets this feature needs; they go once every feature needing them is off.
        public var models: [String] = []
        /// Processes that read the setting only when they start.
        public var restart: [String] = []
        /// Part of the starting selection Spare suggests.
        public var suggested = false
        /// The first macOS major version that has the setting.
        public var since = 14

        public var inProfile: Bool { changes.contains(where: \.inProfile) || (changes.isEmpty && !models.isEmpty) }
        public var supported: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= since }
    }

    // MARK: - Models

    /// A downloadable model set in Apple's asset service.
    public struct ModelSet: Sendable {
        public let name: String
        public let assetType: String
        public let title: String
    }

    public static let foundationModels = "com.apple.modelcatalog"
    static let visualModels = "com.apple.MobileAsset.UAF.FM.Visual"
    static let codeModels = "com.apple.MobileAsset.UAF.FM.CodeLM"
    static let cleanUpModels = "com.apple.MobileAsset.UAF.Photos.MagicCleanup"
    static let spatialModels = "com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive"

    public static let modelSets: [ModelSet] = [
        ModelSet(name: foundationModels, assetType: "com.apple.MobileAsset.UAF.FM.GenerativeModels", title: "Apple Intelligence's language models"),
        ModelSet(name: visualModels, assetType: visualModels, title: "Image and Genmoji models"),
        ModelSet(name: spatialModels, assetType: spatialModels, title: "Spatial Photos models"),
        ModelSet(name: cleanUpModels, assetType: cleanUpModels, title: "Photos Clean Up models"),
        ModelSet(name: codeModels, assetType: codeModels, title: "Xcode code completion models")
    ]

    public static func modelSet(_ name: String) -> ModelSet? { modelSets.first { $0.name == name } }

    /// The sets that can go when these tweaks are on: every set whose features are all switched off.
    public static func setsToRemove(off: Set<String>) -> [String] {
        modelSets.map(\.name).filter { set in
            let users = all.filter { $0.models.contains(set) }
            return !users.isEmpty && users.allSatisfy { off.contains($0.id) }
        }
    }

    // MARK: - Catalog

    public static let all: [Tweak] = [
        // Apple Intelligence: each feature is "turned off", so the tweak's on state means the feature is off.
        Tweak(id: "siri", group: .intelligence, title: "Siri",
              detail: "Siri, its menu bar icon and “Hey Siri”. Dictation keeps working.",
              changes: [.restriction("allowAssistant"),
                        .forced(domain: "com.apple.assistant.support", key: "Assistant Enabled", .bool(false)),
                        .forced(domain: "com.apple.Siri", key: "StatusMenuVisible", .bool(false)),
                        .forced(domain: "com.apple.Siri", key: "VoiceTriggerUserEnabled", .bool(false))],
              models: [foundationModels]),
        Tweak(id: "chatgpt", group: .intelligence, title: "ChatGPT and other AI extensions",
              detail: "Siri and Writing Tools handing requests to ChatGPT or another outside service, and signing in to one.",
              changes: [.restriction("allowExternalIntelligenceIntegrations"), .restriction("allowExternalIntelligenceIntegrationsSignIn")],
              suggested: true),
        Tweak(id: "writing-tools", group: .intelligence, title: "Writing Tools",
              detail: "Rewrite, proofread and summarise in every app.",
              changes: [.restriction("allowWritingTools")], models: [foundationModels], suggested: true),
        Tweak(id: "genmoji", group: .intelligence, title: "Genmoji",
              detail: "Making new emoji from a description.",
              changes: [.restriction("allowGenmoji")], models: [foundationModels, visualModels], suggested: true),
        Tweak(id: "image-playground", group: .intelligence, title: "Image Playground",
              detail: "Making images from a description, in its app and in others.",
              changes: [.restriction("allowImagePlayground")], models: [foundationModels, visualModels], suggested: true),
        Tweak(id: "mail", group: .intelligence, title: "Mail summaries and smart replies",
              detail: "Summaries at the top of messages and suggested replies.",
              changes: [.restriction("allowMailSummary"), .restriction("allowMailSmartReplies"),
                        .forced(domain: "group.com.apple.mail", key: "DisableAutomaticMessageSummarization", .bool(true)),
                        .forced(domain: "group.com.apple.mail", key: "PersonalizedSmartReplies", .bool(false))],
              models: [foundationModels], suggested: true),
        Tweak(id: "notification-summaries", group: .intelligence, title: "Notification summaries",
              detail: "Stacks of notifications rewritten as one summary.",
              changes: [.forced(domain: "group.com.apple.usernoted", key: "summarize_previews", .bool(false))],
              models: [foundationModels], suggested: true),
        Tweak(id: "messages-summaries", group: .intelligence, title: "Messages summaries",
              detail: "Summaries of unread conversations.",
              changes: [.forced(domain: "com.apple.MobileSMS", key: "messageSummarizationEnabled", .bool(false))],
              models: [foundationModels], suggested: true),
        Tweak(id: "safari-summaries", group: .intelligence, title: "Safari summaries",
              detail: "Summaries of web pages in Safari's reader.",
              changes: [.restriction("allowSafariSummary")], models: [foundationModels], suggested: true),
        Tweak(id: "notes-summaries", group: .intelligence, title: "Notes transcription summaries",
              detail: "Summaries of recordings in Notes.",
              changes: [.restriction("allowNotesTranscriptionSummary")], models: [foundationModels], suggested: true),
        Tweak(id: "inline-predictions", group: .intelligence, title: "Inline text predictions",
              detail: "Grey words suggested ahead of the cursor as you type.",
              changes: [.forced(domain: "NSGlobalDomain", key: "NSAutomaticInlinePredictionEnabled", .bool(false))], suggested: true),
        Tweak(id: "spatial-photos", group: .intelligence, title: "Spatial Photos",
              detail: "Turning ordinary photos into 3D scenes.",
              changes: [.forced(domain: "com.apple.spatialphotosrelive", key: "LocallyDisabled", .bool(true))],
              models: [spatialModels], suggested: true),
        Tweak(id: "photos-clean-up", group: .intelligence, title: "Photos Clean Up",
              detail: "Removing distractions from photos. Its models are removed and kept from downloading again.",
              changes: [], models: [cleanUpModels]),
        Tweak(id: "xcode-completion", group: .intelligence, title: "Xcode predictive code completion",
              detail: "Whole lines suggested in Xcode. Its models are removed and kept from downloading again.",
              changes: [], models: [codeModels]),

        // What macOS shares
        Tweak(id: "analytics", group: .sharing, title: "Mac Analytics",
              detail: "Diagnostic and usage data sent to Apple, and crash reports shared with app developers.",
              changes: [.restriction("allowDiagnosticSubmission")], suggested: true),
        Tweak(id: "personalized-ads", group: .sharing, title: "Personalised ads",
              detail: "Apple using what you do in its apps to choose ads in the App Store, News and Stocks.",
              changes: [.restriction("allowApplePersonalizedAdvertising")], suggested: true),
        Tweak(id: "improve-siri", group: .sharing, title: "Improve Siri and Dictation",
              detail: "Apple storing and reviewing recordings of what you say to Siri and dictate.",
              changes: [.forced(domain: "com.apple.assistant.support", key: "Siri Data Sharing Opt-In Status", .int(2))], suggested: true),
        Tweak(id: "improve-search", group: .sharing, title: "Improve Search",
              detail: "Apple keeping what you search for in Spotlight, Safari and Look Up.",
              changes: [.forced(domain: "com.apple.assistant.support", key: "Search Queries Data Sharing Status", .int(2))], suggested: true),
        Tweak(id: "spotlight-web", group: .sharing, title: "Spotlight internet results",
              detail: "What you type in Spotlight sent to Apple for web suggestions.",
              changes: [.restriction("allowSpotlightInternetResults")], suggested: true),
        Tweak(id: "lookup-suggestions", group: .sharing, title: "Look Up suggestions",
              detail: "The words you look up sent to Apple for web results.",
              changes: [.forced(domain: "com.apple.lookup.shared", key: "LookupSuggestionsDisabled", .bool(true))], suggested: true),
        Tweak(id: "safari-suggestions", group: .sharing, title: "Safari search suggestions",
              detail: "What you type in Safari's address bar sent to your search engine and to Apple as you type.",
              caveat: "The address bar no longer suggests searches.",
              changes: [.forced(domain: "com.apple.Safari", key: "UniversalSearchEnabled", .bool(false)),
                        .forced(domain: "com.apple.Safari", key: "SuppressSearchSuggestions", .bool(true))]),
        Tweak(id: "game-center", group: .sharing, title: "Game Center",
              detail: "Game Center, with its sign-in prompts, friend requests and notifications.",
              caveat: "Games that keep progress or play online through Game Center lose that.",
              changes: [.restriction("allowGameCenter")]),

        // Apple's apps
        Tweak(id: "music-service", group: .apps, title: "Apple Music in the Music app",
              detail: "The store, the subscription and its prompts. Music becomes a player for your own library.",
              caveat: "Apple Music subscribers lose streaming on this Mac.",
              changes: [.restriction("allowMusicService")]),
        Tweak(id: "book-store", group: .apps, title: "The Book Store",
              detail: "The store inside Books. Your own books stay.",
              changes: [.restriction("allowBookstore")], since: 15),
        Tweak(id: "media-keys", group: .apps, title: "Play keys opening Music",
              detail: "The service behind the play, pause and skip keys, which opens Music when nothing else plays.",
              caveat: "The keys stop working in every app, Spotify included. Block Music below instead to keep them.",
              changes: [.service("com.apple.rcd")]),

        // Annoyances
        Tweak(id: "click-to-desktop", group: .annoyances, title: "Clicking the wallpaper hides every window",
              detail: "A click on the desktop by mistake slides all windows away.",
              changes: [.pref(domain: "com.apple.WindowManager", key: "EnableStandardClickToShowDesktop", .bool(false))], suggested: true),
        Tweak(id: "desktop-widgets", group: .annoyances, title: "Widgets on the desktop",
              detail: "Widgets on the desktop and in Stage Manager.",
              changes: [.pref(domain: "com.apple.WindowManager", key: "StandardHideWidgets", .bool(true)),
                        .pref(domain: "com.apple.WindowManager", key: "StageManagerHideWidgets", .bool(true))]),
        Tweak(id: "iphone-mirroring", group: .annoyances, title: "iPhone Mirroring",
              detail: "The iPhone Mirroring app and its prompts.",
              changes: [.restriction("allowiPhoneMirroring")], since: 15),
        Tweak(id: "dock-recents", group: .annoyances, title: "Recent apps in the Dock",
              detail: "Apps you opened lately, added to the Dock by themselves.",
              changes: [.pref(domain: "com.apple.dock", key: "show-recents", .bool(false))], restart: ["Dock"], suggested: true),
        Tweak(id: "network-ds-store", group: .annoyances, title: ".DS_Store files on network drives",
              detail: "Finder leaving hidden .DS_Store files in folders shared by other computers.",
              changes: [.pref(domain: "com.apple.desktopservices", key: "DSDontWriteNetworkStores", .bool(true))], suggested: true),
        Tweak(id: "save-to-icloud", group: .annoyances, title: "Saving new documents to iCloud",
              detail: "Save dialogs starting in iCloud Drive instead of on this Mac.",
              changes: [.pref(domain: "NSGlobalDomain", key: "NSDocumentSaveNewDocumentsToCloud", .bool(false))])
    ]

    public static func tweak(_ id: String) -> Tweak? { all.first { $0.id == id } }

    // MARK: - Profile

    /// The profile's identifier, and the preference domain whose forced values say it's installed.
    public static let profileIdentifier = "com.opyuii.spare.debloat"

    /// Asset downloads for a removed set go to a closed local port, so they fail instead of filling the disk again
    /// (a technique from pared).
    static let downloadDomain = "com.apple.MobileAsset"
    static let blockedURL = "https://127.0.0.1:9/spare-blocked/"

    public static func downloadKey(_ set: ModelSet) -> String { "DownloadServerBaseURLOverride-" + set.assetType }

    /// The profile locking these tweaks, as a property list.
    public static func profile(_ tweaks: Set<String>) throws -> Data {
        var restrictions: [String: Any] = payload(type: "com.apple.applicationaccess", suffix: "restrictions", name: "Restrictions")
        var hasRestrictions = false
        var forced: [String: [String: Any]] = [:]
        for tweak in all where tweaks.contains(tweak.id) {
            for change in tweak.changes {
                switch change {
                case .restriction(let key):
                    restrictions[key] = false
                    hasRestrictions = true
                case .forced(let domain, let key, let value):
                    // Managed preferences call the global domain by its file's name.
                    forced[domain == "NSGlobalDomain" ? ".GlobalPreferences" : domain, default: [:]][key] = value.object
                case .pref, .service:
                    break
                }
            }
        }
        for name in setsToRemove(off: tweaks) {
            guard let set = modelSet(name) else { continue }
            forced[downloadDomain, default: [:]][downloadKey(set)] = blockedURL
        }
        // A marker, so Spare can tell the profile is in force and what it holds.
        forced[profileIdentifier] = ["installed": true, "tweaks": tweaks.sorted().joined(separator: ",")]

        let preferences = forced.keys.sorted().map { domain -> [String: Any] in
            var part = payload(type: "com.apple.ManagedClient.preferences", suffix: "preferences." + domain, name: "Locked settings: \(domain)")
            part["PayloadContent"] = [domain: ["Forced": [["mcx_preference_settings": forced[domain]!]]]]
            return part
        }
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": profileIdentifier,
            "PayloadUUID": uuid(profileIdentifier),
            "PayloadDisplayName": "Spare Privacy",
            "PayloadDescription": "Keeps the Apple Intelligence features and the sharing you switched off in Spare switched off, and stops removed models downloading again. Remove this profile to undo all of it.",
            "PayloadOrganization": "Spare",
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": (hasRestrictions ? [restrictions] : []) + preferences
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    private static func payload(type: String, suffix: String, name: String) -> [String: Any] {
        let id = profileIdentifier + "." + suffix
        return ["PayloadType": type, "PayloadVersion": 1, "PayloadIdentifier": id, "PayloadUUID": uuid(id), "PayloadDisplayName": name]
    }

    /// A UUID that stays the same for an identifier, so a new version of the profile replaces the old one.
    static func uuid(_ name: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325, second: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in name.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            second = (second ^ UInt64(byte)) &* 0x100_0000_01b3 &+ 7
        }
        var bytes = withUnsafeBytes(of: hash.bigEndian, Array.init) + withUnsafeBytes(of: second.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }

    /// Removes a profile as root: the current verb, then the older flag some versions of macOS still want.
    public static func removeProfileCommand(_ identifier: String = profileIdentifier) -> String {
        "/usr/bin/profiles remove -identifier '\(identifier)' || /usr/bin/profiles -R -p '\(identifier)'"
    }

    /// The tweaks Spare's profile locks, or nil when it isn't installed.
    public static func installedProfile() -> Set<String>? {
        let domain = profileIdentifier as CFString
        CFPreferencesAppSynchronize(domain)
        guard CFPreferencesAppValueIsForced("installed" as CFString, domain) else { return nil }
        let list = CFPreferencesCopyAppValue("tweaks" as CFString, domain) as? String ?? ""
        return Set(list.split(separator: ",").map(String.init))
    }
}

// MARK: - Reading and writing preferences

/// The person's preferences, read and written through cfprefsd as `defaults` does.
public enum Prefs {
    static func app(_ domain: String) -> CFString {
        domain == "NSGlobalDomain" || domain == ".GlobalPreferences" ? kCFPreferencesAnyApplication : domain as CFString
    }

    /// The value apps see: a locked one wins over the person's own.
    public static func read(_ domain: String, _ key: String) -> Any? {
        CFPreferencesAppSynchronize(app(domain))
        return CFPreferencesCopyAppValue(key as CFString, app(domain))
    }

    /// The person's own value, ignoring locked ones.
    public static func own(_ domain: String, _ key: String) -> Any? {
        CFPreferencesSynchronize(app(domain), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key as CFString, app(domain), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Writes the person's value; nil removes it, so macOS's default applies again.
    @discardableResult
    public static func write(_ domain: String, _ key: String, _ value: Debloat.Value?) -> Bool {
        CFPreferencesSetValue(key as CFString, value?.object, app(domain), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(app(domain), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    public static func isLocked(_ domain: String, _ key: String) -> Bool {
        CFPreferencesAppSynchronize(app(domain))
        return CFPreferencesAppValueIsForced(key as CFString, app(domain))
    }
}
