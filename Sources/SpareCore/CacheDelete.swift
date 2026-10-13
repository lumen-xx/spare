import Foundation

/// macOS's own clean-up, the one it runs when the disk is nearly full. Each part of macOS that keeps space it can give
/// back answers as a service: Time Machine for its snapshots, the file system for files apps marked purgeable, the
/// asset daemon for downloads nothing needs any more. The functions are private to macOS, so they're looked up when
/// first used, and the app calls them only from a child copy of itself: a changed interface then crashes only that.
public enum CacheDelete {
    public static let dataVolume = "/System/Volumes/Data"

    /// The services Spare knows by name. macOS has more; queries report those under their own names.
    public enum Service: String, CaseIterable, Codable, Sendable {
        case timeMachine = "com.apple.TMCacheDelete"
        case purgeableFiles = "com.apple.fspurgeable_data"
        case cloudCopies = "com.apple.fspurgeable_document"
        case containerCaches = "com.apple.cache_delete_app_container_caches"
        case macOSDownloads = "com.apple.mobileassetd.cache-delete"
        case spotlight = "com.apple.metadata.mds.cachedelete"
        case thumbnails = "com.apple.quicklook.ThumbnailsAgent.CacheDelete"

        public var title: String {
            switch self {
            case .timeMachine: "Time Machine snapshots"
            case .purgeableFiles: "Files apps marked as purgeable"
            case .cloudCopies: "Cloud files that are also online"
            case .containerCaches: "Caches inside apps' containers"
            case .macOSDownloads: "macOS downloads nothing needs any more"
            case .spotlight: "Spotlight index"
            case .thumbnails: "Quick Look thumbnails"
            }
        }

        public var about: String {
            switch self {
            case .timeMachine: "Hourly copies of this disk Time Machine keeps while the backup disk is away."
            case .purgeableFiles: "Copies apps keep but told macOS it may delete when space runs low, such as streamed media."
            case .cloudCopies: "Copies on this Mac of iCloud Drive and other cloud files that are safely stored online."
            case .containerCaches: "Caches apps keep inside their own sandboxed folders."
            case .macOSDownloads: "Models, voices and data macOS fetched for a feature that no longer uses them."
            case .spotlight: "Parts of the search index that Spotlight can build again."
            case .thumbnails: "Previews of your files that Finder and Quick Look draw again when needed."
            }
        }

        /// Spare offers to free it. macOS clears the others on its own when it needs room, or another page handles them.
        public var spareFrees: Bool { self == .purgeableFiles || self == .macOSDownloads }

        /// How urgently to ask, from 1 to 4. macOS hands over more the higher it is; downloads go at the gentlest.
        public var urgency: Int { self == .macOSDownloads ? 1 : 3 }
    }

    public static var isAvailable: Bool { functions != nil }

    /// Read-only. Bytes per service name at `urgency`.
    public static func purgeable(volume: String = dataVolume, urgency: Int, services: [String]? = nil) -> [String: Int64]? {
        guard let query = functions?.query else { return nil }
        var info: [String: Any] = ["CACHE_DELETE_VOLUME": volume, "CACHE_DELETE_URGENCY_LIMIT": urgency]
        if let services { info["CACHE_DELETE_SERVICES"] = services }
        guard let answer = query(info as CFDictionary)?.takeRetainedValue() as? [String: Any] else { return nil }
        let services = itemized(answer)
        // A volume macOS doesn't know comes back as an error and nothing else.
        if services.isEmpty, answer["CACHE_DELETE_ERROR"] != nil { return nil }
        return services
    }

    /// What one purge did.
    public struct PurgeResult: Codable, Sendable, Equatable {
        public var service: String
        /// What the service says it removed.
        public var reported: Int64?
        public var freeBefore: Int64?
        public var freeAfter: Int64?
        /// Plain English, nil when it worked.
        public var error: String?

        /// The volume's gain when both readings exist and it's positive, otherwise what the service reported. Services
        /// often report nothing, or the space only returns once the file system has caught up.
        public var freed: Int64 {
            if let freeBefore, let freeAfter, freeAfter - freeBefore > 0 { return freeAfter - freeBefore }
            return max(0, reported ?? 0)
        }

        public init(service: String, reported: Int64? = nil, freeBefore: Int64? = nil, freeAfter: Int64? = nil, error: String? = nil) {
            self.service = service; self.reported = reported; self.freeBefore = freeBefore; self.freeAfter = freeAfter; self.error = error
        }
    }

    /// Purges one service (with the filter check). Retries once at urgency 4 for purgeableFiles when urgency 3 freed
    /// nothing but the estimate was > 0.
    public static func purge(_ service: String, volume: String = dataVolume, urgency: Int, timeout: TimeInterval = 600) -> PurgeResult {
        let (first, estimate) = attempt(service, volume: volume, urgency: urgency, timeout: timeout)
        // Estimates run ahead of what a service gives up at 3; asking at 4 removes what it declined.
        guard service == Service.purgeableFiles.rawValue, urgency == 3, first.error == nil, first.freed == 0, estimate > 0 else { return first }
        var second = attempt(service, volume: volume, urgency: 4, timeout: timeout).result
        second.freeBefore = first.freeBefore ?? second.freeBefore
        if let reported = first.reported { second.reported = reported + (second.reported ?? 0) }
        return second
    }

