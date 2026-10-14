import Foundation

/// Removes privacy decisions. Apps known by bundle identifier go through `tccutil reset`, which looks the app up first
/// and refuses one that's no longer installed, which is exactly what Spare lists, so for those a placeholder app with
/// the same identifier is registered with Launch Services for the moment of the reset, then unregistered and deleted.
/// Programs macOS knows only by their file path (scripts, applets, tools) are something `tccutil` can't name at all;
/// their decision is taken out of macOS's permission database, which Spare may change because it has Full Disk Access.
enum PrivacyTool {
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    struct Decision {
        var service: String
        var client: String
        /// What failures are reported under: "Besiege (Input Monitoring)".
        var label: String
    }

    /// A shell script that removes each decision, run as the person for their own (`database` in their Library) and as
    /// root for the whole Mac's. It prints a line for each decision it couldn't remove and exits with their number.
    static func script(_ decisions: [Decision], database: String) -> String {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.opyuii.spare/Placeholders").path
        var lines = [
            "folder=\(Privileged.quoted(folder)); database=\(Privileged.quoted(database)); failed=0",
            "said() { failed=$((failed + 1)); printf '%s: %s\\n' \"$1\" \"$2\"; }",
            // $1 service, $2 bundle identifier, $3 label.
            "reset() {",
            "  /usr/bin/tccutil reset \"$1\" \"$2\" >/dev/null 2>&1 && return 0",
            "  app=\"$folder/$(printf '%s' \"$2\" | tr '/' '_').app\"; plist=\"$app/Contents/Info.plist\"",
            "  rm -rf \"$app\"; mkdir -p \"$app/Contents/MacOS\" || { said \"$3\" \"Spare couldn't make a stand-in for the app.\"; return; }",
            // plutil takes the identifier as one argument, spaces and all ("unity.Spiderling Games.Besiege").
            "  /usr/bin/plutil -create xml1 \"$plist\" && /usr/bin/plutil -insert CFBundleIdentifier -string \"$2\" \"$plist\" &&",
            "    /usr/bin/plutil -insert CFBundleExecutable -string Placeholder \"$plist\" && /usr/bin/plutil -insert CFBundlePackageType -string APPL \"$plist\"",
            "  cp /usr/bin/true \"$app/Contents/MacOS/Placeholder\" && /usr/bin/codesign -f -s - \"$app\" >/dev/null 2>&1",
            "  \(lsregister) -f -R -trusted \"$app\"",
            // Launch Services takes a moment to answer for a new app.
            "  out=''; for wait in 1 2 3 4 5; do out=$(/usr/bin/tccutil reset \"$1\" \"$2\" 2>&1) && break; out=${out:-tccutil failed}; sleep 1; done",
            "  \(lsregister) -u \"$app\"; rm -rf \"$app\"",
            "  [ -n \"$out\" ] && [ \"$out\" = \"${out#Successfully}\" ] && said \"$3\" \"$(printf '%s' \"$out\" | head -1)\"",
            "  return 0",
            "}",
            // $1 full service name, $2 path, $3 label.
            "forget() {",
            "  out=$(/usr/bin/sqlite3 \"$database\" \"DELETE FROM access WHERE service = '$1' AND client = '$(printf '%s' \"$2\" | sed \"s/'/''/g\")' AND client_type = 1; SELECT changes();\" 2>&1)",
            // No `case` here: bash 3.2, macOS's /bin/sh, can't parse its patterns inside the $( ) the script runs in.
            "  if printf '%s' \"$out\" | grep -Eq '^[0-9]+$'; then return 0; fi",
            "  if printf '%s' \"$out\" | grep -Eqi 'not authorized|unable to open|readonly|permission denied'; then",
            "    said \"$3\" \"macOS didn't let Spare change its permission database. Remove it in System Settings › Privacy & Security: select it and click −.\"",
            "  else said \"$3\" \"$(printf '%s' \"$out\" | head -1)\"; fi",
            "}",
        ]
        for decision in decisions {
            let short = decision.service.replacingOccurrences(of: "kTCCService", with: "")
            // Neither can be a real service or client with a line break or a quote mark in the service.
            guard decision.service.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil,
                  !decision.client.contains(where: \.isNewline) else {
                lines.append("said \(Privileged.quoted(decision.label)) 'Spare can'\\''t read its name.'")
                continue
            }
            if decision.client.hasPrefix("/") {
                lines.append("forget \(Privileged.quoted(decision.service)) \(Privileged.quoted(decision.client)) \(Privileged.quoted(decision.label))")
            } else {
                lines.append("reset \(Privileged.quoted(short)) \(Privileged.quoted(decision.client)) \(Privileged.quoted(decision.label))")
            }
        }
        lines.append("exit $failed")
        return lines.joined(separator: "\n")
    }
}
