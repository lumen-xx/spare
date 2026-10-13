import Foundation
import SpareCore

/// Runs CacheDelete in a child copy of Spare: its functions are private, and a changed interface can only crash the child.
enum PurgeTool {
    /// How long one purge may take in the child. A purge of files apps marked purgeable may run twice.
    static let purgeTimeout: TimeInterval = 600

    /// In the child: handles `--cachedelete query --urgency N` (prints `{"service": bytes, …}` JSON) and
    /// `--cachedelete purge --service S --urgency N` (prints PurgeResult JSON); returns true when it handled the
    /// arguments (the caller then exits).
    static func runIfAsked(_ arguments: [String]) -> Bool {
        guard let flag = arguments.firstIndex(of: "--cachedelete") else { return false }
        let command = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        let urgency = value(after: "--urgency", in: arguments).flatMap { Int($0) }.flatMap { (1...4).contains($0) ? $0 : nil }
        switch command {
        case "query":
            print(urgency.flatMap { CacheDelete.purgeable(urgency: $0) }.flatMap(encode) ?? "null")
        case "purge":
            let name = value(after: "--service", in: arguments) ?? ""
            // Only the services Spare knows by name: a purge without a service would empty all of them.
            let result = CacheDelete.Service(rawValue: name).map { CacheDelete.purge($0.rawValue, urgency: urgency ?? $0.urgency, timeout: purgeTimeout) }
                ?? CacheDelete.PurgeResult(service: name, error: "Spare doesn't purge “\(name)”.")
            print(encode(result) ?? "null")
        default:
            FileHandle.standardError.write(Data("Usage: Spare --cachedelete query --urgency 1-4\n       Spare --cachedelete purge --service NAME [--urgency 1-4]\n".utf8))
        }
        fflush(stdout)
        return true
    }

    /// In the app, off the main thread. nil when the child failed or CacheDelete is unavailable.
    static func purgeable(urgency: Int) -> [String: Int64]? {
        guard case .printed(let json) = child(["--cachedelete", "query", "--urgency", String(urgency)], timeout: 60) else { return nil }
        return try? JSONDecoder().decode([String: Int64].self, from: json)
    }

    /// A crash of the child comes back as a PurgeResult with a plain error, never a crash of the app.
    static func purge(_ service: CacheDelete.Service) -> CacheDelete.PurgeResult {
        let before = freeSpace()
        let arguments = ["--cachedelete", "purge", "--service", service.rawValue, "--urgency", String(service.urgency)]
        let problem: String
        switch child(arguments, timeout: purgeTimeout * 2 + 120) {
        case .printed(let json):
            if let result = try? JSONDecoder().decode(CacheDelete.PurgeResult.self, from: json) { return result }
            problem = "The purge didn't report back."
        case .failed(let reason):
            problem = reason
        }
        // The child may have freed space before it stopped; the volume still tells how much.
        return CacheDelete.PurgeResult(service: service.rawValue, freeBefore: before, freeAfter: freeSpace(), error: problem)
    }

    // MARK: - The child

    private enum Answer {
        case printed(Data)
        case failed(String)
    }

    /// Set once, read once the child is gone; the timer that sets it runs on another thread.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        func raise() { lock.lock(); set = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return set }
    }

    /// Runs this app again with `arguments` and returns the JSON object it printed, ignoring anything else in its output.
    private static func child(_ arguments: [String], timeout: TimeInterval) -> Answer {
        let notStarted = Answer.failed("Spare couldn't start its helper, so nothing was purged.")
        guard let executable = Bundle.main.executableURL else { return notStarted }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return notStarted }
        let timedOut = Flag()
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.raise()
            process.terminate()
            // One that doesn't stop when asked is stopped for good a moment later.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        if timedOut.isRaised { return .failed("macOS took too long, so Spare stopped waiting. It may still be clearing space.") }
        if process.terminationReason == .uncaughtSignal {
            return .failed("The clean-up helper stopped unexpectedly. macOS may have changed how this works, so Spare didn't try again.")
        }
        // The answer is the JSON object at the end of the last line that has one; a framework may have written before it.
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines.reversed() where line.hasSuffix("}") {
            var from = line.startIndex
            while let start = line[from...].firstIndex(of: "{") {
                let json = Data(line[start...].utf8)
                if (try? JSONSerialization.jsonObject(with: json)) is [String: Any] { return .printed(json) }
                from = line.index(after: start)
            }
        }
        return .failed("The purge didn't report back.")
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func freeSpace() -> Int64? {
        (try? URL(fileURLWithPath: CacheDelete.dataVolume).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
    }
}
