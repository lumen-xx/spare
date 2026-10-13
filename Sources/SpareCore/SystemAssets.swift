import Foundation

/// What macOS downloads for its own features into /System/Library/AssetsV2: Apple Intelligence models, voices,
/// dictation, waiting updates. System Integrity Protection guards that folder, so not even an administrator can
/// delete from it; macOS removes these itself once the feature that needs them is switched off.
public struct SystemAsset: Identifiable, Sendable {
    public enum Feature: String, CaseIterable, Sendable {
        case appleIntelligence = "Apple Intelligence and Siri"
        case dictation = "Dictation and Speech Recognition"
        case voices = "Voices"
        case updates = "Downloaded macOS Updates"
        case metal = "Metal Toolchain"
        case dictionaries = "Dictionaries"
        case fonts = "Downloadable Fonts"
        case other = "Other macOS Data"

        public var symbol: String {
            switch self {
            case .appleIntelligence: "brain.head.profile"
            case .dictation: "mic"
            case .voices: "speaker.wave.2"
            case .updates: "arrow.down.circle"
            case .metal: "hammer"
            case .dictionaries: "character.book.closed"
            case .fonts: "textformat"
            case .other: "gearshape"
            }
        }

        /// How to get the space back.
        public var remedy: String {
            switch self {
            case .appleIntelligence: "Turn off Apple Intelligence in Apple Intelligence & Siri. macOS then deletes these models, which can take a while."
            case .dictation: "Turn off Dictation in Keyboard settings, and macOS deletes its speech models."
            case .voices: "Remove voices you added in Accessibility › Spoken Content › System Voice › Manage Voices."
            case .updates: "A macOS update is downloaded and waiting. Installing it frees this space."
            case .metal: "Downloaded by Xcode for compiling shaders. Remove it in Xcode › Settings › Components."
            case .dictionaries, .fonts, .other: "macOS downloads and removes these on its own."
            }
        }

        public var settings: URL? {
            switch self {
            case .appleIntelligence: URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
            case .dictation: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
            case .voices: URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension")
            case .updates: URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
            default: nil
            }
        }

        /// Which feature a folder such as "com_apple_MobileAsset_UAF_Siri_Understanding" belongs to.
        public static func of(_ folder: String) -> Feature {
            let name = folder.lowercased()
            if name.contains("speech_automaticspeech") || name.contains("dictation") || name.contains("speechrecognition") { return .dictation }
            if name.contains("texttospeech") || name.contains("macintalk") || name.contains("ttsax") || name.contains("voiceservices") { return .voices }
            if name.contains("softwareupdate") || name.contains("osupdate") || name.contains("updatebrain") { return .updates }
            if name.contains("metaltoolchain") { return .metal }
            if name.contains("dictionary") { return .dictionaries }
            if name.contains("font") { return .fonts }
            if name.contains("_uaf_") || name.contains("generativemodel") || name.contains("imagecaption") || name.contains("siri") { return .appleIntelligence }
            return .other
        }
    }

    public let feature: Feature
    public var folders: [URL]
    public var bytes: Int64
    public var id: String { feature.rawValue }
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
        }
        // Below a megabyte a group is only bookkeeping, such as the catalogue of available updates.
        return SystemAsset.Feature.allCases.compactMap { groups[$0] }.filter { $0.bytes >= 1_000_000 }
    }
}
