import Foundation
import Darwin

/// Files cloud apps downloaded to this Mac while keeping them online. iCloud Drive and File Provider apps such as
/// OneDrive or Google Drive mark such a file purgeable; removing the download, as Finder's Remove Download does,
/// leaves it in the cloud and in its folder, and it downloads again when opened. Files someone chose to keep on this
/// Mac aren't marked, so Spare never touches them.
public enum CloudDownloads {
    public struct Place: Identifiable, Sendable, Equatable {
        public var name: String
        public var url: URL
        public var bytes: Int64
        public var files: Int
        public var id: String { url.path }

        public init(name: String, url: URL, bytes: Int64, files: Int) {
            self.name = name; self.url = url; self.bytes = bytes; self.files = files
        }
    }

    public struct Provider: Identifiable, Sendable, Equatable {
        public var name: String
        public var root: URL
        /// Its folders with downloads in them, largest first. Downloads loose at the top count only in the totals.
        public var places: [Place]
        public var bytes: Int64
        public var files: Int
        /// false when the time limit cut the scan short; the numbers are then lower than the truth.
        public var complete: Bool
        public var id: String { root.path }

        public init(name: String, root: URL, places: [Place], bytes: Int64, files: Int, complete: Bool) {
            self.name = name; self.root = root; self.places = places; self.bytes = bytes; self.files = files; self.complete = complete
        }
    }

    /// Downloads per provider, largest first; providers with none are left out. Folders that are only in the cloud
    /// are never opened, since that would make the provider download them.
    public static func scan(home: URL, timeLimit: TimeInterval = 30, cancel: Cancellation) -> [Provider] {
        withoutDownloads { providers(home: home, timeLimit: timeLimit, cancel: cancel) }
    }

