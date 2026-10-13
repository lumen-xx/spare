import Foundation

/// Software a package manager installed: Homebrew formulae and casks, global npm, pnpm and Bun packages, Cargo,
/// uv and pipx tools.
public struct Package: Identifiable, Sendable, Hashable {
    public enum Manager: String, CaseIterable, Sendable {
        case homebrew = "Homebrew", npm = "npm", pnpm = "pnpm", bun = "Bun", cargo = "Cargo", uv = "uv", pipx = "pipx"

        /// The command that removes packages, before their names.
        public var uninstall: [String] {
            switch self {
            case .homebrew: ["brew", "uninstall"]
            case .npm: ["npm", "uninstall", "-g"]
            case .pnpm: ["pnpm", "remove", "-g"]
            case .bun: ["bun", "remove", "-g"]
            case .cargo: ["cargo", "uninstall"]
            case .uv: ["uv", "tool", "uninstall"]
            case .pipx: ["pipx", "uninstall"]
            }
        }

        public var install: String {
            switch self {
            case .homebrew: "brew install"
            case .npm: "npm install -g"
            case .pnpm: "pnpm add -g"
            case .bun: "bun add -g"
            case .cargo: "cargo install"
            case .uv: "uv tool install"
            case .pipx: "pipx install"
            }
        }
    }

    public let manager: Manager
    public let name: String
    /// "Formula", "App (cask)", "Global package" or "Tool".
    public let kind: String
    public let version: String
    public var summary: String?
    /// Installed packages it needs.
    public var needs: [String] = []
    /// Installed packages that need it.
    public var neededBy: [String] = []
    /// Installed because someone asked for it, not only to satisfy another package.
    public var requested = true
    public var location: URL?
    public var id: String { manager.rawValue + "/" + kind + "/" + name }
    public var isCask: Bool { kind == "App (cask)" }

    public init(manager: Manager, name: String, kind: String, version: String, summary: String? = nil, location: URL? = nil) {
        self.manager = manager; self.name = name; self.kind = kind; self.version = version; self.summary = summary; self.location = location
    }

    /// The command that installs it again.
    public var reinstall: String { manager.install + (isCask ? " --cask " : " ") + name }
}

public enum PackageParsing {
    /// `brew info --json=v2 --installed`.
    public static func homebrew(_ data: Data, prefix: String) -> [Package] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var packages: [Package] = []
        for formula in root["formulae"] as? [[String: Any]] ?? [] {
            guard let name = formula["name"] as? String else { continue }
            let installed = (formula["installed"] as? [[String: Any]])?.last ?? [:]
            var package = Package(manager: .homebrew, name: name, kind: "Formula", version: installed["version"] as? String ?? "",
                                  summary: formula["desc"] as? String,
                                  location: URL(fileURLWithPath: prefix).appendingPathComponent("Cellar").appendingPathComponent(name))
            package.needs = formula["dependencies"] as? [String] ?? []
            // Newer Homebrew records only whether it was asked for; older versions also said "as dependency".
            package.requested = installed["installed_on_request"] as? Bool ?? !(installed["installed_as_dependency"] as? Bool ?? false)
            packages.append(package)
        }
        for cask in root["casks"] as? [[String: Any]] ?? [] {
            guard let token = cask["token"] as? String else { continue }
            let title = (cask["name"] as? [String])?.first
            var package = Package(manager: .homebrew, name: token, kind: "App (cask)", version: cask["installed"] as? String ?? cask["version"] as? String ?? "",
                                  summary: [title, cask["desc"] as? String].compactMap { $0 }.joined(separator: ": "),
                                  location: URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom").appendingPathComponent(token))
            package.needs = ((cask["depends_on"] as? [String: Any])?["formula"] as? [String]) ?? []
            packages.append(package)
        }
        return linked(packages)
    }

    /// Fills in which installed packages need each one, keeping only dependencies that are installed.
    static func linked(_ packages: [Package]) -> [Package] {
        let names = Set(packages.filter { !$0.isCask }.map(\.name))
        var neededBy: [String: [String]] = [:]
        for package in packages {
            for need in package.needs where names.contains(need) { neededBy[need, default: []].append(package.name) }
        }
        return packages.map { package in
            var linked = package
            linked.needs = package.needs.filter(names.contains)
            linked.neededBy = (neededBy[package.isCask ? "" : package.name] ?? []).sorted()
            return linked
        }
    }

