import Foundation

/// Finder's small settings that its own Settings window doesn't offer: the path bar, the status bar with the space
/// left, full paths, hidden files and the like. Each is one of Finder's preferences; switching one back to how macOS
/// has it removes the value again rather than writing macOS's default, so nothing of Spare's stays behind.
public enum FinderOptions {
    public struct Option: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let detail: String
        public let domain: String
        public let key: String
        public let on: Debloat.Value
        public let off: Debloat.Value
        /// How macOS has it when nothing is set.
        public let standard: Bool

        /// On or off, from what Finder reads now (nil when nothing is set).
        public func isOn(_ value: Any?) -> Bool {
            guard let value else { return standard }
            return on.matches(value)
        }

        /// What to write for on or off: nil, so macOS's default applies, when that's what macOS does anyway.
        public func value(on wanted: Bool) -> Debloat.Value? {
            wanted == standard ? nil : wanted ? on : off
        }
    }

    static let finder = "com.apple.finder"

    private static func toggle(_ id: String, _ title: String, _ detail: String, domain: String = finder, _ key: String,
                               on: Debloat.Value = .bool(true), off: Debloat.Value = .bool(false), standard: Bool = false) -> Option {
        Option(id: id, title: title, detail: detail, domain: domain, key: key, on: on, off: off, standard: standard)
    }

    public static let all: [Option] = [
        toggle("pathbar", "Path bar", "The folders above the one you're in, at the bottom of every window.", "ShowPathbar"),
        toggle("statusbar", "Status bar", "How many items are in a folder and how much space is left on the disk.", "ShowStatusBar"),
        toggle("full-path", "Full path in the title", "“/Users/you/Documents” instead of just “Documents”.", "_FXShowPosixPathInTitle"),
        toggle("extensions", "All filename extensions", ".pdf, .zip and the rest, on every file.", domain: "NSGlobalDomain", "AppleShowAllExtensions"),
        toggle("hidden", "Hidden files", "Shown dimmed, like .zshrc. Command-Shift-. switches them too.", "AppleShowAllFiles"),
        toggle("folders-first", "Folders on top", "Folders before files when windows sort by name.", "_FXSortFoldersFirst"),
        toggle("folders-first-desktop", "Folders on top on the Desktop", "The same for the Desktop.", "_FXSortFoldersFirstOnDesktop"),
        toggle("search-here", "Search the folder you're in", "Searching from a window looks there first, not on the whole Mac.", "FXDefaultSearchScope",
               on: .string("SCcf"), off: .string("SCev")),
        toggle("extension-warning", "Ask before changing an extension", "Finder checks before a file's type changes with its name.", "FXEnableExtensionChangeWarning",
               standard: true),
        toggle("old-trash", "Empty old Trash items", "Items are deleted after 30 days in the Trash.", "FXRemoveOldTrashItems"),
        toggle("empty-warning", "Ask before emptying the Trash", "Finder checks before deleting what's in the Trash for good.", "WarnOnEmptyTrash", standard: true),
        // Network drives are under Annoyances, which keeps the value from before.
        toggle("ds-usb", "No .DS_Store files on USB drives", "Finder stops leaving its hidden view files on USB sticks and external disks.",
               domain: "com.apple.desktopservices", "DSDontWriteUSBStores"),
        toggle("desktop-disks", "External disks on the Desktop", "Plugged-in disks appear on the Desktop.", "ShowExternalHardDrivesOnDesktop", standard: true),
    ]

    /// How folders open that haven't been given their own view.
    public enum View: String, CaseIterable, Sendable {
        case icons = "icnv", list = "Nlsv", columns = "clmv", gallery = "glyv"
        public var title: String {
            switch self {
            case .icons: "Icons"
            case .list: "List"
            case .columns: "Columns"
            case .gallery: "Gallery"
            }
        }
    }

    public static let viewKey = "FXPreferredViewStyle"

    public static func view() -> View { (Prefs.read(finder, viewKey) as? String).flatMap(View.init) ?? .icons }

    public static func setView(_ view: View) {
        Prefs.write(finder, viewKey, view == .icons ? nil : .string(view.rawValue))
    }

    public static func states() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.isOn(Prefs.read($0.domain, $0.key))) })
    }

    public static func set(_ option: Option, on: Bool) {
        Prefs.write(option.domain, option.key, option.value(on: on))
    }

    // MARK: Library

    static var library: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library") }

    /// Whether your Library folder shows in your home folder; macOS hides it.
    public static func libraryShown() -> Bool {
        (try? library.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == false
    }

    /// Shows or hides your Library folder. nil when that worked.
    public static func showLibrary(_ shown: Bool) -> String? {
        var url = library
        var values = URLResourceValues()
        values.isHidden = !shown
        do { try url.setResourceValues(values) } catch { return error.localizedDescription }
        return nil
    }
}
