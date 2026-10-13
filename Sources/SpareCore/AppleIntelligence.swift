import Foundation
import Darwin
import notify

/// Whether Apple Intelligence runs on this Mac, and why. macOS 27 keeps it switched off while Siri's language differs
/// from the Mac's: it then calls the account not eligible, and the model catalog lets go of the on-device models so
/// macOS can delete them. That is the one switch that frees their space, so it's what Spare uses.
public enum AppleIntelligence {
    /// `unavailable`: a virtual machine, or a Mac that can't run it.
    public enum State: String, Sendable { case on, off, releasing, unavailable, unknown }

    public struct Status: Sendable, Equatable {
        public var state: State
        public var systemLanguage: String?
        public var siriLanguage: String?
        public var siriEnabled: Bool?
        /// nil when eligibility can't be read (no Full Disk Access).
        public var eligible: Bool?
        /// The model catalog still holds the on-device model.
        public var modelsSelected: Bool?
        /// Spare switched it off and kept the Siri settings to restore.
        public var savedBySpare: Bool
        public var isVirtualMachine: Bool
        /// One or two plain sentences for the page.
        public var explanation: String

        public init(state: State, systemLanguage: String?, siriLanguage: String?, siriEnabled: Bool?, eligible: Bool?, modelsSelected: Bool?,
                    savedBySpare: Bool, isVirtualMachine: Bool, explanation: String) {
            self.state = state; self.systemLanguage = systemLanguage; self.siriLanguage = siriLanguage; self.siriEnabled = siriEnabled
            self.eligible = eligible; self.modelsSelected = modelsSelected; self.savedBySpare = savedBySpare
            self.isVirtualMachine = isVirtualMachine; self.explanation = explanation
        }
    }

    /// What macOS answers for an account that may use Apple Intelligence; 2 means it may not.
    static let eligibleAnswer = 4

    public static func status() -> Status {
        let environment = LiveSiriEnvironment()
        let virtual = isVirtualMachine()
        var status = evaluate(systemLanguage: environment.systemLanguage(), siriLanguage: environment.siriLanguage(),
                              siriEnabled: environment.siriEnabled(), eligibilityAnswer: environment.eligibilityAnswer(),
                              modelsSelected: modelsSelected(), savedBySpare: environment.loadSaved() != nil, isVirtualMachine: virtual)
        if !virtual && !isAppleSilicon() {
            status.state = .unavailable
            status.explanation = "Apple Intelligence needs a Mac with Apple silicon, so there's nothing to switch off."
        }
        return status
    }

    public static func evaluate(systemLanguage: String?, siriLanguage: String?, siriEnabled: Bool?, eligibilityAnswer: Int?,
                                modelsSelected: Bool?, savedBySpare: Bool, isVirtualMachine: Bool) -> Status {
        let eligible = eligibilityAnswer.map { $0 == eligibleAnswer }
        var differ: Bool?
        if let systemLanguage, let siriLanguage { differ = baseLanguage(systemLanguage) != baseLanguage(siriLanguage) }
        var state = State.unknown
        var explanation = "Spare couldn't read Siri's language or your Mac's, so it can't tell whether Apple Intelligence is on."
        if isVirtualMachine {
            state = .unavailable
            explanation = "Apple Intelligence never runs in a virtual machine, so there's nothing to switch off."
        } else if eligible == true || (eligible == nil && differ == false) {
            state = .on
            if differ == false, let systemLanguage {
                explanation = "On: Siri and your Mac both use \(languageName(systemLanguage)), so macOS lets Apple Intelligence run and keeps its models on this Mac."
            } else {
                explanation = "On: macOS lets Apple Intelligence run and keeps its models on this Mac."
            }
        } else if eligible == false || differ == true {
            if modelsSelected == true {
                state = .releasing
                explanation = "Off, but macOS is still holding on to the models. Spare can get it to let go by switching Siri's language for a minute and back."
            } else if differ == false {
                // The languages agree, yet macOS says no: the Mac or its region can't have it.
                state = .unavailable
                explanation = "macOS doesn't offer Apple Intelligence on this Mac, so there's nothing to switch off."
            } else {
                state = .off
                if let systemLanguage, let siriLanguage, differ == true {
                    explanation = "Off: Siri speaks \(languageName(siriLanguage)) and your Mac \(languageName(systemLanguage)), so macOS keeps Apple Intelligence switched off."
                } else {
                    explanation = "Off: macOS keeps Apple Intelligence switched off."
                }
                if savedBySpare { explanation += " Turning it on puts your Siri settings back." }
            }
        }
        return Status(state: state, systemLanguage: systemLanguage, siriLanguage: siriLanguage, siriEnabled: siriEnabled, eligible: eligible,
                      modelsSelected: modelsSelected, savedBySpare: savedBySpare, isVirtualMachine: isVirtualMachine, explanation: explanation)
    }

