import Foundation

/// Something Spare moved to the Trash, and where it went, so it can be put back.
public struct TrashRecord: Codable, Sendable, Hashable, Identifiable {
    public let original: String
    public let trashed: String
    /// Its size when moved; nil when it was part of a group measured together.
    public let bytes: Int64?
    public var id: String { trashed }
    public init(original: String, trashed: String, bytes: Int64?) { self.original = original; self.trashed = trashed; self.bytes = bytes }

    public enum State: Sendable { case inTrash, putBack, gone }

    public var state: State {
        if FileManager.default.fileExists(atPath: trashed) { return .inTrash }
        return FileManager.default.fileExists(atPath: original) ? .putBack : .gone
    }
}

/// One clean-up, uninstall or removal.
public struct TrashSession: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let title: String
    public var records: [TrashRecord]
    public var bytes: Int64
    public init(id: UUID = UUID(), date: Date = Date(), title: String, records: [TrashRecord], bytes: Int64) {
        self.id = id; self.date = date; self.title = title; self.records = records; self.bytes = bytes
    }
}

public enum Trash {
    public struct Failure: Sendable {
        public let url: URL
        public let reason: String
        public let needsPermission: Bool
        public init(url: URL, reason: String, needsPermission: Bool) { self.url = url; self.reason = reason; self.needsPermission = needsPermission }
    }

    /// Moves items to the Trash, one by one, so one failure doesn't stop the rest. Nothing is ever deleted.
    public static func move(_ urls: [(url: URL, bytes: Int64?)]) -> (records: [TrashRecord], failures: [Failure]) {
        var records: [TrashRecord] = []
        var failures: [Failure] = []
        for (url, bytes) in urls {
            guard FileManager.default.fileExists(atPath: url.path) || isSymbolicLink(url) else { continue }
            do {
                var result: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                records.append(TrashRecord(original: url.path, trashed: (result as URL?)?.path ?? url.path, bytes: bytes))
            } catch {
                failures.append(Failure(url: url, reason: error.localizedDescription, needsPermission: isPermission(error)))
            }
        }
        return (records, failures)
    }

    /// Moves an item back to where it was. Fails rather than replace something that is there now.
    public static func putBack(_ record: TrashRecord) throws {
        let original = URL(fileURLWithPath: record.original)
        if FileManager.default.fileExists(atPath: original.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: original.path,
                NSLocalizedDescriptionKey: "Something new is already at \(original.path)."])
        }
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: record.trashed), to: original)
    }

    public static func isPermission(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain,
           [Int(EPERM), Int(EACCES)].contains(underlying.code) { return true }
        return error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code)
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}

/// Spare's record of everything it moved, kept in ~/Library/Application Support/Spare.
public final class TrashHistory {
    public let file: URL
    public init(file: URL) { self.file = file }

    public func load() -> [TrashSession] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TrashSession].self, from: data)) ?? []
    }

    public func save(_ sessions: [TrashSession]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(sessions.prefix(200))) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// Empties a Trash folder for good, item by item, so one stubborn item doesn't stop the rest the way it stops
/// Finder. Locked files and read-only folders of the person's own are unlocked first; what still can't be deleted
/// (usually items owned by the system) is handed back for an administrator to remove.
public enum TrashEmptier {
    public struct Result: Sendable {
        public var removed = 0
        /// Items only an administrator can delete.
        public var needsAdministrator: [URL] = []
        /// Items that couldn't be deleted at all, with why.
        public var failed: [(URL, String)] = []
    }

    public static func empty(_ trash: URL) -> Result {
        var result = Result()
        let items = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: [])) ?? []
        for item in items {
            if delete(item) { result.removed += 1; continue }
            unlock(item)
            do {
                try FileManager.default.removeItem(at: item)
                result.removed += 1
            } catch where Trash.isPermission(error) {
                result.needsAdministrator.append(item)
            } catch {
                result.failed.append((item, error.localizedDescription))
            }
        }
        return result
    }

    static func delete(_ url: URL) -> Bool { (try? FileManager.default.removeItem(at: url)) != nil }

    /// Clears the "locked" flag and gives the owner write access throughout, which deleting needs.
    static func unlock(_ url: URL) {
        for (tool, arguments) in [("/usr/bin/chflags", ["-R", "nouchg", url.path]), ("/bin/chmod", ["-R", "u+rwX", url.path])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}