    /// `npm ls -g --depth=0 --json`.
    public static func npm(_ data: Data, root: String) -> [Package] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = json["dependencies"] as? [String: Any] else { return [] }
        return dependencies.compactMap { name, value in
            // npm itself and corepack come with Node; removing them breaks it.
            guard name != "npm", name != "corepack" else { return nil }
            let version = (value as? [String: Any])?["version"] as? String ?? ""
            return Package(manager: .npm, name: name, kind: "Global package", version: version,
                           location: URL(fileURLWithPath: root).appendingPathComponent(name))
        }
    }

    /// `pnpm ls -g --json`.
    public static func pnpm(_ data: Data) -> [Package] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return json.flatMap { project -> [Package] in
            (project["dependencies"] as? [String: Any] ?? [:]).map { name, value in
                let info = value as? [String: Any] ?? [:]
                return Package(manager: .pnpm, name: name, kind: "Global package", version: info["version"] as? String ?? "",
                               location: (info["path"] as? String).map { URL(fileURLWithPath: $0) })
            }
        }
    }

    /// `bun pm ls -g`: a tree such as "├── typescript@5.4.5".
    public static func bun(_ text: String, root: String) -> [Package] {
        text.split(separator: "\n").compactMap { line in
            guard let start = line.firstIndex(where: { $0.isLetter || $0.isNumber || $0 == "@" }), line.contains("── ") else { return nil }
            let entry = String(line[start...])
            // Scoped names start with "@", so the version follows the last "@".
            guard let at = entry.lastIndex(of: "@"), at != entry.startIndex else { return nil }
            let name = String(entry[..<at])
            return Package(manager: .bun, name: name, kind: "Global package", version: String(entry[entry.index(after: at)...]),
                           location: URL(fileURLWithPath: root).appendingPathComponent(name))
        }
    }

    /// `cargo install --list`: "ripgrep v14.1.0:" followed by indented binary names.
    public static func cargo(_ text: String, bin: String) -> [Package] {
        var packages: [Package] = []
        for line in text.split(separator: "\n") where !line.hasPrefix(" ") && line.hasSuffix(":") {
            let parts = line.dropLast().split(separator: " ")
            guard let name = parts.first else { continue }
            let version = parts.count > 1 ? String(parts[1]).replacingOccurrences(of: "v", with: "", options: .anchored) : ""
            packages.append(Package(manager: .cargo, name: String(name), kind: "Tool", version: version))
        }
        // Each package's binaries are listed under it.
        var current: Int?
        for line in text.split(separator: "\n") {
            if !line.hasPrefix(" ") { current = packages.firstIndex { line.hasPrefix($0.name + " ") }; continue }
            if let current, packages[current].location == nil {
                packages[current].location = URL(fileURLWithPath: bin).appendingPathComponent(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return packages
    }

    /// `uv tool list`: "ruff v0.4.4" followed by "- ruff" lines.
    public static func uv(_ text: String, root: String) -> [Package] {
        text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("-"), !line.hasPrefix(" "), let space = line.firstIndex(of: " ") else { return nil }
            let name = String(line[..<space])
            let version = line[line.index(after: space)...].split(separator: " ").first.map { String($0).replacingOccurrences(of: "v", with: "", options: .anchored) } ?? ""
            return Package(manager: .uv, name: name, kind: "Tool", version: version, location: URL(fileURLWithPath: root).appendingPathComponent(name))
        }
    }

    /// `pipx list --json`.
    public static func pipx(_ data: Data) -> [Package] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let venvs = json["venvs"] as? [String: Any] else { return [] }
        return venvs.compactMap { name, value in
            let metadata = ((value as? [String: Any])?["metadata"] as? [String: Any]) ?? [:]
            let main = metadata["main_package"] as? [String: Any] ?? [:]
            return Package(manager: .pipx, name: name, kind: "Tool", version: main["package_version"] as? String ?? "",
                           location: (metadata["venv_dir"] as? String).map { URL(fileURLWithPath: $0) })
        }
    }
}