    /// "de" for "de-DE" or "de_DE".
    public static func baseLanguage(_ identifier: String) -> String {
        let normal = normalised(identifier)
        if let code = Locale(identifier: normal).language.languageCode?.identifier, !code.isEmpty { return code.lowercased() }
        return normal.split(separator: "-").first.map { $0.lowercased() } ?? normal.lowercased()
    }

    /// A Siri language whose base differs from the Mac's, which switches Apple Intelligence off: the current one if it
    /// already does, then one whose speech models are already downloaded, then a widely spoken one. nil when Siri
    /// speaks nothing but the Mac's language.
    public static func offLanguage(system: String, current: String?, installed: [String], supported: [String]?) -> String? {
        let base = baseLanguage(system)
        let allowed = supported.map { Set($0.map(normalised)) }
        for candidate in ([current].compactMap { $0 } + installed + ["en-US", "es-ES", "fr-FR", "de-DE", "ja-JP"]).map(normalised)
        where baseLanguage(candidate) != base {
            if let allowed, !allowed.contains(candidate) { continue }
            return candidate
        }
        return nil
    }

    /// "German". Names are in the language of Spare's own text, so a sentence never mixes two languages.
    public static func languageName(_ identifier: String) -> String {
        let base = baseLanguage(identifier)
        return namingLocale.localizedString(forLanguageCode: base) ?? identifier
    }

    static let namingLocale = Locale(identifier: Bundle.main.preferredLocalizations.first { $0 != "Base" } ?? "en")

    /// "English (US)", "German (Germany)": the language with its region, when it has one.
    static func variantName(_ identifier: String) -> String {
        let normal = normalised(identifier)
        let name = languageName(normal)
        guard let region = Locale(identifier: normal).region?.identifier else { return name }
        let short = ["US": "US", "GB": "UK"][region] ?? namingLocale.localizedString(forRegionCode: region) ?? region
        return "\(name) (\(short))"
    }

    static func normalised(_ identifier: String) -> String { identifier.replacingOccurrences(of: "_", with: "-") }

    /// The Siri language closest to the Mac's: the same one if Siri has it, else the same language for the Mac's
    /// region, else the first of that language Siri has.
    static func siriLanguage(matching system: String, supported: [String]?) -> String? {
        let wanted = normalised(system)
        guard let supported = supported?.map(normalised), !supported.isEmpty else { return wanted }
        if supported.contains(wanted) { return wanted }
        let base = baseLanguage(wanted)
        if let region = Locale(identifier: wanted).region?.identifier, supported.contains("\(base)-\(region)") { return "\(base)-\(region)" }
        return supported.first { baseLanguage($0) == base }
    }

    // MARK: - What macOS says

    static let eligibilityFile = "/private/var/db/os_eligibility/eligibility.plist"

    /// macOS's answer for Apple Intelligence's language rule, from its eligibility file.
    public static func eligibilityAnswer(in plist: [String: Any]) -> Int? {
        switch plist["OS_ELIGIBILITY_DOMAIN_SIRI_MODE"] {
        case let domain as [String: Any]: (domain["os_eligibility_answer_t"] as? NSNumber)?.intValue
        case let answer as NSNumber: answer.intValue
        default: nil
        }
    }