    /// The services in an answer: every number under a name that isn't one of CacheDelete's own keys.
    public static func itemized(_ answer: [String: Any]) -> [String: Int64] {
        var services: [String: Int64] = [:]
        for (key, value) in answer where !key.hasPrefix("CACHE_DELETE_") {
            if let bytes = number(value) { services[key] = max(0, bytes) }
        }
        return services
    }

    // MARK: - Calls into macOS

    private typealias Query = @convention(c) (CFDictionary) -> Unmanaged<CFDictionary>?
    private typealias Callback = @convention(block) (CFDictionary?) -> Void
    private typealias Purge = @convention(c) (CFDictionary, Callback) -> UnsafeRawPointer?

    private struct Functions {
        let query: Query
        let purge: Purge
    }

    private static let functions: Functions? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/CacheDelete.framework/CacheDelete", RTLD_NOW),
              let query = dlsym(handle, "CacheDeleteCopyItemizedPurgeableSpaceWithInfo"),
              let purge = dlsym(handle, "CacheDeletePurgeSpaceWithInfoSync") else { return nil }
        return Functions(query: unsafeBitCast(query, to: Query.self), purge: unsafeBitCast(purge, to: Purge.self))
    }()

    /// Holds the answer for a callback that may arrive on another thread, or after Spare stopped waiting.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: Any]?
        func set(_ value: [String: Any]?) { lock.lock(); stored = value; lock.unlock() }
        var value: [String: Any]? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private static func attempt(_ service: String, volume: String, urgency: Int, timeout: TimeInterval) -> (result: PurgeResult, estimate: Int64) {
        var result = PurgeResult(service: service)
        guard let functions else {
            result.error = "macOS's own clean-up isn't available on this Mac."
            return (result, 0)
        }
        // Ask first what a purge limited to this service would touch. If macOS ignored the limit, the purge would empty
        // every service, Time Machine's snapshots included.
        guard let estimate = purgeable(volume: volume, urgency: urgency, services: [service]) else {
            result.error = "macOS didn't say what it could remove, so nothing was purged."
            return (result, 0)
        }
        guard estimate.keys.allSatisfy({ $0 == service }) else {
            result.error = "macOS ignored the request to limit the purge, so nothing was purged."
            return (result, 0)
        }
        guard let expected = estimate[service] else {
            result.error = "macOS doesn't offer this clean-up here, so nothing was purged."
            return (result, 0)
        }
        result.freeBefore = freeSpace(volume)
        // As much as the service can give: the size of the whole disk is a limit none can reach.
        let amount = capacity(volume) ?? max(expected, 1)
        let info: [String: Any] = ["CACHE_DELETE_VOLUME": volume, "CACHE_DELETE_URGENCY": urgency, "CACHE_DELETE_AMOUNT": amount,
                                   "CACHE_DELETE_SERVICES": [service], "CACHE_DELETE_QUERY_AFTER_PURGE": true]
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        // Some services answer after the call has returned, so the block is a stored, escaping one; a closure written
        // into the call would be checked for not escaping and trap.
        let callback: Callback = { reply in
            answer.set((reply as NSDictionary?) as? [String: Any])
            done.signal()
        }
        _ = functions.purge(info as CFDictionary, callback)
        guard wait(done, timeout: timeout) else {
            result.error = "macOS didn't finish within \(Int(timeout / 60)) minutes. It may still be clearing space."
            return (result, expected)
        }
        let reply = answer.value ?? [:]
        result.reported = reply["CACHE_DELETE_AMOUNT"].flatMap(number)
        if let problem = reply["CACHE_DELETE_ERROR"] {
            result.error = "macOS couldn't purge it: \(problem)."
        }
        result.freeAfter = settledFreeSpace(volume)
        return (result, expected)
    }

    /// Waits for the purge's answer. On the main thread the run loop keeps turning, in case macOS answers there.
    private static func wait(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
        guard Thread.isMainThread else { return semaphore.wait(timeout: .now() + timeout) == .success }
        let deadline = Date().addingTimeInterval(timeout)
        while semaphore.wait(timeout: .now()) == .timedOut {
            if Date() >= deadline { return false }
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        return true
    }

    static func number(_ value: Any) -> Int64? {
        // Booleans arrive as numbers too; only real numbers count.
        let object = value as AnyObject
        guard CFGetTypeID(object) == CFNumberGetTypeID(), let number = object as? NSNumber else { return nil }
        return number.int64Value
    }

    static func freeSpace(_ volume: String) -> Int64? {
        (try? URL(fileURLWithPath: volume).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
    }

    static func capacity(_ volume: String) -> Int64? {
        (try? URL(fileURLWithPath: volume).resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
    }

    /// Freed blocks come back a moment after a purge returns, so the reading is repeated, for about two seconds at
    /// most, until it stops changing.
    static func settledFreeSpace(_ volume: String) -> Int64? {
        var last = freeSpace(volume)
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 0.5)
            let now = freeSpace(volume)
            if now == last { break }
            last = now
        }
        return last
    }
}
