import Foundation

/// What Docker and the apps like it keep. Images, containers, volumes and build cache live inside a virtual machine's
/// disk, a single large file that grows as they do and rarely shrinks on its own.
public enum Docker {
    /// One line of `docker system df`.
    public struct Usage: Identifiable, Sendable, Equatable {
        /// "Images", "Containers", "Local Volumes", "Build Cache".
        public var kind: String
        public var count: Int
        public var active: Int
        public var bytes: Int64
        /// What `docker system prune` and the like would free.
        public var reclaimable: Int64
        public var id: String { kind }

        public init(kind: String, count: Int, active: Int, bytes: Int64, reclaimable: Int64) {
            self.kind = kind; self.count = count; self.active = active; self.bytes = bytes; self.reclaimable = reclaimable
        }
    }

    /// `docker system df --format '{{json .}}'`: one JSON object per line.
    public static func usage(lines: String) -> [Usage] {
        lines.split(whereSeparator: \.isNewline).compactMap { line in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let kind = object["Type"] as? String else { return nil }
            func text(_ key: String) -> String? {
                switch object[key] {
                case let text as String: text
                case let number as NSNumber: number.stringValue
                default: nil
                }
            }
            return Usage(kind: kind, count: text("TotalCount").flatMap { Int($0) } ?? 0, active: text("Active").flatMap { Int($0) } ?? 0,
                         bytes: text("Size").flatMap(bytes) ?? 0, reclaimable: text("Reclaimable").flatMap(bytes) ?? 0)
        }
    }

    /// "1.23GB", "512.4MB (40%)", "0B", "1.2kB": the decimal units Docker prints, and binary ones such as "1.5GiB".
    public static func bytes(_ text: String) -> Int64? {
        let size = (text.split(separator: "(").first.map(String.init) ?? text).trimmingCharacters(in: .whitespaces)
        let number = size.prefix { $0.isNumber || $0 == "." }
        let unit = size.dropFirst(number.count).trimmingCharacters(in: .whitespaces).lowercased()
        guard let value = Double(number) else { return nil }
        let units: [String: Double] = ["": 1, "b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12, "pb": 1e15,
                                       "kib": 1_024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776, "pib": 1_125_899_906_842_624]
        guard let scale = units[unit] else { return nil }
        return Int64((value * scale).rounded())
    }

    /// A virtual machine's disk.
    public struct DiskImage: Identifiable, Sendable, Equatable {
        public var app: String
        public var url: URL
        /// Allocated, not the size Finder shows: these files are sparse, so they take less than they say.
        public var bytes: Int64
        public var id: String { url.path }

        public init(app: String, url: URL, bytes: Int64) { self.app = app; self.url = url; self.bytes = bytes }
    }

    /// The disks of Docker Desktop, OrbStack, Colima and Podman's machines.
    public static func diskImages(home: URL) -> [DiskImage] {
        var candidates: [(String, URL)] = [
            ("Docker Desktop", home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")),
            ("Docker Desktop", home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.qcow2")),
            ("OrbStack", home.appendingPathComponent(".orbstack/data/data.img")),
            ("OrbStack", home.appendingPathComponent("Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img"))
        ]
        // Colima names its machines "colima", or "colima-<profile>" for other profiles.
        for machine in Catalog.list(home.appendingPathComponent(".colima/_lima")) {
            let name = machine.lastPathComponent
            let profile = name.hasPrefix("colima-") ? String(name.dropFirst("colima-".count)) : nil
            candidates.append((profile.map { "Colima (\($0))" } ?? "Colima", machine.appendingPathComponent("diffdisk")))
        }
        let podman = home.appendingPathComponent(".local/share/containers/podman/machine")
        if let walk = FileManager.default.enumerator(at: podman, includingPropertiesForKeys: nil) {
            for case let url as URL in walk where ["raw", "qcow2"].contains(url.pathExtension.lowercased()) {
                candidates.append(("Podman", url))
            }
        }
        // OrbStack's two places can be one file reached through a link.
        var seen = Set<String>()
        return candidates.compactMap { app, url in
            var stats = stat()
            guard lstat(url.path, &stats) == 0, stats.st_mode & S_IFMT == S_IFREG, stats.st_blocks > 0,
                  seen.insert("\(stats.st_dev):\(stats.st_ino)").inserted else { return nil }
            return DiskImage(app: app, url: url, bytes: Int64(stats.st_blocks) * 512)
        }
    }
}
