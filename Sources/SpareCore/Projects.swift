import Foundation

/// Build and dependency folders inside code projects: big, and recreated by the project's own tools.
public enum Projects {
    public struct Kind: Sendable {
        /// The folder's name.
        public let folder: String
        /// Files next to it that prove what it is. A folder called "build" or "target" is only touched when the
        /// project file of the tool that makes it sits beside it.
        public let markers: [String]
        /// How to get it back.
        public let restore: String
    }

    public struct Artifact: Sendable {
        public let folder: URL
        public let project: URL
        public let kind: Kind
    }

    public static let kinds: [Kind] = [
        Kind(folder: "node_modules", markers: ["package.json"], restore: "Install packages again to restore"),
        Kind(folder: ".next", markers: ["package.json"], restore: "Rebuilt by Next.js"),
        Kind(folder: ".nuxt", markers: ["package.json"], restore: "Rebuilt by Nuxt"),
        Kind(folder: ".svelte-kit", markers: ["package.json"], restore: "Rebuilt by SvelteKit"),
        Kind(folder: ".turbo", markers: ["package.json", "turbo.json"], restore: "Rebuilt by Turborepo"),
        Kind(folder: ".parcel-cache", markers: ["package.json"], restore: "Rebuilt by Parcel"),
        Kind(folder: ".angular", markers: ["angular.json"], restore: "Rebuilt by Angular"),
        Kind(folder: ".build", markers: ["Package.swift"], restore: "Rebuilt by swift build"),
        Kind(folder: "target", markers: ["Cargo.toml"], restore: "Rebuilt by cargo build"),
        Kind(folder: "Pods", markers: ["Podfile"], restore: "Run pod install to restore"),
        Kind(folder: ".venv", markers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "uv.lock"], restore: "Recreate the environment to restore"),
        Kind(folder: "venv", markers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "uv.lock"], restore: "Recreate the environment to restore"),
        Kind(folder: ".gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], restore: "Rebuilt by Gradle"),
        Kind(folder: "build", markers: ["build.gradle", "build.gradle.kts"], restore: "Rebuilt by Gradle"),
        Kind(folder: ".dart_tool", markers: ["pubspec.yaml"], restore: "Run flutter pub get to restore"),
        Kind(folder: "vendor", markers: ["composer.json"], restore: "Run composer install to restore"),
        Kind(folder: ".zig-cache", markers: ["build.zig"], restore: "Rebuilt by zig build"),
        Kind(folder: "elm-stuff", markers: ["elm.json"], restore: "Rebuilt by elm make")
    ]

    /// Ignored when judging how recently a project was worked on: tools write to these on their own.
    public static let ignoredWhenDating: Set<String> = Set(kinds.map(\.folder)).union([".git", ".DS_Store"])

    /// How deep below a project folder to look; monorepos keep packages a few levels down.
    static let maximumDepth = 6

    /// Folders never worth walking into while looking for projects.
    static let neverEnter: Set<String> = ["Library", "Applications", ".Trash", ".git", "Photos Library.photoslibrary"]

    public static func artifacts(in roots: [URL], cancel: Cancellation) -> [Artifact] {
        let byName = Dictionary(grouping: kinds, by: \.folder)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var found: [Artifact] = []
        var visited = Set<String>()
        var queue = roots.map { ($0.standardizedFileURL, 0) }
        var next = 0
        while next < queue.count, !cancel.isCancelled {
            let (folder, depth) = queue[next]
            next += 1
            guard visited.insert(folder.path.lowercased()).inserted else { continue }
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: []) else { continue }
            let names = Set(entries.map(\.lastPathComponent))
            for entry in entries {
                let name = entry.lastPathComponent
                guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                      values.isSymbolicLink != true else { continue }
                if let kind = byName[name]?.first(where: { $0.markers.contains(where: names.contains) }) {
                    found.append(Artifact(folder: entry, project: folder, kind: kind))
                    continue
                }
                // Dependency folders without their project file are still never entered; they hold thousands of folders.
                if name == "node_modules" || name.hasPrefix(".") || values.isPackage == true || neverEnter.contains(name) { continue }
                if depth < maximumDepth { queue.append((entry, depth + 1)) }
            }
        }
        return found
    }

    /// Common places people keep code, as found in a home folder.
    public static let usualFolders: Set<String> = ["dev", "developer", "projects", "code", "src", "source", "repos", "repositories",
                                                   "git", "github", "gitlab", "sites", "workspace", "work", "coding", "programming"]

    public static func defaultRoots(home: URL) -> [URL] {
        Catalog.list(home).filter { url in
            usualFolders.contains(url.lastPathComponent.lowercased())
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
