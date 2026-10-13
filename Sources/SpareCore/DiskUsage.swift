import Foundation
import Darwin

/// How much space a file or folder takes, as the disk sees it.
public struct Usage: Sendable, Hashable {
    /// Space that removing it would give back.
    public var bytes: Int64 = 0
    /// Space in files that are also hard-linked from somewhere else, such as a pnpm store. Removing this copy
    /// frees none of it, so it is never counted in `bytes`.
    public var shared: Int64 = 0
    public var files = 0
    /// Folders inside that couldn't be read, usually for lack of permission. The size is then a lower bound.
    public var unreadable = 0

    public init(bytes: Int64 = 0, shared: Int64 = 0, files: Int = 0, unreadable: Int = 0) {
        self.bytes = bytes; self.shared = shared; self.files = files; self.unreadable = unreadable
    }

    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(bytes: a.bytes + b.bytes, shared: a.shared + b.shared, files: a.files + b.files, unreadable: a.unreadable + b.unreadable)
    }
}

/// A flag that long scans check now and then, so they stop soon after the person moves on.
public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
}

public enum DiskUsage {
    /// Measures a file or folder without following symbolic links or crossing onto other volumes.
    ///
    /// Sizes are allocated blocks, so compressed files count at their compressed size. A file with several hard
    /// links counts only when every link is inside; otherwise it is `shared`. APFS clones can't be told apart, so
    /// a cloned file counts in full here even though removing one copy frees little.
    ///
    /// - Parameters:
    ///   - skip: folders not to enter, such as ones macOS would ask permission for.
    ///   - folders: called with every folder inside, and its size, once it has been measured completely and is at
    ///     least `threshold` bytes; it lets a browser show deeper levels without measuring again.
    public static func measure(_ url: URL, skip: Set<String> = [], cancel: Cancellation? = nil,
                               threshold: Int64 = .max, folders: ((String, Int64) -> Void)? = nil) -> Usage {
        var usage = Usage()
        guard let path = strdup(url.path) else { return usage }
        defer { free(path) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let walk = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return usage }
        defer { fts_close(walk) }

        // Files with more than one link: blocks, links in total, and links seen inside.
        var linked: [UInt64: (blocks: Int64, links: Int, seen: Int)] = [:]
        // Running totals of the folders currently open, by depth; -1 marks a folder that was skipped.
        var open: [Int64] = []
        var visited = 0
        func close(above level: Int) { if open.count > level { open.removeSubrange(level...) } }
        func add(_ bytes: Int64, at level: Int) {
            let parent = level - 1
            if parent >= 0, parent < open.count, open[parent] >= 0 { open[parent] += bytes }
        }

        while let entry = fts_read(walk) {
            visited += 1
            if visited & 1023 == 0, cancel?.isCancelled == true { break }
            let info = Int32(entry.pointee.fts_info)
            let level = Int(entry.pointee.fts_level)
            switch info {
            case FTS_D:
                close(above: level)
                if level > 0, !skip.isEmpty, skip.contains(String(cString: entry.pointee.fts_path)) {
                    // fts still visits a skipped folder once more on the way out, as FTS_DP.
                    fts_set(walk, entry, FTS_SKIP)
                    usage.unreadable += 1
                    open.append(-1)
                } else {
                    open.append(0)
                }
            case FTS_DP:
                let total = level < open.count ? open[level] : 0
                close(above: level)
                guard total >= 0 else { break }
                let own = Int64(entry.pointee.fts_statp.pointee.st_blocks) * 512
                usage.bytes += own
                add(total + own, at: level)
                if total + own >= threshold, let folders { folders(String(cString: entry.pointee.fts_path), total + own) }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                let stat = entry.pointee.fts_statp.pointee
                let blocks = Int64(stat.st_blocks) * 512
                usage.files += 1
                if info == FTS_F, stat.st_nlink > 1 {
                    let key = UInt64(stat.st_ino)
                    if var known = linked[key] { known.seen += 1; linked[key] = known }
                    else { linked[key] = (blocks, Int(stat.st_nlink), 1); add(blocks, at: level) }
                } else {
                    usage.bytes += blocks
                    add(blocks, at: level)
                }
            case FTS_DNR, FTS_ERR, FTS_NS:
                // An unreadable folder comes back as FTS_DNR instead of its FTS_DP visit.
                usage.unreadable += 1
                close(above: level)
            default:
                break
            }
        }
        for file in linked.values {
            if file.seen >= file.links { usage.bytes += file.blocks } else { usage.shared += file.blocks }
        }
        return usage
    }

    /// The most recent modification time of anything directly inside a folder, or of the item itself. Used to tell
    /// when a project was last worked on without reading every file.
    public static func lastTouched(_ url: URL, ignoring: Set<String> = []) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var newest = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        for child in children where !ignoring.contains(child.lastPathComponent) {
            if let date = (try? child.resourceValues(forKeys: Set(keys)))?.contentModificationDate, date > (newest ?? .distantPast) {
                newest = date
            }
        }
        // Git touches its index on every checkout, add and commit, which says more than the folder's own date.
        if let index = (try? url.appendingPathComponent(".git/index").resourceValues(forKeys: Set(keys)))?.contentModificationDate,
           index > (newest ?? .distantPast) {
            newest = index
        }
        return newest
    }
}

public enum Volume {
    public struct Space: Sendable, Equatable {
        public var total: Int64
        /// Free right now.
        public var free: Int64
        /// Free plus what macOS can clear by itself when it needs room: local Time Machine snapshots, iCloud files
        /// that are also in the cloud, and caches it manages.
        public var available: Int64
        public var purgeable: Int64 { max(0, available - free) }
        public var used: Int64 { max(0, total - free) }
        public init(total: Int64, free: Int64, available: Int64) { self.total = total; self.free = free; self.available = available }
    }

    public static func space(of url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Space? {
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity else { return nil }
        return Space(total: Int64(total), free: Int64(free), available: max(Int64(free), values.volumeAvailableCapacityForImportantUsage ?? Int64(free)))
    }
}

public enum Bytes {
    /// "12.4 GB", using the decimal units Finder uses, so numbers match what people see elsewhere on the Mac.
    public static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
