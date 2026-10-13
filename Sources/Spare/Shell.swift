import Foundation
import SpareCore

/// Runs command-line tools the way they'd run in Terminal. Apps opened from Finder get a bare PATH, so Spare
/// adds the usual tool folders and whatever the login shell sets up.
enum Shell {
    static let path: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folders = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin",
                       "\(home)/.local/bin", "\(home)/Library/pnpm", "\(home)/.volta/bin", "\(home)/go/bin"]
        // nvm keeps each Node version in its own folder; the newest is the likeliest to be in use.
        let nvm = "\(home)/.nvm/versions/node"
        if let newest = (try? FileManager.default.contentsOfDirectory(atPath: nvm))?.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }).first {
            folders.append("\(nvm)/\(newest)/bin")
        }
        let login = run("/bin/zsh", ["-l", "-c", "printf '__PATH__%s' \"$PATH\""], path: nil, timeout: 6).output
        if let range = login.range(of: "__PATH__") { folders += login[range.upperBound...].split(separator: ":").map(String.init) }
        folders += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return folders.filter { seen.insert($0).inserted }.joined(separator: ":")
    }()

    static func which(_ tool: String) -> String? {
        path.split(separator: ":").map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Result: Sendable {
        var status: Int32
        var output: String
        var succeeded: Bool { status == 0 }
    }

    /// Runs a tool found on the PATH, or an absolute path, with a time limit. Output and errors come back together.
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 300) -> Result {
        guard let executable = tool.hasPrefix("/") ? tool : which(tool) else { return Result(status: 127, output: "\(tool) isn't installed.") }
        return run(executable, arguments, path: path, timeout: timeout)
    }

    private static func run(_ executable: String, _ arguments: [String], path: String?, timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let path { environment["PATH"] = path }
        // Homebrew otherwise updates itself first and may ask questions.
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NONINTERACTIVE"] = "1"
        environment["CI"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Result(status: 126, output: "Couldn't start \(executable).") }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
