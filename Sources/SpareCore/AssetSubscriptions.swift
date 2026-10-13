import Foundation
import SQLite3

/// Why macOS keeps a download. A downloaded asset stays while any subscription names it: Siri subscribes to speech
/// models for its languages, Dictionary to its dictionaries, the model catalog to parts of Apple Intelligence. The list
/// sits in a database every account may read when it's opened read-only; Spare never changes it.
public enum AssetSubscriptions {
    public static let database = "/private/var/db/assetsubscriptiond/UAFAssetSubscriptions.db"

    public struct Subscription: Sendable, Hashable {
        /// Who asked for it, such as "com.apple.siri.embeddedspeech".
        public var client: String
        /// What it asked for, such as "assistant.de_DE".
        public var name: String
        public init(client: String, name: String) { self.client = client; self.name = name }
    }

    /// Every subscription of every account on this Mac, since any of them keeps an asset. nil when the database
    /// can't be read.
    public static func live(database: String = database) -> [Subscription]? {
        // immutable=1 reads the file as it is, without the lock and journal files a live database needs write access for.
        let path = database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2("file:\(path)?immutable=1", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT DISTINCT k0, k1 FROM Subscriptions ORDER BY k0, k1", -1, &statement, nil) == SQLITE_OK else { return nil }
        var found: [Subscription] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let client = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { continue }
            found.append(Subscription(client: String(cString: client), name: String(cString: name)))
        }
        return found
    }

    /// Plain-English holder for an asset family, e.g. "Kept for Siri in German and English, even with Siri off." nil when
    /// nothing found.
    public static func holder(of feature: SystemAsset.Feature, in subscriptions: [Subscription], siriLanguage: String?, systemLanguage: String?) -> String? {
        let first = [siriLanguage, systemLanguage]
        switch feature {
        case .siriSpeech:
            // "assistant" is Siri's speech recognition, "hammer" the model behind it.
            let codes = subscriptions.compactMap { language(in: $0.name, after: "assistant.") ?? language(in: $0.name, after: "hammer.") }
            return codes.isEmpty ? nil : "Kept for Siri in \(names(codes, first: first)), even with Siri off."
        case .voices:
            let codes = subscriptions.compactMap { language(in: $0.name, after: "siri.tts.voice.") ?? language(in: $0.name, after: "siri.tts.resource.") }
            return codes.isEmpty ? nil : "Kept for Siri's voices in \(names(codes, first: first))."
        case .languageData:
            let codes = subscriptions.compactMap { language(in: $0.name, after: "LinguisticData.") }
            return codes.isEmpty ? nil : "Kept for spelling and typing suggestions in \(names(codes, first: first))."
        case .dictionaries:
            // "com.apple.DictionaryServices;en_US;com.apple.dictionary.NOAD.DataDeliveryService_0": one dictionary per third part.
            let dictionaries = Set(subscriptions.compactMap { subscription -> String? in
                let parts = subscription.name.split(separator: ";")
                guard parts.count >= 3, parts[0] == "com.apple.DictionaryServices" else { return nil }
                return parts[2].components(separatedBy: ".DataDeliveryService").first
            })
            if dictionaries.isEmpty { return nil }
            return dictionaries.count == 1 ? "Kept for a dictionary in the Dictionary app." : "Kept for \(dictionaries.count) dictionaries in the Dictionary app."
        case .photos:
            return subscriptions.contains { $0.name.lowercased().contains("photos") } ? "Kept for Photos." : nil
        case .appleIntelligence:
            var uses: [String] = []
            if subscriptions.contains(where: { $0.name.hasPrefix("handwriting.") }) { uses.append("handwriting") }
            if subscriptions.contains(where: { $0.client.hasSuffix(".summarizationkit") }) { uses.append("summaries") }
            if subscriptions.contains(where: { $0.client == "model-catalog" && $0.name.hasPrefix("safety.") }) { uses.append("safety checks") }
            return uses.isEmpty ? nil : "Kept for Apple Intelligence's \(joined(uses))."
        case .updates, .metal, .fonts, .other:
            return nil
        }
    }

    /// Languages Siri has speech models for, from subscriptions such as "assistant.de_DE", as "de-DE".
    public static func siriLanguages(in subscriptions: [Subscription]) -> [String] {
        Array(Set(subscriptions.compactMap { language(in: $0.name, after: "assistant.") })).sorted()
    }

    /// The locale right after `prefix` in a subscription's name, as "de-DE", or "de" for a language without a region.
    static func language(in name: String, after prefix: String) -> String? {
        guard let range = name.range(of: prefix) else { return nil }
        let code = name[range.upperBound...].prefix { $0 != "." && $0 != ";" }
        guard let first = code.first, first.isLetter, code.allSatisfy({ $0.isLetter || $0 == "_" || $0 == "-" }) else { return nil }
        // "mul_Latn" covers many languages written in one script; it names none of them.
        guard !code.hasPrefix("mul"), !code.hasPrefix("und") else { return nil }
        return code.replacingOccurrences(of: "_", with: "-")
    }

    /// "German and English": each language once, the ones in `first` leading.
    static func names(_ codes: [String], first: [String?]) -> String {
        let bases = codes.map(AppleIntelligence.baseLanguage)
        let rest = Set(bases).sorted { AppleIntelligence.languageName($0) < AppleIntelligence.languageName($1) }
        var ordered: [String] = []
        for base in first.compactMap({ $0.map(AppleIntelligence.baseLanguage) }) + rest where bases.contains(base) && !ordered.contains(base) {
            ordered.append(base)
        }
        return joined(ordered.map(AppleIntelligence.languageName))
    }

    /// "a", "a and b", "a, b and c".
    static func joined(_ words: [String]) -> String {
        guard words.count > 1, let last = words.last else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + last
    }
}