    private static func providers(home: URL, timeLimit: TimeInterval, cancel: Cancellation) -> [Provider] {
        var providers: [Provider] = []
        for root in Catalog.list(home.appendingPathComponent("Library/CloudStorage")) where isFolder(root) && !cancel.isCancelled {
            let entries = Catalog.list(root).filter { !$0.lastPathComponent.hasPrefix(".") }
            providers.append(provider(providerName(root.lastPathComponent), root: root,
                                      places: entries.filter(isFolder).map { ($0.lastPathComponent, $0) },
                                      loose: entries.filter { !isFolder($0) }, timeLimit: timeLimit, cancel: cancel))
        }
        // iCloud Drive keeps its own files in com~apple~CloudDocs and each app's in a container beside it.
        let mobile = home.appendingPathComponent("Library/Mobile Documents")
        let drive = mobile.appendingPathComponent("com~apple~CloudDocs")
        let driveEntries = Catalog.list(drive).filter { !$0.lastPathComponent.hasPrefix(".") }
        let containers = Catalog.list(mobile).filter { isFolder($0) && !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != drive.lastPathComponent }
        if !driveEntries.isEmpty || !containers.isEmpty, !cancel.isCancelled {
            let places = driveEntries.filter(isFolder).map { ($0.lastPathComponent, $0) } + containers.map { (containerName($0.lastPathComponent), $0) }
            providers.append(provider("iCloud Drive", root: mobile, places: places, loose: driveEntries.filter { !isFolder($0) },
                                      timeLimit: timeLimit, cancel: cancel))
        }
        return providers.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    public struct Removal: Sendable, Equatable {
        public var files = 0
        public var bytes: Int64 = 0
        /// Downloads that stayed; `problems` says why.
        public var kept = 0
        public var problems: [String] = []

        public init(files: Int = 0, bytes: Int64 = 0, kept: Int = 0, problems: [String] = []) {
            self.files = files; self.bytes = bytes; self.kept = kept; self.problems = problems
        }
    }

    /// Removes the downloads under `url`, leaving the files online. Only a file that's marked purgeable, fully
    /// uploaded and free of conflicts goes; every other one stays, and is counted with the reason.
    public static func removeDownloads(under url: URL, cancel: Cancellation) -> Removal {
        withoutDownloads { evict(under: url, cancel: cancel) }
    }

    private static func evict(under url: URL, cancel: Cancellation) -> Removal {
        var removal = Removal()
        var notUploaded = 0, uploading = 0, conflicts = 0, failed = 0
        var firstError: String?
        walk(url, deadline: .distantFuture, cancel: cancel) { path, allocated in
            let file = URL(fileURLWithPath: path)
            let values = try? file.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
                                                            .ubiquitousItemHasUnresolvedConflictsKey])
            if values?.ubiquitousItemIsUploaded != true { notUploaded += 1 }
            else if values?.ubiquitousItemIsUploading == true { uploading += 1 }
            else if values?.ubiquitousItemHasUnresolvedConflicts == true { conflicts += 1 }
            else {
                do {
                    try FileManager.default.evictUbiquitousItem(at: file)
                    removal.files += 1
                    removal.bytes += allocated
                    return
                } catch {
                    failed += 1
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            removal.kept += 1
        }
        func stay(_ count: Int, _ one: String, _ many: String) {
            guard count > 0 else { return }
            removal.problems.append(count == 1 ? "1 file \(one), so it stays." : "\(count) files \(many), so they stay.")
        }
        stay(notUploaded, "isn't uploaded yet", "aren't uploaded yet")
        stay(uploading, "is still uploading", "are still uploading")
        stay(conflicts, "has a conflict to resolve first", "have conflicts to resolve first")
        let reason = (firstError ?? "the cloud app refused").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        stay(failed, "couldn't be removed (\(reason))", "couldn't be removed (\(reason))")
        return removal
    }

    /// "OneDrive-Personal" is "OneDrive (Personal)", "GoogleDrive-anna@example.com" is "Google Drive (anna@example.com)".
    public static func providerName(_ folder: String) -> String {
        let known = ["OneDrive": "OneDrive", "GoogleDrive": "Google Drive", "Dropbox": "Dropbox", "Box": "Box", "ProtonDrive": "Proton Drive",
                     "SynologyDrive": "Synology Drive", "pCloudDrive": "pCloud Drive", "iCloudDrive": "iCloud Drive"]
        guard let dash = folder.firstIndex(of: "-") else { return known[folder] ?? folder }
        let provider = String(folder[..<dash]), account = String(folder[folder.index(after: dash)...])
        let name = known[provider] ?? provider
        return account.isEmpty || account == provider || account == name ? name : "\(name) (\(account))"
    }

    /// "57T9237FN3~net~whatsapp~WhatsApp" is "WhatsApp", "iCloud~md~obsidian" is "Obsidian", "com~apple~CloudDocs" is "iCloud Drive".
    public static func containerName(_ folder: String) -> String {
        if folder == "com~apple~CloudDocs" { return "iCloud Drive" }
        guard let last = folder.split(separator: "~").last, !last.isEmpty else { return folder }
        return last.allSatisfy { !$0.isUppercase } ? last.prefix(1).uppercased() + last.dropFirst() : String(last)
    }

    // MARK: - Walking

    private static func provider(_ name: String, root: URL, places: [(String, URL)], loose: [URL], timeLimit: TimeInterval,
                                 cancel: Cancellation) -> Provider {
        let deadline = Date().addingTimeInterval(timeLimit)
        var found: [Place] = []
        var bytes: Int64 = 0, files = 0, complete = true
        for (placeName, url) in places {
            var place = Place(name: placeName, url: url, bytes: 0, files: 0)
            complete = walk(url, deadline: deadline, cancel: cancel) { _, allocated in place.bytes += allocated; place.files += 1 }
            bytes += place.bytes; files += place.files
            if place.bytes > 0 { found.append(place) }
            if !complete { break }
        }
        for url in loose where complete {
            complete = walk(url, deadline: deadline, cancel: cancel) { _, allocated in bytes += allocated; files += 1 }
        }
        return Provider(name: name, root: root, places: found.sorted { $0.bytes > $1.bytes }, bytes: bytes, files: files, complete: complete)
    }

    /// Calls `download` for every file under `url` that's marked purgeable, with its allocated size. Returns false
    /// when stopped by the deadline or `cancel`.
    @discardableResult
    static func walk(_ url: URL, deadline: Date, cancel: Cancellation, download: (String, Int64) -> Void) -> Bool {
        guard let path = strdup(url.path) else { return true }
        defer { free(path) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let walk = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return true }
        defer { fts_close(walk) }
        var visited = 0
        while let entry = fts_read(walk) {
            visited += 1
            if visited & 255 == 0, cancel.isCancelled || Date() >= deadline { return false }
            let info = Int32(entry.pointee.fts_info)
            let flags = entry.pointee.fts_statp?.pointee.st_flags ?? 0
            // Only in the cloud: there's nothing local inside, and reading it would start a download.
            let dataless = flags & UInt32(SF_DATALESS) != 0
            if info == FTS_D, dataless { fts_set(walk, entry, FTS_SKIP); continue }
            guard info == FTS_F, !dataless else { continue }
            let path = String(cString: entry.pointee.fts_path)
            if let file = attributes(of: path), file.purgeable { download(path, file.allocated) }
        }
        return true
    }

    /// A file's allocated size, and whether it's marked purgeable: the extended flag cloud apps set on downloads
    /// they may remove. nil when it can't be read.
    public static func attributes(of path: String) -> (allocated: Int64, purgeable: Bool)? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        // Length, then the allocated size, then the extended flags.
        var buffer = [UInt8](repeating: 0, count: 32)
        let status = buffer.withUnsafeMutableBytes { getattrlist(path, &request, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)) }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) >= 20 else { return nil }
            let allocated = raw.loadUnaligned(fromByteOffset: 4, as: Int64.self)
            let flags = raw.loadUnaligned(fromByteOffset: 12, as: UInt64.self)
            return (allocated, flags & UInt64(EF_IS_PURGEABLE) != 0)
        }
    }

    /// Runs `body` with downloads switched off for this thread: even by mistake, reading something that's only in the
    /// cloud then fails instead of making the provider download it.
    static func withoutDownloads<T>(_ body: () -> T) -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if previous >= 0 { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) } }
        return body()
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