    /// The model catalog's choice of models, a set configuration in macOS's asset store. Missing when it chose none.
    static let modelCatalogState = URL(fileURLWithPath: "/System/Library/AssetsV2/persisted/AutoSetConfigurations/AutoSetConfigurations_Entry_com.apple.UnifiedAssetFramework_com.apple.modelcatalog.state")

    /// Apple Intelligence's main on-device language model; while the catalog lists it, macOS keeps the models.
    static let languageModel = "com.apple.fm.language.instruct_3b"

    static func modelsSelected(stateFile: URL = modelCatalogState) -> Bool? {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return false }
        guard let data = FileManager.default.contents(atPath: stateFile.path) else { return nil }
        return modelsSelected(in: data)
    }

    /// Whether a model catalog state file still selects the on-device language model. The selection is an archived
    /// object inside the file; the model's name appears among its strings. nil when the file can't be understood.
    public static func modelsSelected(in data: Data) -> Bool? {
        guard let outer = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        guard let fields = outer["SUCorePersistedStatePolicySecureCodedObjectsFields"] as? [String: Any],
              let archive = fields["setConfiguration"] as? Data else { return false }
        guard let inner = (try? PropertyListSerialization.propertyList(from: archive, format: nil)) as? [String: Any],
              let objects = inner["$objects"] as? [Any] else { return nil }
        return objects.contains { ($0 as? String)?.hasPrefix(languageModel) == true }
    }

    static func isVirtualMachine() -> Bool { sysctl("kern.hv_vmm_present") == 1 }

    static func isAppleSilicon() -> Bool { sysctl("hw.optional.arm64") == 1 }

    private static func sysctl(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

/// Siri's language and voice as they were before Spare changed them, to put back.
public struct SavedSiri: Codable, Equatable, Sendable {
    public var siriLanguage: String
    /// Siri's voice setting as a binary property list, restored as it was.
    public var outputVoice: Data?
    public var savedAt: Date

    public init(siriLanguage: String, outputVoice: Data?, savedAt: Date) {
        self.siriLanguage = siriLanguage; self.outputVoice = outputVoice; self.savedAt = savedAt
    }
}

/// Everything the switch reads or writes, so checks can use a fake.
public protocol SiriEnvironment {
    func systemLanguage() -> String?
    func siriLanguage() -> String?
    func siriEnabled() -> Bool?
    func outputVoice() -> Data?
    func supportedLanguages() -> [String]?
    /// Languages whose Siri speech models are downloaded, from subscriptions such as "assistant.de_DE".
    func installedSiriLanguages() -> [String]
    func eligibilityAnswer() -> Int?
    /// Sets Siri's language, and its voice when given; nil leaves the voice as it is.
    func write(siriLanguage: String, outputVoice: Data?) throws
    func loadSaved() -> SavedSiri?
    /// nil forgets the saved settings.
    func save(_ saved: SavedSiri?) throws
    func sleep(_ seconds: Double)
    /// Apple Intelligence never becomes available in a virtual machine, so the switch leaves Siri alone there.
    func isVirtualMachine() -> Bool
}

extension SiriEnvironment {
    public func isVirtualMachine() -> Bool { AppleIntelligence.isVirtualMachine() }
}

/// The real Siri settings, in the preferences Siri's own settings write.
public struct LiveSiriEnvironment: SiriEnvironment {
    /// Where Spare keeps the Siri settings it changed.
    public var savedFile: URL

    public init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        savedFile = support.appendingPathComponent("Spare/Siri.json")
    }

    static let siriDomain = "com.apple.assistant.backedup" as CFString
    static let assistantServices = "/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices"

    public func systemLanguage() -> String? {
        (CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication) as? [String])?.first
    }

    public func siriLanguage() -> String? {
        CFPreferencesCopyAppValue("Session Language" as CFString, Self.siriDomain) as? String
    }

    public func siriEnabled() -> Bool? {
        (CFPreferencesCopyAppValue("Assistant Enabled" as CFString, "com.apple.assistant.support" as CFString) as? NSNumber)?.boolValue
    }

    public func outputVoice() -> Data? {
        guard let voice = CFPreferencesCopyAppValue("Output Voice" as CFString, Self.siriDomain) else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: voice, format: .binary, options: 0)
    }

    public func supportedLanguages() -> [String]? {
        typealias Supported = @convention(c) () -> Unmanaged<CFArray>?
        guard let handle = dlopen(Self.assistantServices, RTLD_LAZY), let symbol = dlsym(handle, "AFPreferencesSupportedLanguages") else { return nil }
        return unsafeBitCast(symbol, to: Supported.self)()?.takeUnretainedValue() as? [String]
    }

    public func installedSiriLanguages() -> [String] {
        AssetSubscriptions.live().map { AssetSubscriptions.siriLanguages(in: $0) } ?? []
    }

    /// Readable only with Full Disk Access.
    public func eligibilityAnswer() -> Int? {
        guard let data = FileManager.default.contents(atPath: AppleIntelligence.eligibilityFile),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return AppleIntelligence.eligibilityAnswer(in: plist)
    }

    struct WriteFailed: Error {}

    public func write(siriLanguage: String, outputVoice: Data?) throws {
        CFPreferencesSetAppValue("Session Language" as CFString, siriLanguage as CFString, Self.siriDomain)
        if let outputVoice {
            guard let voice = try? PropertyListSerialization.propertyList(from: outputVoice, format: nil) else { throw WriteFailed() }
            CFPreferencesSetAppValue("Output Voice" as CFString, voice as AnyObject as CFPropertyList, Self.siriDomain)
        }
        guard CFPreferencesAppSynchronize(Self.siriDomain),
              CFPreferencesCopyAppValue("Session Language" as CFString, Self.siriDomain) as? String == siriLanguage else { throw WriteFailed() }
        // Siri's services reload their language when told; without this they'd keep the old one until next login.
        notify_post(Self.languageChanged)
    }

    /// The name Siri's services listen for, as AssistantServices exports it.
    static let languageChanged: String = {
        if let handle = dlopen(assistantServices, RTLD_LAZY), let symbol = dlsym(handle, "AFLanguageCodeDidChangeDarwinNotification"),
           let name = symbol.assumingMemoryBound(to: Unmanaged<CFString>?.self).pointee {
            return name.takeUnretainedValue() as String
        }
        return "AFLanguageCodeDidChangeDarwinNotification"
    }()

    public func loadSaved() -> SavedSiri? {
        guard let data = try? Data(contentsOf: savedFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SavedSiri.self, from: data)
    }

    public func save(_ saved: SavedSiri?) throws {
        guard let saved else {
            if FileManager.default.fileExists(atPath: savedFile.path) { try FileManager.default.removeItem(at: savedFile) }
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: savedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(saved).write(to: savedFile, options: .atomic)
    }

    public func sleep(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}

/// Switches Apple Intelligence off and on through Siri's language, and gets macOS to let go of models it still holds.
/// Siri's language syncs through iCloud, so the person's iPhone and iPad follow each change.
public enum AppleIntelligenceSwitch {
    public struct Outcome: Sendable, Equatable {
        public var done: Bool
        /// Plain English, nil when it worked.
        public var error: String?
        /// Siri's language afterwards.
        public var siriLanguage: String?
        public var purge: CacheDelete.PurgeResult?

        public init(done: Bool, error: String? = nil, siriLanguage: String? = nil, purge: CacheDelete.PurgeResult? = nil) {
            self.done = done; self.error = error; self.siriLanguage = siriLanguage; self.purge = purge
        }
    }

    /// Off: Siri to a language whose base differs, saving the settings first; rolls back if macOS still reports it
    /// eligible. Then, after ~15 s, `purge()`.
    public static func turnOff(_ env: SiriEnvironment, purge: () -> CacheDelete.PurgeResult, step: (String) -> Void) -> Outcome {
        guard !env.isVirtualMachine() else { return Outcome(done: false, error: inVirtualMachine, siriLanguage: env.siriLanguage()) }
        guard let system = env.systemLanguage() else {
            return Outcome(done: false, error: "Spare couldn't read your Mac's language, so it changed nothing.")
        }
        let current = env.siriLanguage()
        guard let target = AppleIntelligence.offLanguage(system: system, current: current, installed: env.installedSiriLanguages(),
                                                         supported: env.supportedLanguages()) else {
            return Outcome(done: false, error: "Siri speaks no language other than \(AppleIntelligence.languageName(system)), so Spare can't switch Apple Intelligence off.",
                           siriLanguage: current)
        }
        let changed = target != current.map(AppleIntelligence.normalised)
        var saved: SavedSiri?
        if changed {
            step("Saving your Siri settings…")
            let original = SavedSiri(siriLanguage: current ?? system, outputVoice: env.outputVoice(), savedAt: Date())
            do { try env.save(original) } catch {
                return Outcome(done: false, error: "Spare couldn't save your Siri settings, so it changed nothing.", siriLanguage: current)
            }
            saved = original
            step("Switching Siri to \(AppleIntelligence.variantName(target))…")
            do { try env.write(siriLanguage: target, outputVoice: nil) } catch {
                let restored = restore(original, env, step)
                return Outcome(done: false, error: "macOS didn't accept the new Siri language. " + (restored ? "Siri is as it was." : advice(original)),
                               siriLanguage: env.siriLanguage())
            }
        }
        step("Checking that macOS switched Apple Intelligence off…")
        let off = changed ? wait(env, eligible: false, seconds: 8) : env.eligibilityAnswer().map { $0 != AppleIntelligence.eligibleAnswer }
        if off == false {
            guard let saved else {
                return Outcome(done: false, error: "macOS lets Apple Intelligence run even with Siri in \(AppleIntelligence.variantName(target)), so Spare can't switch it off.",
                               siriLanguage: current)
            }
            let restored = restore(saved, env, step)
            return Outcome(done: false, error: "macOS still lets Apple Intelligence run with Siri in \(AppleIntelligence.variantName(target)). "
                           + (restored ? "Spare put Siri back as it was." : advice(saved)), siriLanguage: env.siriLanguage())
        }
        if changed {
            step("Waiting for macOS to let go of the models…")
            env.sleep(15)
        }
        step("Asking macOS to delete them…")
        return Outcome(done: true, siriLanguage: target, purge: purge())
    }

    /// On: restores the saved Siri language and voice. macOS may download the models again.
    public static func turnOn(_ env: SiriEnvironment) -> Outcome {
        if let saved = env.loadSaved() {
            do { try env.write(siriLanguage: saved.siriLanguage, outputVoice: saved.outputVoice) } catch {
                return Outcome(done: false, error: "macOS didn't accept the change. " + advice(saved), siriLanguage: env.siriLanguage())
            }
            try? env.save(nil)
            return Outcome(done: true, siriLanguage: saved.siriLanguage)
        }
        // Switched off some other way: Siri follows the Mac's language again.
        guard let system = env.systemLanguage(), let language = AppleIntelligence.siriLanguage(matching: system, supported: env.supportedLanguages()) else {
            return Outcome(done: false, error: "Siri doesn't speak your Mac's language, so Spare can't switch Apple Intelligence on.")
        }
        do { try env.write(siriLanguage: language, outputVoice: nil) } catch {
            return Outcome(done: false, error: "macOS didn't accept the change. Set Siri to \(AppleIntelligence.variantName(language)) in System Settings › Apple Intelligence & Siri.",
                           siriLanguage: env.siriLanguage())
        }
        return Outcome(done: true, siriLanguage: language)
    }

    /// For the releasing state: the available→unavailable round trip, then `purge()`. Restores the original Siri
    /// language on every path.
    ///
    /// The model catalog lets go of the models only when Apple Intelligence goes from available to unavailable, so
    /// Siri briefly follows the Mac's language, long enough for the catalog to take the models, and then goes back.
    public static func release(_ env: SiriEnvironment, purge: () -> CacheDelete.PurgeResult, step: (String) -> Void) -> Outcome {
        guard !env.isVirtualMachine() else { return Outcome(done: false, error: inVirtualMachine, siriLanguage: env.siriLanguage()) }
        guard let system = env.systemLanguage(), let original = env.siriLanguage() else {
            return Outcome(done: false, error: "Spare couldn't read Siri's language or your Mac's, so it changed nothing.")
        }
        guard AppleIntelligence.baseLanguage(original) != AppleIntelligence.baseLanguage(system) else {
            return Outcome(done: false, error: "Apple Intelligence is on, so macOS keeps its models. Switch it off first.", siriLanguage: original)
        }
        guard let available = AppleIntelligence.siriLanguage(matching: system, supported: env.supportedLanguages()) else {
            return Outcome(done: false, error: "Siri doesn't speak your Mac's language, so macOS can't make Apple Intelligence available for a moment.",
                           siriLanguage: original)
        }
        let back = SavedSiri(siriLanguage: original, outputVoice: env.outputVoice(), savedAt: Date())
        func putBack() -> Bool {
            step("Switching Siri back to \(AppleIntelligence.variantName(original))…")
            return (try? env.write(siriLanguage: back.siriLanguage, outputVoice: back.outputVoice)) != nil
        }
        func failed(_ problem: String) -> Outcome {
            let restored = putBack()
            return Outcome(done: false, error: problem + " " + (restored ? "Siri is back as it was." : advice(back)), siriLanguage: env.siriLanguage())
        }

        step("Switching Siri to \(AppleIntelligence.variantName(available)) for a moment…")
        guard (try? env.write(siriLanguage: available, outputVoice: nil)) != nil else { return failed("macOS didn't accept the change.") }
        step("Waiting for macOS to make Apple Intelligence available…")
        if wait(env, eligible: true, seconds: 30) == false {
            return failed("macOS didn't make Apple Intelligence available, so it can't let go of the models.")
        }
        step("Waiting for macOS to take the models…")
        env.sleep(20)
        guard putBack() else {
            return Outcome(done: false, error: "Spare couldn't switch Siri back. " + advice(back), siriLanguage: env.siriLanguage())
        }
        step("Waiting for macOS to let go of the models…")
        if wait(env, eligible: false, seconds: 30) == false {
            return Outcome(done: false, error: "macOS still lets Apple Intelligence run with Siri back in \(AppleIntelligence.variantName(original)).",
                           siriLanguage: env.siriLanguage())
        }
        env.sleep(15)
        step("Asking macOS to delete them…")
        return Outcome(done: true, siriLanguage: original, purge: purge())
    }

    /// Asks macOS once a second, for at most `seconds`, until Apple Intelligence is `eligible` or not. Without Full
    /// Disk Access the answer can't be read: it then waits the whole time, usually long enough, and returns nil.
    static func wait(_ env: SiriEnvironment, eligible wanted: Bool, seconds: Double) -> Bool? {
        var waited = 0.0
        while true {
            guard let answer = env.eligibilityAnswer() else {
                if waited < seconds { env.sleep(seconds - waited) }
                return nil
            }
            if (answer == AppleIntelligence.eligibleAnswer) == wanted { return true }
            if waited >= seconds { return false }
            env.sleep(1)
            waited += 1
        }
    }

    /// Puts Siri's language and voice back as saved, and forgets the saved copy once that worked.
    static func restore(_ saved: SavedSiri, _ env: SiriEnvironment, _ step: (String) -> Void) -> Bool {
        step("Putting Siri back to \(AppleIntelligence.variantName(saved.siriLanguage))…")
        guard (try? env.write(siriLanguage: saved.siriLanguage, outputVoice: saved.outputVoice)) != nil else { return false }
        try? env.save(nil)
        return true
    }

    static let inVirtualMachine = "Apple Intelligence never runs in a virtual machine, so Spare left Siri as it is."

    static func advice(_ saved: SavedSiri) -> String {
        "Set Siri to \(AppleIntelligence.variantName(saved.siriLanguage)) in System Settings › Apple Intelligence & Siri."
    }
}
