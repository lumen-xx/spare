import Foundation

/// Hidden files and folders in the home folder, and what's in /Users/Shared: settings, caches and data tools and apps
/// leave behind that Finder doesn't show.
public struct HomeItem: Identifiable, Sendable, Hashable {
    public enum Place: String, Sendable { case home = "Home", shared = "Shared" }
    public let url: URL
    public let place: Place
    /// The tool or app it belongs to.
    public var owner: String?
    /// "Settings", "Cache", "Data", "History" or "Keys".
    public var kind: String
    /// Holds keys, tokens or passwords: losing it can lock you out of servers or services.
    public var sensitive: Bool
    /// Its tool or app is no longer here.
    public var ownerGone: Bool
    public var origin: Origin
    public var bytes: Int64?
    public var modified: Date?
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

public enum HomeItems {
    struct Known {
        let owner: String
        /// App bundle identifiers, any of which being installed means the owner is still here.
        var apps: [String] = []
        /// Commands, any of which being found means the owner is still here.
        var tools: [String] = []
        var kind = "Data"
        var sensitive = false
    }

    static let known: [String: Known] = [
        ".ssh": Known(owner: "SSH", tools: ["ssh"], kind: "Keys", sensitive: true),
        ".gnupg": Known(owner: "GnuPG", tools: ["gpg"], kind: "Keys", sensitive: true),
        ".aws": Known(owner: "AWS CLI", tools: ["aws"], kind: "Keys", sensitive: true),
        ".azure": Known(owner: "Azure CLI", tools: ["az"], kind: "Keys", sensitive: true),
        ".kube": Known(owner: "Kubernetes", tools: ["kubectl"], kind: "Keys", sensitive: true),
        ".netrc": Known(owner: "Network logins", kind: "Keys", sensitive: true),
        ".git-credentials": Known(owner: "Git", tools: ["git"], kind: "Keys", sensitive: true),
        ".npmrc": Known(owner: "npm", tools: ["npm"], kind: "Settings", sensitive: true),
        ".gitconfig": Known(owner: "Git", tools: ["git"], kind: "Settings"),
        ".config": Known(owner: "Many tools", kind: "Settings"),
        ".cache": Known(owner: "Many tools", kind: "Cache"),
        ".local": Known(owner: "Tools installed for you", kind: "Data"),
        ".zshrc": Known(owner: "Your shell", kind: "Settings"), ".zprofile": Known(owner: "Your shell", kind: "Settings"),
        ".zshenv": Known(owner: "Your shell", kind: "Settings"), ".zsh_history": Known(owner: "Your shell", kind: "History"),
        ".zsh_sessions": Known(owner: "Your shell", kind: "History"), ".bash_profile": Known(owner: "Bash", kind: "Settings"),
        ".bashrc": Known(owner: "Bash", kind: "Settings"), ".bash_history": Known(owner: "Bash", kind: "History"),
        ".bash_sessions": Known(owner: "Bash", kind: "History"), ".profile": Known(owner: "Your shell", kind: "Settings"),
        ".oh-my-zsh": Known(owner: "Oh My Zsh", kind: "Settings"),
        ".lesshst": Known(owner: "less", kind: "History"), ".viminfo": Known(owner: "Vim", kind: "History"), ".vim": Known(owner: "Vim", kind: "Settings"),
        ".python_history": Known(owner: "Python", kind: "History"), ".node_repl_history": Known(owner: "Node", kind: "History"),
        ".sqlite_history": Known(owner: "SQLite", kind: "History"), ".psql_history": Known(owner: "PostgreSQL", tools: ["psql"], kind: "History"),
        ".redis": Known(owner: "Redis", tools: ["redis-server"]), ".rediscli_history": Known(owner: "Redis", kind: "History"),
        ".npm": Known(owner: "npm", tools: ["npm"], kind: "Cache"), ".yarn": Known(owner: "Yarn", tools: ["yarn"], kind: "Cache"),
        ".yarnrc": Known(owner: "Yarn", tools: ["yarn"], kind: "Settings"), ".pnpm-store": Known(owner: "pnpm", tools: ["pnpm"], kind: "Cache"),
        ".bun": Known(owner: "Bun", tools: ["bun"]), ".deno": Known(owner: "Deno", tools: ["deno"]),
        ".cargo": Known(owner: "Cargo", tools: ["cargo"]), ".rustup": Known(owner: "Rust", tools: ["rustup"]),
        ".nvm": Known(owner: "nvm"), ".pyenv": Known(owner: "pyenv", tools: ["pyenv"]), ".rbenv": Known(owner: "rbenv", tools: ["rbenv"]),
        ".gem": Known(owner: "RubyGems", tools: ["gem"]), ".gradle": Known(owner: "Gradle", tools: ["gradle"], kind: "Cache"),
        ".m2": Known(owner: "Maven", tools: ["mvn"], kind: "Cache"), ".conda": Known(owner: "Conda", tools: ["conda"]),
        ".condarc": Known(owner: "Conda", tools: ["conda"], kind: "Settings"), ".ipython": Known(owner: "IPython", tools: ["ipython"]),
        ".jupyter": Known(owner: "Jupyter", tools: ["jupyter"]), ".matplotlib": Known(owner: "Matplotlib", kind: "Cache"),
        ".dotnet": Known(owner: ".NET", tools: ["dotnet"]), ".nuget": Known(owner: "NuGet", tools: ["dotnet"], kind: "Cache"),
        ".swiftpm": Known(owner: "Swift Package Manager", tools: ["swift"]), ".pub-cache": Known(owner: "Dart", tools: ["dart", "flutter"], kind: "Cache"),
        ".android": Known(owner: "Android Studio", apps: ["com.google.android.studio"]),
        ".docker": Known(owner: "Docker", apps: ["com.docker.docker"], tools: ["docker"], kind: "Settings"),
        ".orbstack": Known(owner: "OrbStack", apps: ["dev.kdrag0n.MacVirt"]),
        ".vscode": Known(owner: "Visual Studio Code", apps: ["com.microsoft.VSCode"], kind: "Extensions"),
        ".cursor": Known(owner: "Cursor", apps: ["com.todesktop.230313mzl4w4u92"], kind: "Extensions"),
        ".windsurf": Known(owner: "Windsurf", apps: ["com.exafunction.windsurf"], kind: "Extensions"),
        ".antigravity": Known(owner: "Antigravity", apps: ["com.google.antigravity"], tools: ["antigravity"]),
        ".antigravity-ide": Known(owner: "Antigravity", apps: ["com.google.antigravity"], tools: ["antigravity"]),
        ".codex": Known(owner: "Codex", apps: ["com.openai.codex"], tools: ["codex"]),
        ".claude": Known(owner: "Claude Code", tools: ["claude"]), ".claude.json": Known(owner: "Claude Code", tools: ["claude"], kind: "Settings"),
        ".gemini": Known(owner: "Gemini CLI", tools: ["gemini"]), ".opencode": Known(owner: "opencode", tools: ["opencode"]),
        ".expo": Known(owner: "Expo"), ".vercel": Known(owner: "Vercel CLI", tools: ["vercel"], kind: "Settings"),
        ".netlify": Known(owner: "Netlify CLI", tools: ["netlify"], kind: "Settings"), ".supabase": Known(owner: "Supabase CLI", tools: ["supabase"]),
        ".terraform.d": Known(owner: "Terraform", tools: ["terraform"]), ".pm2": Known(owner: "PM2", tools: ["pm2"]),
        ".zoomus": Known(owner: "Zoom", apps: ["us.zoom.xos"]), ".cups": Known(owner: "Printing", kind: "Settings"),
        ".mono": Known(owner: "Mono", tools: ["mono"]), ".wdm": Known(owner: "WebDriver Manager", kind: "Cache"),
        ".thumbnails": Known(owner: "Image viewers", kind: "Cache"), ".rest-client": Known(owner: "REST Client", kind: "Data")
    ]

