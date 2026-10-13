import Foundation

/// Software a package manager installed: Homebrew formulae and casks, global npm, pnpm and Bun packages, Cargo,
/// uv and pipx tools.
public struct Package: Identifiable, Sendable, Hashable {
    public enum Manager: String, CaseIterable, Sendable {
        case homebrew = "Homebrew", npm = "npm", pnpm = "pnpm", bun = "Bun", cargo = "Cargo", uv = "uv", pipx = "pipx"
        /// Language versions and SDKs: Rust toolchains, Node and Python versions, Xcode's Command Line Tools.
        case toolchain = "Toolchain"
        /// Command-line tools copied into /usr/local by hand or by an installer script.
        case manual = "By hand"

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
            case .toolchain, .manual: []
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
            case .toolchain: "its version manager"
            case .manual: "the tool's own installer"
            }
        }
    }

    /// How it is removed.
    public enum Removal: Sendable, Hashable {
        /// With the package manager's own uninstall command.
        case manager
        /// With a specific command, such as `rustup toolchain uninstall stable`.
        case command([String])
        /// By moving its folder or file to the Trash.
        case trash
    }

    public let manager: Manager
    public let name: String
    /// "Formula", "App (cask)", "Global package" or "Tool".
    public var kind: String
    public let version: String
    public var summary: String?
    /// Installed packages it needs.
    public var needs: [String] = []
    /// Installed packages that need it.
    public var neededBy: [String] = []
    /// Installed because someone asked for it, not only to satisfy another package.
    public var requested = true
    public var location: URL?
    public var removal = Removal.manager
    public var origin = Origin.thirdParty
    /// Something worth knowing before removing it.
    public var note: String?
    public var id: String { manager.rawValue + "/" + kind + "/" + name + (location?.path ?? "") }
    public var isCask: Bool { kind == "App (cask)" }

    public init(manager: Manager, name: String, kind: String, version: String, summary: String? = nil, location: URL? = nil) {
        self.manager = manager; self.name = name; self.kind = kind; self.version = version; self.summary = summary; self.location = location
    }

    /// The command that installs it again.
    public var reinstall: String {
        switch manager {
        case .toolchain, .manual: "Install it again with \(manager.install)"
        default: manager.install + (isCask ? " --cask " : " ") + name
        }
    }
}

/// Language versions and SDKs installed outside a package manager's package list.
public enum Toolchains {
    public static func find(home: URL) -> [Package] {
        var found: [Package] = []
        func versions(_ relative: String, _ language: String, via: String, skip: Set<String> = []) {
            for url in Catalog.list(home.appendingPathComponent(relative))
            where !skip.contains(url.lastPathComponent) && !url.lastPathComponent.hasPrefix(".")
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                var package = Package(manager: .toolchain, name: "\(language) \(url.lastPathComponent)", kind: "\(language) (\(via))",
                                      version: url.lastPathComponent, summary: "A \(language) version installed with \(via).", location: url)
                package.removal = .trash
                found.append(package)
            }
        }
        // Rust: each toolchain through rustup, and rustup itself.
        for url in Catalog.list(home.appendingPathComponent(".rustup/toolchains")) {
            var package = Package(manager: .toolchain, name: "Rust " + url.lastPathComponent, kind: "Rust (rustup)",
                                  version: url.lastPathComponent.components(separatedBy: "-").first ?? "", summary: "A Rust compiler and its standard library.", location: url)
            package.removal = .command(["rustup", "toolchain", "uninstall", url.lastPathComponent])
            found.append(package)
        }
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".rustup").path) {
            var rustup = Package(manager: .toolchain, name: "rustup", kind: "Rust (rustup)", version: "",
                                 summary: "Rust's installer, with every toolchain and Cargo's tools in ~/.cargo.", location: home.appendingPathComponent(".rustup"))
            rustup.removal = .command(["rustup", "self", "uninstall", "-y"])
            rustup.note = "Removes every Rust toolchain and the tools Cargo installed."
            found.append(rustup)
        }
        versions(".nvm/versions/node", "Node", via: "nvm")
        versions(".local/share/fnm/node-versions", "Node", via: "fnm")
        versions("Library/Application Support/fnm/node-versions", "Node", via: "fnm")
        versions(".volta/tools/image/node", "Node", via: "Volta")
        versions(".pyenv/versions", "Python", via: "pyenv")
        versions(".local/share/uv/python", "Python", via: "uv")
        versions(".rbenv/versions", "Ruby", via: "rbenv")
        versions("sdk", "Go", via: "go")
        for tool in Catalog.list(home.appendingPathComponent(".sdkman/candidates")) {
            versions(".sdkman/candidates/\(tool.lastPathComponent)", tool.lastPathComponent.capitalized, via: "SDKMAN", skip: ["current"])
        }
        for (relative, name) in [("miniconda3", "Miniconda"), ("anaconda3", "Anaconda"), ("miniforge3", "Miniforge"), ("opt/miniconda3", "Miniconda"),
                                 ("opt/anaconda3", "Anaconda"), ("Library/Android/sdk", "Android SDK"), ("flutter", "Flutter SDK"),
                                 ("development/flutter", "Flutter SDK"), (".dotnet", ".NET SDK")] {
            let url = home.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var package = Package(manager: .toolchain, name: name, kind: "SDK", version: "", summary: "Installed in ~/\(relative).", location: url)
            package.removal = .trash
            if name.contains("conda") { package.note = "Your shell's settings may still set it up; remove its lines from ~/.zshrc." }
            found.append(package)
        }
        let tools = URL(fileURLWithPath: "/Library/Developer/CommandLineTools")
        if FileManager.default.fileExists(atPath: tools.path) {
            var package = Package(manager: .toolchain, name: "Command Line Tools for Xcode", kind: "Apple developer tools", version: "",
                                  summary: "Apple's compilers, git and make.", location: tools)
            package.removal = .trash
            package.origin = .apple
            package.note = "git, make and Homebrew need these. Get them back with: xcode-select --install"
            found.append(package)
        }
        let go = URL(fileURLWithPath: "/usr/local/go")
        if FileManager.default.fileExists(atPath: go.path) {
            var package = Package(manager: .toolchain, name: "Go", kind: "SDK", version: "", summary: "Installed in /usr/local/go.", location: go)
            package.removal = .trash
            found.append(package)
        }
        return found
    }
}

