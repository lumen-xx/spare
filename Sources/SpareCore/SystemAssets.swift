import Foundation

/// What macOS downloads for its own features into /System/Library/AssetsV2: Apple Intelligence models, Siri's speech
/// models, voices, waiting updates. System Integrity Protection guards that folder, so not even an administrator can
/// delete from it; macOS removes a download itself once nothing holds on to it any more.
public struct SystemAsset: Identifiable, Sendable {
    public enum Feature: String, CaseIterable, Sendable {
        case appleIntelligence = "Apple Intelligence"
        case siriSpeech = "Siri and Dictation"
        case voices = "Voices"
        case photos = "Photos Models"
        case languageData = "Language Data"
        case updates = "Downloaded macOS Updates"
        case metal = "Metal Toolchain"
        case dictionaries = "Dictionaries"
        case fonts = "Downloadable Fonts"
        case other = "Other macOS Data"

        public var symbol: String {
            switch self {
            case .appleIntelligence: "brain.head.profile"
            case .siriSpeech: "waveform"
            case .voices: "speaker.wave.2"
            case .photos: "photo"
            case .languageData: "character.bubble"
            case .updates: "arrow.down.circle"
            case .metal: "hammer"
            case .dictionaries: "character.book.closed"
            case .fonts: "textformat"
            case .other: "gearshape"
            }
        }

        /// What it is, for when nothing says who keeps it.
        public var about: String {
            switch self {
            case .appleIntelligence: "Models for Writing Tools, summaries and Apple Intelligence's other features."
            case .siriSpeech: "Speech models for Siri and Dictation, which macOS keeps even with Siri off."
            case .voices: "Siri's voice, which stays while Siri uses it, and system voices you added."
            case .photos: "Models Photos uses to recognise what's in your pictures."
            case .languageData: "Spelling, typing and translation data for the languages you use."
            case .updates: "A macOS update that's downloaded and waiting to be installed."
            case .metal: "Tools for compiling Metal shaders."
            case .dictionaries: "Dictionaries for the Dictionary app and Look Up."
            case .fonts: "Fonts apps asked macOS to download."
            case .other: "Smaller data macOS keeps for its features."
            }
        }

        /// What lets macOS remove it.
        public var remedy: String {
            switch self {
            case .appleIntelligence: "Switching Apple Intelligence off lets macOS remove them."
            case .siriSpeech: "No setting removes them."
            case .voices: "Remove voices you added in Accessibility › Spoken Content › System Voice › Manage Voices."
            case .photos: "macOS manages them; no setting removes them."
            case .languageData: "Remove translation languages you don't need in Language & Region › Translation Languages; macOS manages the rest."
            case .updates: "Installing it frees this space."
            case .metal: SystemAssets.xcodeInstalled
                ? "Xcode downloaded it; remove it in Xcode › Settings › Components."
                : "Without Xcode installed, only macOS removes it, on its own."
            case .dictionaries, .fonts: "macOS downloads and removes them on its own."
            case .other: "macOS downloads and removes it on its own."
            }
        }

        public var settings: URL? {
            switch self {
            case .appleIntelligence: URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
            case .voices: URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension")
            case .languageData: URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")
            case .updates: URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
            default: nil
            }
        }

        /// Which feature a folder such as "com_apple_MobileAsset_UAF_Siri_Understanding" belongs to.
        public static func of(_ folder: String) -> Feature {
            let name = folder.lowercased()
            func has(_ parts: String...) -> Bool { parts.contains { name.contains($0) } }
            if has("texttospeech", "macintalk", "ttsax", "voiceservices") { return .voices }
            // Before Siri: Siri's answer synthesis is part of Apple Intelligence.
            if has("_uaf_fm_", "uaf_if_planner", "generativemodel", "imagecaption", "summarizationkit", "handwriting",
                   "shortcuts_generator", "answersynthesis") { return .appleIntelligence }
            if has("siri", "speech", "dictation", "voicetrigger") { return .siriSpeech }
            if has("photos") { return .photos }
            if has("linguisticdata", "translation") { return .languageData }
            if has("softwareupdate", "osupdate", "updatebrain") { return .updates }
            if has("metaltoolchain") { return .metal }
            if has("dictionary") { return .dictionaries }
            if has("font") { return .fonts }
            return .other
        }
    }

    public let feature: Feature
    public var folders: [URL]
    /// What could be measured. When `hidden`, the real size is larger by an unknown amount.
    public var bytes: Int64
    /// macOS doesn't let apps measure (some of) these folders, Full Disk Access or not.
    public var hidden = false
    public var measurable: Bool { !hidden }
    public var id: String { feature.rawValue }

    public init(feature: Feature, folders: [URL], bytes: Int64, hidden: Bool = false) {
        self.feature = feature; self.folders = folders; self.bytes = bytes; self.hidden = hidden
    }
}

public enum SystemAssets {
    public static let root = URL(fileURLWithPath: "/System/Library/AssetsV2")

    public static func measure(root: URL = root) -> [SystemAsset] {
        let folders = Catalog.list(root).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let sizes = Catalog.measure(folders, cancel: Cancellation())
        var groups: [SystemAsset.Feature: SystemAsset] = [:]
        for (index, folder) in folders.enumerated() {
            let feature = SystemAsset.Feature.of(folder.lastPathComponent)
            groups[feature, default: SystemAsset(feature: feature, folders: [], bytes: 0)].folders.append(folder)
            groups[feature]?.bytes += sizes[index].bytes
            if sizes[index].unreadable > 0 { groups[feature]?.hidden = true }
        }
        // Below a megabyte a group is only bookkeeping, such as the catalogue of available updates. One that can't be
        // measured stays: its size is unknown, not small.
        return SystemAsset.Feature.allCases.compactMap { groups[$0] }.filter { $0.bytes >= 1_000_000 || $0.hidden }
    }

    static var xcodeInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/Xcode.app", "/Applications/Xcode-beta.app", home + "/Applications/Xcode.app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }
}
