import Foundation

/// Removes privacy decisions with `tccutil reset`. It looks the app up first and refuses one that's no longer
/// installed, which is exactly what Spare lists, so for those a placeholder app with the same identifier is
/// registered with Launch Services for the moment of the reset, then unregistered and deleted.
enum PrivacyTool {
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// A shell script that removes each decision, run as the person for their own and as root for the whole Mac's.
    /// It exits with the number of decisions it couldn't remove.
    static func script(_ decisions: [(service: String, client: String)]) -> String {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.opyuii.spare/Placeholders").path
        // Bundle identifiers only; anything else can't be one and stays out of the script.
        let valid = decisions.filter { $0.client.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil }
        var lines = [
            "folder=\(Privileged.quoted(folder)); failed=\(decisions.count - valid.count)",
            "reset() {",
            "  /usr/bin/tccutil reset \"$1\" \"$2\" >/dev/null 2>&1 && return 0",
            "  app=\"$folder/$2.app\"; mkdir -p \"$app/Contents/MacOS\" || return 1",
            "  /usr/libexec/PlistBuddy -c \"Add :CFBundleIdentifier string $2\" -c 'Add :CFBundleExecutable string Placeholder' -c 'Add :CFBundlePackageType string APPL' \"$app/Contents/Info.plist\" >/dev/null 2>&1",
            "  cp /usr/bin/true \"$app/Contents/MacOS/Placeholder\" && /usr/bin/codesign -f -s - \"$app\" >/dev/null 2>&1",
            "  \(lsregister) -f -R -trusted \"$app\"",
            // Launch Services takes a moment to answer for a new app.
            "  status=1; for wait in 1 2 3 4 5; do /usr/bin/tccutil reset \"$1\" \"$2\" >/dev/null 2>&1 && { status=0; break; }; sleep 1; done",
            "  \(lsregister) -u \"$app\"; rm -rf \"$app\"",
            "  return $status",
            "}",
        ]
        lines += valid.map { "reset \(Privileged.quoted($0.service.replacingOccurrences(of: "kTCCService", with: ""))) \(Privileged.quoted($0.client)) || failed=$((failed + 1))" }
        lines.append("exit $failed")
        return lines.joined(separator: "\n")
    }
}
