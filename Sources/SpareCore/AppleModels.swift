import Foundation
import ObjectiveC

/// Apple Intelligence's downloaded models, through Apple's unified asset service: how much of each set is on this
/// Mac, and removing a set. The service and its reset operation were mapped by pared (github.com/4evy/pared, MIT) and
/// RemoveMacAI. Nothing here needs an entitlement or a password.
public enum AppleModels {
    static let framework = "/System/Library/PrivateFrameworks/UnifiedAssetFramework.framework/UnifiedAssetFramework"
    static let service = "com.apple.siri.uaf.subscription.service"

    static let loaded: Bool = dlopen(framework, RTLD_NOW) != nil

    /// Whether this Mac's asset service is the one Spare knows.
    public static var available: Bool { assetType(of: Debloat.foundationModels) != nil }

    private static func type(_ name: String) -> AnyObject? { NSClassFromString(name).map { $0 as AnyObject } }

    /// Sends a message without an argument.
    private static func call(_ target: AnyObject?, _ selector: String) -> AnyObject? {
        let name = NSSelectorFromString(selector)
        guard let target, target.responds(to: name) else { return nil }
        return target.perform(name)?.takeUnretainedValue()
    }

    /// Sends a message with one argument, which may be nil, as for an error pointer nobody reads.
    private static func call(_ target: AnyObject?, _ selector: String, with argument: Any?) -> AnyObject? {
        let name = NSSelectorFromString(selector)
        guard let target, target.responds(to: name) else { return nil }
        return target.perform(name, with: argument)?.takeUnretainedValue()
    }

    /// The asset type macOS files a set under, or nil when this macOS has no such set.
    public static func assetType(of set: String) -> String? {
        guard loaded else { return nil }
        let manager = call(type("UAFConfigurationManager"), "defaultManager")
        return call(call(manager, "getAssetSet:", with: set), "autoAssetType") as? String
    }

    /// Bytes on disk by asset type, from the service's inventory; nil when it didn't answer.
    public static func inventory() -> [String: Int64]? {
        guard loaded, var info: Any = call(type("UAFAssetSetManager"), "generateInformationWithError:", with: nil) else { return nil }
        if let text = info as? String, let data = text.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) { info = parsed }
        guard let dictionary = info as? [String: Any] else { return nil }
        return parse(dictionary)
    }

    public static func parse(_ info: [String: Any]) -> [String: Int64] {
        var bytes: [String: Int64] = [:]
        for asset in info["SystemAssets"] as? [[String: Any]] ?? [] {
            guard asset["isPresentOnDevice"] as? Bool == true, let meta = asset["metadata"] as? [String: Any],
                  let type = meta["AssetType"] as? String else { continue }
            let size = meta["com.apple.UnifiedAssetFramework.UnarchivedSize"] ?? meta["_UnarchivedSize"]
            bytes[type, default: 0] += Int64("\(size ?? 0)") ?? 0
        }
        return bytes
    }

    /// Bytes on disk for each of Spare's known sets, by set name; nil when the service didn't answer.
    public static func sizes() -> [String: Int64]? {
        guard let inventory = inventory() else { return nil }
        return Dictionary(uniqueKeysWithValues: Debloat.modelSets.map { ($0.name, inventory[$0.assetType] ?? 0) })
    }

    /// Removes these sets, one request each so one the service turns down doesn't stop the rest. Refuses sets Spare
    /// doesn't know, and leaves alone a set whose asset type has changed in this macOS. Returns the sets that stayed,
    /// with why. Slow; call it off the main thread.
    public static func remove(_ sets: [String], timeout: TimeInterval = 120) -> [(set: String, reason: String)] {
        var failed: [(set: String, reason: String)] = []
        for name in sets {
            guard let known = Debloat.modelSet(name) else { failed.append((name, "Spare doesn't know this set.")); continue }
            guard assetType(of: name) == known.assetType else {
                failed.append((known.title, "This version of macOS files it differently, so Spare left it alone."))
                continue
            }
            if let problem = reset(name, timeout: timeout) { failed.append((known.title, problem)) }
        }
        return failed
    }

    /// Asks the asset service to reset one set, which lets go of its downloaded models. nil when it agreed.
    static func reset(_ set: String, timeout: TimeInterval) -> String? {
        guard loaded, let interface = call(type("UAFXPCProxyServiceInterface"), "defaultInterface") as? NSXPCInterface else {
            return "macOS's asset service isn't there."
        }
        // A proxy answers to every selector, so ask the interface whether it has the operation.
        let operation = NSSelectorFromString("operationWithConfig:completion:")
        guard protocol_getMethodDescription(interface.protocol, operation, true, true).name != nil
                || protocol_getMethodDescription(interface.protocol, operation, false, true).name != nil else {
            return "macOS's asset service doesn't take this request."
        }
        let connection = NSXPCConnection(machServiceName: service, options: [])
        connection.remoteObjectInterface = interface
        connection.resume()
        defer { connection.invalidate() }

        let done = DispatchSemaphore(value: 0)
        let answer = Answer()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            answer.set(error as NSError)
            done.signal()
        }
        let service = unsafeBitCast(proxy as AnyObject, to: AssetOperations.self)
        service.operation(withConfig: ["Operation": "ResetAssetSets", "AssetSets": [set]] as NSDictionary) { error in
            answer.set(error)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return "No answer in \(Int(timeout)) seconds." }
        return answer.error.map { "\($0.localizedDescription) (\($0.domain) \($0.code))" }
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var first: NSError??
        func set(_ error: NSError?) { lock.withLock { if first == nil { first = .some(error) } } }
        var error: NSError? { lock.withLock { first ?? nil } }
    }
}

/// The one call Spare makes to the asset service.
@objc private protocol AssetOperations {
    func operation(withConfig configuration: NSDictionary, completion: @escaping (NSError?) -> Void)
}
