import Foundation

/// What a macOS update or upgrade left behind. The installer stages its download in "macOS Install Data" and
/// normally removes it when it's done; after an install that failed or was put off it stays, often several gigabytes.
/// The folder belongs to the system, so the app moves it to the Trash with an administrator's permission.
public enum UpdateLeftovers {
    public static let folder = URL(fileURLWithPath: "/System/Volumes/Data/macOS Install Data")

    public struct Found: Sendable, Equatable {
        /// Everything inside except "Locked Files", which System Integrity Protection guards.
        public var items: [URL]
        public var bytes: Int64
        public var downloaded: Date?
        /// "macOS Sequoia installer (24.6.231)".
        public var product: String?
        /// Older than the installed system, so nothing is waiting to be installed from it.
        public var isLeftover: Bool

        public init(items: [URL], bytes: Int64, downloaded: Date?, product: String?, isLeftover: Bool) {
            self.items = items; self.bytes = bytes; self.downloaded = downloaded; self.product = product; self.isLeftover = isLeftover
        }
    }

    /// nil when there's no such folder or nothing in it besides the locked files.
    public static func find(folder: URL = folder,
                            systemVersion: URL = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")) -> Found? {
        let items = Catalog.listIncludingLinks(folder).filter { $0.lastPathComponent != "Locked Files" }
        guard !items.isEmpty else { return nil }
        let bytes = Catalog.measure(items, cancel: Cancellation()).reduce(Int64(0)) { $0 + $1.bytes }
        let values = try? folder.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let product = (NSDictionary(contentsOf: folder.appendingPathComponent("index.sproduct")) as? [String: Any]).flatMap(productName)
        // An update still waiting to be installed is newer than the running system; one that was installed, or given
        // up on, is older. Without both dates it's treated as waiting.
        var isLeftover = false
        if let installed = modified(systemVersion) {
            let newest = ([folder] + items).compactMap(modified).max()
            isLeftover = newest.map { $0 < installed } ?? false
        }
        return Found(items: items, bytes: bytes, downloaded: values?.creationDate ?? values?.contentModificationDate,
                     product: product, isLeftover: isLeftover)
    }

    /// "macOS Sequoia installer (24.6.231)" for an index.sproduct whose package is com.apple.pkg.InstallAssistant.macOSSequoia,
    /// "macOS update (25.1)" for other packages. nil when it names none.
    public static func productName(_ sproduct: [String: Any]) -> String? {
        guard let package = (sproduct["Packages"] as? [[String: Any]])?.first,
              let identifier = package["Identifier"] as? String, !identifier.isEmpty else { return nil }
        let version = (package["Version"] as? String).flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        let marker = "InstallAssistant."
        guard let range = identifier.range(of: marker) else { return "macOS update" + version }
        var release = String(identifier[range.upperBound...])
        if release.lowercased().hasPrefix("macos") { release.removeFirst(5) }
        // "BigSur" is Big Sur.
        var words = ""
        for character in release {
            if character.isUppercase, let last = words.last, last.isLowercase { words.append(" ") }
            words.append(character)
        }
        return (words.isEmpty ? "macOS installer" : "macOS \(words) installer") + version
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
