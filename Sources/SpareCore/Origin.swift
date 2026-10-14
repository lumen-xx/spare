import Foundation
import Security

/// Who something came from. Spare shows this everywhere it lists what is on the Mac, and never removes macOS's own.
public enum Origin: String, Sendable, Hashable, CaseIterable {
    /// Part of macOS itself. Removing it could break the system, so Spare doesn't offer to.
    case macOS
    /// Made by Apple, but added later and removable, such as SF Symbols' fonts or Xcode's tools.
    case apple
    /// Everything else.
    case thirdParty
    /// Made by Spare itself, such as its privacy profile.
    case spare

    public var label: String {
        switch self {
        case .macOS: "macOS"
        case .apple: "Apple"
        case .thirdParty: "Added"
        case .spare: "Spare"
        }
    }

    public var removable: Bool { self != .macOS }
}

public enum Origins {
    /// Signed by Apple itself, rather than with a developer certificate Apple issued to someone else.
    public static func signedByApple(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess else { return false }
        // Checks who signed it without hashing every file inside, which would take seconds for large bundles.
        let flags = SecCSFlags(rawValue: (1 << 1) | (1 << 2))
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// The installer package that put a file in place, from macOS's receipts.
    public static func package(of path: String) -> String? {
        let output = run("/usr/sbin/pkgutil", ["--file-info", path])
        return output.split(separator: "\n").first { $0.hasPrefix("pkgid: ") }.map { String($0.dropFirst("pkgid: ".count)) }
    }

    /// Packages macOS itself installs: its data template, and the core packages of older macOS versions.
    static func isSystemPackage(_ id: String) -> Bool {
        id.hasPrefix("com.apple.files.") || ["com.apple.pkg.Core", "com.apple.pkg.Essentials", "com.apple.pkg.BaseSystemResources",
                                             "com.apple.pkg.BSD", "com.apple.pkg.AdditionalEssentials"].contains(id)
    }

    /// Where a file or bundle in /Library or ~/Library came from.
    public static func origin(of url: URL) -> Origin {
        let package = Origins.package(of: url.path)
        if let package {
            if isSystemPackage(package) { return .macOS }
            if package.hasPrefix("com.apple.") { return .apple }
            return .thirdParty
        }
        // Not from an installer: copied in by a person or an app. Apple-signed bundles still count as Apple's.
        let isBundle = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true || ["driver", "plugin", "kext", "bundle", "component", "appex", "qlgenerator", "mdimporter", "prefPane", "saver"].contains(url.pathExtension)
        if isBundle, signedByApple(url) { return url.path.hasPrefix("/System/") ? .macOS : .apple }
        return .thirdParty
    }

    static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