/// Command-line tools in /usr/local that no package manager tracks: copied by hand, or by an app's own installer.
public enum HandTools {
    public static func find(folders: [String] = ["/usr/local/bin", "/usr/local/sbin", "/usr/local/libexec"],
                            packageOf: (String) -> String?) -> [Package] {
        var found: [Package] = []
        for folder in folders {
            for url in Catalog.listIncludingLinks(URL(fileURLWithPath: folder)) {
                let path = url.path
                var package = Package(manager: .manual, name: url.lastPathComponent, kind: "Tool", version: "", location: url)
                package.removal = .trash
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                    let absolute = target.hasPrefix("/") ? target : url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
                    // Homebrew links its own tools here on Intel Macs; those belong on the Packages page.
                    if absolute.contains("/Cellar/") || absolute.contains("/Caskroom/") || absolute.contains("/Homebrew/") { continue }
                    if !FileManager.default.fileExists(atPath: absolute) {
                        package.kind = "Broken link"
                        package.summary = "Points to \(absolute), which is gone."
                        if let app = absolute.range(of: ".app/").map({ URL(fileURLWithPath: String(absolute[..<$0.lowerBound]) + ".app").deletingPathExtension().lastPathComponent }) {
                            package.note = "Left by \(app), which is no longer here."
                        }
                    } else if let range = absolute.range(of: ".app/") {
                        let app = URL(fileURLWithPath: String(absolute[..<range.lowerBound]) + ".app").deletingPathExtension().lastPathComponent
                        package.summary = "A link into \(app)."
                    } else {
                        package.summary = "A link to \(absolute)."
                    }
                } else if url.pathExtension == "xpc" || url.pathExtension == "app" {
                    package.kind = "Helper"
                    package.summary = "A helper program an installer put here."
                } else if let head = try? FileHandle(forReadingFrom: url).readData(ofLength: 400),
                          String(decoding: head, as: UTF8.self).hasPrefix("#!"), String(decoding: head, as: UTF8.self).contains("xcrun") {
                    package.origin = .apple
                    package.summary = "Runs Apple's \(url.lastPathComponent) through Xcode's tools."
                }
                if let receipt = packageOf(path) {
                    package.note = "Installed by the package \(receipt)."
                    if receipt.hasPrefix("com.apple.") { package.origin = .apple }
                }
                found.append(package)
            }
        }
        return found
    }
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