    /// Never listed: macOS's own, or not something anyone would remove.
    static let ignored: Set<String> = [".Trash", ".DS_Store", ".localized", ".CFUserTextEncoding", ".file"]

    /// - Parameters:
    ///   - appInstalled: whether an app with this bundle identifier is installed.
    ///   - toolFound: whether a command with this name is on the PATH.
    ///   - appNamed: whether an installed app's name contains this, for apps whose identifier isn't known for sure.
    public static func hidden(home: URL, appInstalled: (String) -> Bool, toolFound: (String) -> Bool,
                              appNamed: (String) -> Bool = { _ in false }) -> [HomeItem] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return entries.filter { $0.hasPrefix(".") && !ignored.contains($0) }.map { name in
            let url = home.appendingPathComponent(name)
            let info = known[name]
            let present = info.map { $0.apps.contains(where: appInstalled) || $0.tools.contains(where: toolFound) || (!$0.apps.isEmpty && appNamed($0.owner)) }
            let checkable = info.map { !$0.apps.isEmpty || !$0.tools.isEmpty } ?? false
            let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let kind = info?.kind ?? (name.hasSuffix("history") || name.hasSuffix("hst") ? "History" : folder ? "Data" : "Settings")
            return HomeItem(url: url, place: .home, owner: info?.owner, kind: kind, sensitive: info?.sensitive ?? false,
                            ownerGone: checkable && present == false, origin: .thirdParty, bytes: nil, modified: Catalog.modified(url))
        }
    }

    /// What's in /Users/Shared. Hidden files macOS keeps there are locked.
    public static func shared(root: URL = URL(fileURLWithPath: "/Users/Shared")) -> [HomeItem] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let owners: [String: String] = ["adobe": "Adobe", "adobegcinfo": "Adobe", "ngl": "Adobe", ".logishrd": "Logitech", "blackmagic design": "Blackmagic",
                                        "native instruments": "Native Instruments", "ableton": "Ableton", "steam": "Steam", "epic games": "Epic Games",
                                        "riot games": "Riot Games", "relocated items": "A macOS upgrade", "previously relocated items": "A macOS upgrade",
                                        "previously relocated items 1": "A macOS upgrade", "sc info": "macOS"]
        return entries.filter { !ignored.contains($0) }.map { name in
            let url = root.appendingPathComponent(name)
            let owner = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountName] as? String
            // Hidden files written by macOS's setup and migration, owned by root or its setup account.
            // "SC Info" holds the Mac's authorization for purchased media.
            let system = (name.hasPrefix(".") && (owner == "root" || owner == "_mbsetupuser") && owners[name.lowercased()] == nil) || name == "SC Info"
            return HomeItem(url: url, place: .shared, owner: owners[name.lowercased()] ?? (system ? "macOS" : nil),
                            kind: name.hasPrefix(".") ? "Settings" : "Data", sensitive: false, ownerGone: false,
                            origin: system ? .macOS : .thirdParty, bytes: nil, modified: Catalog.modified(url))
        }
    }
}
