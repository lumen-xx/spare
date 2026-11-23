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
        /// Stopped before the end, as asked. Whatever wasn't deleted yet is still in the Trash.
        public var stopped = false
        public init() {}
    }

    /// How far emptying has got, reported as it goes.
    public struct Progress: Sendable, Equatable {
        public enum Step: Sendable, Equatable { case counting, deleting, unlocking }
        public var step = Step.counting
        /// Items directly in the Trash, and how many have been counted, or deleted (or given up on).
        public var items = 0
        public var itemsDone = 0
        /// Files and folders inside them all. Deleting goes through them one at a time, so the bar moves by these
        /// rather than by items: one folder can hold most of the Trash.
        public var entries = 0
        public var entriesDone = 0
        /// The size of it all, and roughly how much of that is deleted so far.
        public var bytes: Int64 = 0
        public var bytesDone: Int64 = 0
        /// The item being counted or deleted now.
        public var current: String?
        public init() {}

        public var fraction: Double { entries > 0 ? min(1, Double(entriesDone) / Double(entries)) : 0 }
    }

    /// Empties `trash`. It counts what's inside first, then deletes, calling `report` (on this thread, at most about
    /// 15 times a second) as it goes. When `cancel` is set it stops soon, even inside a large folder.
    public static func empty(_ trash: URL, cancel: Cancellation? = nil, report: ((Progress) -> Void)? = nil) -> Result {
        var result = Result()
        let items = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: [])) ?? []
        let deletion = Deletion(cancel: cancel, report: report)
        deletion.progress.items = items.count
        deletion.send(force: true)

        var sizes: [Usage] = []
        for item in items {
            if cancel?.isCancelled == true { result.stopped = true; return result }
            deletion.progress.current = item.lastPathComponent
            deletion.send()
            let usage = DiskUsage.measure(item, cancel: cancel)
            sizes.append(usage)
            deletion.progress.itemsDone += 1
            deletion.progress.entries += max(1, usage.files + usage.folders)
            deletion.progress.bytes += usage.bytes + usage.shared
        }

        deletion.progress.step = .deleting
        deletion.progress.itemsDone = 0
        deletion.send(force: true)
        let manager = FileManager()
        manager.delegate = deletion
        for (item, usage) in zip(items, sizes) {
            if cancel?.isCancelled == true { result.stopped = true; break }
            deletion.begin(item, usage)
            let removedBefore = result.removed
            if (try? manager.removeItem(at: item)) != nil {
                result.removed += 1
            } else if cancel?.isCancelled == true {
                // Stopping makes the rest of the folder fail as if it were protected; that's not a problem to report.
                result.stopped = true
                break
            } else {
                deletion.progress.step = .unlocking
                deletion.send(force: true)
                unlock(item)
                deletion.progress.step = .deleting
                do {
                    try manager.removeItem(at: item)
                    result.removed += 1
                } catch where cancel?.isCancelled == true {
                    result.stopped = true
                    break
                } catch where Trash.isPermission(error) {
                    result.needsAdministrator.append(item)
                } catch {
                    result.failed.append((item, error.localizedDescription))
                }
            }
            deletion.finish(deleted: result.removed > removedBefore)
        }
        deletion.progress.current = nil
        deletion.send(force: true)
        return result
    }

    /// Counts entries as FileManager deletes them, which it asks about one by one, even deep inside a folder.
    private final class Deletion: NSObject, FileManagerDelegate {
        var progress = Progress()
        private let cancel: Cancellation?
        private let report: ((Progress) -> Void)?
        private var lastSent = 0.0
        /// The item being deleted: where the totals stood before it, its own size, and how many entries are gone.
        private var before = (entries: 0, bytes: Int64(0))
        private var size = (entries: 1, bytes: Int64(0))
        private var seen = 0

        init(cancel: Cancellation?, report: ((Progress) -> Void)?) { self.cancel = cancel; self.report = report }

        func begin(_ item: URL, _ usage: Usage) {
            before = (progress.entriesDone, progress.bytesDone)
            size = (max(1, usage.files + usage.folders), usage.bytes + usage.shared)
            seen = 0
            progress.current = item.lastPathComponent
            send(force: true)
        }

        /// The item is dealt with. Its entries count as gone through either way; its size only when it was deleted.
        func finish(deleted: Bool) {
            progress.itemsDone += 1
            progress.entriesDone = before.entries + size.entries
            if deleted { progress.bytesDone = before.bytes + size.bytes }
            send()
        }

        func fileManager(_ fileManager: FileManager, shouldRemoveItemAt url: URL) -> Bool {
            if cancel?.isCancelled == true { return false }
            seen += 1
            let share = min(1, Double(seen) / Double(size.entries))
            progress.entriesDone = before.entries + min(seen, size.entries)
            progress.bytesDone = before.bytes + Int64(Double(size.bytes) * share)
            send()
            return true
        }

        func send(force: Bool = false) {
            guard let report else { return }
            let now = Date.timeIntervalSinceReferenceDate
            guard force || now - lastSent >= 1.0 / 15 else { return }
            lastSent = now
            report(progress)
        }
    }

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
