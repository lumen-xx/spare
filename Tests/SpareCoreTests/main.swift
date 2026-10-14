import Foundation
import Security
import SQLite3
import SpareCore

// Self-contained checks for Spare's scanning logic, run with `swift run SpareChecks`. Everything happens inside a
// temporary folder; nothing is moved to the Trash.

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() { print("PASS  \(message)") } else { failures += 1; print("FAIL  \(message) (line \(line))") }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("spare-checks-\(UUID().uuidString)").resolvingSymlinksInPath()
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

@discardableResult
func write(_ relative: String, bytes: Int = 10_000) -> URL {
    let url = root.appendingPathComponent(relative)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Random bytes, so APFS can't compress them and sizes stay predictable.
    var data = Data(count: bytes)
    if bytes > 0 { _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) } }
    try? data.write(to: url)
    return url
}
@discardableResult
func folder(_ relative: String) -> URL {
    let url = root.appendingPathComponent(relative)
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func blocks(_ path: String) -> Int64 {
    var stats = stat()
    return lstat(path, &stats) == 0 ? Int64(stats.st_blocks) * 512 : 0
}
func allocated(_ url: URL) -> Int64 {
    var total = blocks(url.path)
    for case let path as String in fm.enumerator(atPath: url.path)! { total += blocks(url.appendingPathComponent(path).path) }
    return total
}

// MARK: Sizes

let sized = folder("sized")
write("sized/a.bin", bytes: 100_000)
write("sized/inner/b.bin", bytes: 50_000)
write("sized/inner/deeper/c.bin", bytes: 20_000)
var reported: [String: Int64] = [:]
let usage = DiskUsage.measure(sized, threshold: 0) { reported[$0] = $1 }
check(usage.bytes == allocated(sized), "size matches the allocated blocks of every file and folder")
check(usage.files == 3, "counts files")
check(reported[sized.appendingPathComponent("inner").path] == allocated(sized.appendingPathComponent("inner")), "reports inner folder totals")
check(reported[sized.path] == usage.bytes, "the top folder's total equals the whole size")

// Hard links: one inside twice counts once; one also linked from outside is shared.
let linked = folder("linked")
let twice = write("linked/twice.bin", bytes: 40_000)
try fm.linkItem(at: twice, to: linked.appendingPathComponent("twice-again.bin"))
let outside = write("store/shared.bin", bytes: 30_000)
try fm.linkItem(at: outside, to: linked.appendingPathComponent("shared.bin"))
let linkUsage = DiskUsage.measure(linked)
check(linkUsage.shared == blocks(outside.path), "a file linked from outside counts as shared")
check(linkUsage.bytes == allocated(linked) - blocks(twice.path) - blocks(outside.path),
      "a file linked twice inside counts once, and shared files don't count as freed")

// Skipped and unreadable folders.
let guarded = folder("guarded")
write("guarded/open/x.bin", bytes: 10_000)
write("guarded/secret/y.bin", bytes: 60_000)
let skipped = DiskUsage.measure(guarded, skip: [guarded.appendingPathComponent("secret").path])
check(skipped.unreadable == 1 && skipped.files == 1, "skips folders it was asked not to enter")
let locked = guarded.appendingPathComponent("secret")
chmod(locked.path, 0)
var lockedTotals: [String: Int64] = [:]
let unreadable = DiskUsage.measure(guarded, threshold: 0) { lockedTotals[$0] = $1 }
chmod(locked.path, 0o755)
check(unreadable.unreadable == 1 && unreadable.files == 1, "counts a folder it can't read and carries on")
check(lockedTotals[guarded.path] == unreadable.bytes, "folder totals stay right around an unreadable folder")

let single = DiskUsage.measure(write("lonely.bin", bytes: 12_345))
check(single.files == 1 && single.bytes >= 12_345, "measures a single file")

let cancelled = Cancellation(); cancelled.cancel()
check(Catalog.measure([sized], cancel: cancelled) == [Usage()], "a cancelled scan measures nothing")

// MARK: Projects

write("code/web/package.json", bytes: 10)
write("code/web/node_modules/left-pad/index.js", bytes: 2_000)
write("code/web/node_modules/left-pad/node_modules/x/package.json", bytes: 10)
write("code/notes/build/keep.txt", bytes: 10)
write("code/android/build.gradle", bytes: 10)
write("code/android/build/out.bin", bytes: 10)
write("code/group/apps/site/package.json", bytes: 10)
write("code/group/apps/site/.next/cache.bin", bytes: 10)
write("code/.hidden/package.json", bytes: 10)
write("code/.hidden/node_modules/a.js", bytes: 10)
let artifacts = Projects.artifacts(in: [root.appendingPathComponent("code")], cancel: Cancellation())
let names = Set(artifacts.map { $0.project.lastPathComponent + "/" + $0.folder.lastPathComponent })
check(names == ["web/node_modules", "android/build", "site/.next"], "finds build folders only beside their project file (\(names.sorted()))")

// MARK: Apps and leftovers

check(Apps.identifier(in: "com.vendor.app.plist") == "com.vendor.app", "reads an identifier from a settings file")
check(Apps.identifier(in: "com.apple.Safari") == nil, "never treats Apple's files as leftovers")
check(Apps.identifier(in: "Google") == nil && Apps.identifier(in: "group.com.vendor.app") == nil, "ignores names and group containers")

let home = folder("home")
write("home/Library/Preferences/com.gone.app.plist", bytes: 500)
write("home/Library/Caches/com.gone.app/data.bin", bytes: 5_000)
write("home/Library/Caches/com.gone.app.helper/data.bin", bytes: 5_000)
write("home/Library/Application Support/com.kept.app/db.bin", bytes: 5_000)
write("home/Library/Caches/com.kept.app.ShipIt/update.bin", bytes: 5_000)
write("home/Library/Application Support/Kept/notes.bin", bytes: 5_000)
write("home/Library/Application Support/Keptic/other.bin", bytes: 5_000)
write("home/Library/Preferences/com.apple.finder.plist", bytes: 500)
let orphans = Apps.orphans(home: home, fullDiskAccess: false, cancel: Cancellation()) { $0 == "com.kept.app" }
check(orphans.map(\.bundleID) == ["com.gone.app"], "lists leftovers only for identifiers nothing uses (\(orphans.map(\.bundleID)))")
check(orphans.first?.leftovers.count == 3, "files a helper's leftovers with its app")
write("home/Library/Caches/org.swift.swiftpm/manifests.bin", bytes: 500)
write("home/Library/Preferences/com.vendor.removed.plist", bytes: 500)
let quieter = Apps.orphans(home: home, fullDiskAccess: false, cancel: Cancellation(), companyInUse: { $0 == "com.vendor" }) { $0 == "com.kept.app" }
check(quieter.map(\.bundleID) == ["com.gone.app"], "leaves out tool caches and fresh files of companies still installed (\(quieter.map(\.bundleID)))")
let later = Apps.orphans(home: home, fullDiskAccess: false, cancel: Cancellation(), now: Date().addingTimeInterval(60 * 86_400),
                         companyInUse: { $0 == "com.vendor" }) { $0 == "com.kept.app" }
check(Set(later.map(\.bundleID)) == ["com.gone.app", "com.vendor.removed"], "lists a company's files once they've been untouched for a month")

let contents = folder("Apps/Kept.app/Contents")
try (["CFBundleIdentifier": "com.kept.app", "CFBundleName": "Kept", "CFBundleExecutable": "Kept", "CFBundlePackageType": "APPL"] as NSDictionary)
    .write(to: contents.appendingPathComponent("Info.plist"))
let kept = InstalledApp(url: root.appendingPathComponent("Apps/Kept.app"), bundleID: "com.kept.app", name: "Kept", version: nil,
                        isApple: false, fromAppStore: false)
let leftovers = Apps.leftovers(for: kept, home: home, fullDiskAccess: false, cancel: Cancellation())
let found = Set(leftovers.map { $0.url.path.replacingOccurrences(of: home.path + "/Library/", with: "") })
check(found == ["Application Support/com.kept.app", "Caches/com.kept.app.ShipIt", "Application Support/Kept"],
      "finds an app's files by identifier and exact name only (\(found.sorted()))")

check(Apps.company(of: "com.adobe.Photoshop") == "com.adobe", "reads the company part of an identifier")
check(Apps.company(of: "com.github.facebook.watchman") == nil && Apps.company(of: "io.github.someone.tool") == nil,
      "never treats a code host as a company")

// MARK: Background items

let plist = root.appendingPathComponent("agent.plist")
try (["Label": "com.vendor.agent", "ProgramArguments": ["/nonexistent/Vendor.app/Contents/MacOS/agent", "--quiet"],
      "StartInterval": 3600, "RunAtLoad": true] as NSDictionary).write(to: plist)
let agent = LaunchItem(plist: plist, scope: .user)
check(agent?.schedule == "Every hour", "describes an hourly job")
check(agent?.programExists == false, "notices a job whose program is gone")
check(agent?.programApp?.lastPathComponent == "Vendor.app", "finds the app a program lives in")
try (["Label": "homebrew.mxcl.redis", "Program": "/bin/sh", "KeepAlive": ["SuccessfulExit": false]] as NSDictionary).write(to: plist)
let service = LaunchItem(plist: plist, scope: .user)
check(service?.schedule == "Always running" && service?.note?.contains("brew services") == true, "explains a Homebrew service")
let printed = """
    gui/501 = {
    \tservices = {
    \t\t   4242      - \tapplication.com.example.screenshots.1000.1001
    \t\t       0      0 \tcom.vendor.agent
    \t}
    }
    """
let services = Launchd.parse(printed)
check(services["com.vendor.agent"] == Launchd.Status(loaded: true, pid: nil), "reads a loaded job that isn't running")
check(services["application.com.example.screenshots.1000.1001"]?.pid == 4242, "reads a running job's process")

let disabledJobs = Launchd.parseDisabled("\tdisabled services = {\n\t\t\"com.docker.helper\" => enabled\n\t\t\"homebrew.mxcl.redis\" => disabled\n\t\t\"old.style\" => true\n\t}\n")
check(disabledJobs == ["com.docker.helper": false, "homebrew.mxcl.redis": true, "old.style": true], "reads which jobs are turned off")

// MARK: History

let history = TrashHistory(file: root.appendingPathComponent("History.json"))
let session = TrashSession(title: "Cleanup", records: [TrashRecord(original: "/a", trashed: "/b", bytes: 5)], bytes: 5)
history.save([session])
check(history.load().first?.records.first?.trashed == "/b", "keeps the history of moved items")
let movedAway = write("restore/item.bin", bytes: 100)
let parked = root.appendingPathComponent("parked.bin")
try fm.moveItem(at: movedAway, to: parked)
try fm.removeItem(at: root.appendingPathComponent("restore"))
try Trash.putBack(TrashRecord(original: movedAway.path, trashed: parked.path, bytes: 100))
check(fm.fileExists(atPath: movedAway.path), "puts an item back, recreating its folder")
write("taken/item.bin", bytes: 1)
let taken = (try? Trash.putBack(TrashRecord(original: root.appendingPathComponent("taken/item.bin").path, trashed: movedAway.path, bytes: 1))) == nil
check(taken && fm.fileExists(atPath: movedAway.path), "never replaces something new when putting back")

// MARK: Open files

let busy = folder("busy")
let writer = Process()
writer.executableURL = URL(fileURLWithPath: "/bin/sh")
writer.arguments = ["-c", "exec 3>\"$0/log.txt\"; sleep 10", busy.path]
try writer.run()
var open: [String: String] = [:]
for _ in 0..<40 where OpenFiles.user(of: busy, in: open) == nil { usleep(50_000); open = OpenFiles.snapshot() }
check(OpenFiles.user(of: busy, in: open) != nil, "sees a file another program has open inside a folder (\(OpenFiles.user(of: busy, in: open) ?? "none"))")
check(OpenFiles.user(of: sized, in: open) == nil, "doesn't flag folders nothing has open")
let marked = OpenFiles.mark([Item(urls: [busy], label: "busy", suggested: true), Item(urls: [sized], label: "idle", suggested: true)], with: open)
check(marked[0].inUseBy != nil && !marked[0].suggested && marked[1].inUseBy == nil && marked[1].suggested,
      "an item in use is never suggested; others stay as they were")
writer.terminate()
writer.waitUntilExit()

check(Catalog.isSystemService("familycircled") && Catalog.isSystemService("akd"), "recognises macOS service caches")
check(!Catalog.isSystemService("Zed") && !Catalog.isSystemService("bun") && !Catalog.isSystemService("com.vendor.app"), "doesn't mistake app caches for macOS's")

// MARK: Login items, packages, extensions, snapshots

let btm = """
    ========================
     Records for UID 501 : 00000001
    ========================

     #1:
                     UUID: 00000002
                     Name: postgres
           Developer Name: (null)
                     Type: legacy agent (0x10008)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.homebrew.mxcl.postgresql@17
                      URL: /Users/501/Library/LaunchAgents/homebrew.mxcl.postgresql@17.plist

     #2:
                     UUID: 00000003
                     Name: Notch
           Developer Name: Example Developer
                     Type: app (0x2)
              Disposition: [disabled, allowed, not notified] (0x2)
               Identifier: 2.com.example.Notch
                      URL: /Applications/Notch.app
        Bundle Identifier: com.example.Notch
    ========================
     Records for UID 502 : 00000004
    ========================

     #1:
                     UUID: OTHER
                     Name: Someone else's
                     Type: app (0x2)
              Disposition: [enabled, allowed] (0x3)
               Identifier: 2.other
    """
let records = LoginItems.parse(btm, uid: 501)
check(records.count == 2 && records[0].isLegacy && records[0].enabled && records[0].allowed, "reads login records of one account only")
check(records[1].developer == "Example Developer" && !records[1].enabled && records[1].bundleID == "com.example.Notch" && !records[1].opensAtLogin,
      "reads a disabled app record, telling disabled from enabled")

let brewJSON = Data("""
    {"formulae": [
      {"name": "postgresql@14", "desc": "Database", "dependencies": ["icu4c", "openssl@3"], "installed": [{"version": "14.1", "installed_on_request": true}]},
      {"name": "icu4c", "desc": "Unicode", "dependencies": [], "installed": [{"version": "76", "installed_on_request": false}]},
      {"name": "openssl@3", "desc": "TLS", "dependencies": ["ca-certificates"], "installed": [{"version": "3.4", "installed_on_request": false}]}
    ], "casks": [{"token": "aerospace", "name": ["AeroSpace"], "desc": "Tiling", "installed": "0.19", "depends_on": {"formula": ["openssl@3"]}}]}
    """.utf8)
let brew = PackageParsing.homebrew(brewJSON, prefix: "/opt/homebrew")
let icu = brew.first { $0.name == "icu4c" }
let openssl = brew.first { $0.name == "openssl@3" }
check(icu?.requested == false && icu?.neededBy == ["postgresql@14"], "knows a formula was installed for another one")
check(openssl?.neededBy == ["aerospace", "postgresql@14"] && openssl?.needs == [], "lists formulae and apps that need a package, ignoring missing ones")
check(brew.first { $0.name == "aerospace" }?.isCask == true && brew.first { $0.name == "aerospace" }?.reinstall == "brew install --cask aerospace",
      "reads casks and how to install them again")
let npm = PackageParsing.npm(Data(#"{"dependencies": {"npm": {"version": "10"}, "corepack": {"version": "0.3"}, "http-server": {"version": "14.1.1"}}}"#.utf8), root: "/opt/homebrew/lib/node_modules")
check(npm.map(\.name) == ["http-server"] && npm.first?.location?.path == "/opt/homebrew/lib/node_modules/http-server", "lists global npm packages but not npm itself")
let bun = PackageParsing.bun("/Users/x/.bun/install/global node_modules (3)\n├── @openai/codex@0.91.0\n└── react-devtools@7.0.1\n", root: "/r")
check(bun.map(\.name) == ["@openai/codex", "react-devtools"] && bun.first?.version == "0.91.0", "reads Bun's tree, scoped names included")
let cargo = PackageParsing.cargo("rustlings v6.5.0:\n    rustlings\nripgrep v14.1.0:\n    rg\n", bin: "/b")
check(cargo.map(\.name) == ["rustlings", "ripgrep"] && cargo.last?.location?.path == "/b/rg" && cargo.last?.version == "14.1.0", "reads Cargo's installed tools and their binaries")

let extensionsText = """
    4 extension(s)
    --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    *\t*\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.102.4/101.102.4)\tTailscale Network Extension\t[activated enabled]
    \t\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.98.8/101.98.8)\tTailscale Network Extension\t[terminated waiting to uninstall on reboot]
    """
let systemExtensions = Extensions.systemExtensions(extensionsText)
check(systemExtensions.count == 2 && systemExtensions[0].state == "On" && systemExtensions[1].state == "Removed at restart"
      && systemExtensions[0].detail?.hasPrefix("Network extension · Version 1.102.4") == true,
      "reads system extensions with their kind, version and state in plain words")
check(Extensions.receipts("com.apple.pkg.Core\nnet.mullvad.vpn\n").map(\.name) == ["net.mullvad.vpn"], "lists installer packages that aren't Apple's")

let snapshots = Snapshots.parse("Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-09-124133.local (dataless)\ncom.apple.TimeMachine.2026-10-12-134623.local\n")
check(snapshots.count == 2 && snapshots[0].dataless && !snapshots[1].dataless && snapshots[1].stamp == "2026-10-12-134623" && snapshots[1].date != nil,
      "reads Time Machine's local snapshots and their dates")

check(Origins.origin(of: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")) != .thirdParty, "knows Finder is Apple's")
check(Origins.origin(of: root.appendingPathComponent("lonely.bin")) == .thirdParty, "treats a file no installer put there as added")

check(SystemAsset.Feature.of("com_apple_MobileAsset_UAF_Siri_Understanding") == .siriSpeech
      && SystemAsset.Feature.of("com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition") == .siriSpeech
      && SystemAsset.Feature.of("com_apple_MobileAsset_UAF_Siri_TextToSpeech") == .voices
      && SystemAsset.Feature.of("com_apple_MobileAsset_MacSoftwareUpdate") == .updates
      && SystemAsset.Feature.of("com_apple_MobileAsset_PKITrustStore") == .other,
      "sorts macOS's downloads by the feature that needs them")
check(SystemAsset.Feature.allCases.allSatisfy { $0.about.hasSuffix(".") && $0.remedy.hasSuffix(".") && !$0.remedy.hasPrefix($0.about) },
      "says what each kind of download is and, separately, what lets macOS remove it")

// A package installed into a shared folder, its files partly gone, next to someone else's.
let volume = folder("volume")
write("volume/Library/Audio/Plug-Ins/HAL/Loopback.driver/Contents/Info.plist", bytes: 10)
write("volume/Library/Audio/Plug-Ins/HAL/Other.driver/Contents/Info.plist", bytes: 10)
let driverPlan = Receipts.plan(id: "loop", volume: volume, location: "Library/Audio/Plug-Ins/HAL", files: ["._Loopback.driver", "Loopback.driver", "Loopback.driver/Contents", "Loopback.driver/Contents/Info.plist"])
check(driverPlan.roots.map(\.lastPathComponent) == ["Loopback.driver"], "removes a package's driver whole, and nothing beside it")
let gone = Receipts.plan(id: "gone", volume: volume, location: "Library/Audio/Plug-Ins/HAL", files: ["Gone.driver", "Gone.driver/Contents"])
check(gone.roots.isEmpty, "a package whose files are gone leaves only its receipt")
// Installed at the root: shared folders are walked through, a vendor folder shared with another package is not taken whole.
write("volume/Applications/Tool.app/Contents/Info.plist", bytes: 10)
write("volume/Library/Application Support/Vendor/tool.dat", bytes: 10)
write("volume/Library/Application Support/Vendor/other-product.dat", bytes: 10)
write("volume/Library/LaunchDaemons/com.vendor.tool.plist", bytes: 10)
let rootPlan = Receipts.plan(id: "tool", volume: volume, location: "/", files: ["Applications", "Applications/Tool.app", "Applications/Tool.app/Contents",
    "Applications/Tool.app/Contents/Info.plist", "Library", "Library/Application Support", "Library/Application Support/Vendor",
    "Library/Application Support/Vendor/tool.dat", "Library/LaunchDaemons", "Library/LaunchDaemons/com.vendor.tool.plist"])
let rootNames = Set(rootPlan.roots.map { $0.path.replacingOccurrences(of: volume.path, with: "") })
check(rootNames == ["/Applications/Tool.app", "/Library/Application Support/Vendor/tool.dat", "/Library/LaunchDaemons/com.vendor.tool.plist"],
      "takes the package's app, files and launch daemon, never a folder another package also uses (\(rootNames.sorted()))")

write("volume/Applications/Client.app/Contents/Info.plist", bytes: 10)
let bundlePlan = Receipts.plan(id: "client", volume: volume, location: "Applications/Client.app", files: ["Contents", "Contents/Info.plist"])
check(bundlePlan.roots.map(\.lastPathComponent) == ["Client.app"], "a package installed into an app takes the whole app (\(bundlePlan.roots.map(\.path)))")

// Emptying a Trash: a plain file, a locked file and a read-only folder all go.
let fakeTrash = folder("fake-trash")
write("fake-trash/plain.bin", bytes: 100)
let lockedFile = write("fake-trash/locked.bin", bytes: 100)
chflags(lockedFile.path, UInt32(UF_IMMUTABLE))
write("fake-trash/readonly/inside.bin", bytes: 100)
chmod(fakeTrash.appendingPathComponent("readonly").path, 0o555)
let emptied = TrashEmptier.empty(fakeTrash)
check(emptied.removed == 3 && emptied.needsAdministrator.isEmpty && emptied.failed.isEmpty
      && (try? fm.contentsOfDirectory(atPath: fakeTrash.path))?.isEmpty == true,
      "empties a Trash folder, unlocking locked files and read-only folders (\(emptied.removed) removed)")

// MARK: System changes

let accountList = "_amavisd 83\n_BGMXPCHelper 502\nlumen 501\nguest 201\nanna 503\n"
let accounts = SystemChanges.accounts(list: accountList, me: "lumen") { name in
    name == "_BGMXPCHelper" ? "NFSHomeDirectory: /var/empty\nRealName:\n Background Music XPC Helper\nUniqueID: 502\nUserShell: /usr/bin/false\n"
        : "NFSHomeDirectory: /Users/anna\nRealName: Anna\nUserShell: /bin/zsh\n"
}
check(accounts.count == 2 && accounts[0].action == .deleteAccount("_BGMXPCHelper") && accounts[0].name == "Background Music XPC Helper"
      && accounts[1].action == .settings(SystemChanges.usersSettings) && !accounts[1].removable,
      "offers to delete an installer's hidden account, never a person's or macOS's")
let printers = SystemChanges.printers(devices: "device for Office_Printer: dnssd://Office%20Printer._ipp._tcp.local./?uuid=1\n", states: "printer Office_Printer is idle.  enabled since Tue\n")
check(printers.first?.name == "Office Printer" && printers.first?.state == "Idle" && printers.first?.action == .deletePrinter("Office_Printer"), "reads added printers")
let vpns = SystemChanges.vpns("Available network connection services in the current set (*=enabled):\n* (Connected)      00000000-0000 VPN (io.tailscale.ipn.macsys) \"Tailscale\"   [VPN:io.tailscale.ipn.macsys]\n") { $0 == "io.tailscale.ipn.macsys" ? "Tailscale" : nil }
check(vpns.first?.name == "Tailscale" && vpns.first?.state == "Connected" && vpns.first?.owner == "Tailscale" && vpns.first?.ownerGone == false, "reads VPN configurations and their app")
check(SystemChanges.profiles("There are no configuration profiles installed for user 'lumen'").isEmpty
      && SystemChanges.profiles("_computerlevel[1] attribute: profileIdentifier: com.vendor.mdm\n").first?.detail == "For the whole Mac", "reads configuration profiles")

let profilerXML: [[String: Any]] = [["_items": [["_name": "spconfigprofile_section_deviceconfigprofiles", "_items": [
    ["_name": "Spare Privacy", "spconfigprofile_profile_identifier": "com.opyuii.spare.debloat",
     "spconfigprofile_install_date": "Wednesday, 14. October 2026 at 01:53:35 CEST (2026-10-13 23:53:35 +0000)",
     "_items": [["spconfigprofile_payload_data": "{ \"com.opyuii.spare.debloat\" = { tweaks = \"analytics,siri,genmoji\"; }; }"]]],
    ["_name": "Wi-Fi", "spconfigprofile_profile_identifier": "com.school.wifi", "spconfigprofile_organization": "School",
     "spconfigprofile_verification_state": "verified"]
]]]]]
let fromProfiler = SystemChanges.profiles(systemProfiler: (try? PropertyListSerialization.data(fromPropertyList: profilerXML, format: .xml, options: 0)) ?? Data())
check(fromProfiler.count == 2 && fromProfiler[0].origin == .spare && fromProfiler[0].state == "3 switched off"
      && fromProfiler[0].action == .removeProfile("com.opyuii.spare.debloat") && fromProfiler[0].removable
      && fromProfiler[1].detail?.hasPrefix("School · For the whole Mac") == true && !fromProfiler[1].removable,
      "lists the whole Mac's profiles, marks Spare's own as removable, and leaves others to Settings (\(fromProfiler.map(\.state)))")
let privacy = SystemChanges.privacy("kTCCServiceCamera|us.zoom.xos|0|2|1700000000\nkTCCServiceMicrophone|com.apple.Safari|0|2|1\nkTCCServiceAccessibility|/usr/local/bin/gone|1|2|1\n",
                                    scope: "user", appName: { $0 == "us.zoom.xos" ? nil : "x" }, exists: { _ in false })
check(privacy.count == 2 && privacy[0].ownerGone && privacy[0].state == "Allowed" && privacy[0].detail?.hasPrefix("Camera") == true
      && privacy[0].action == .resetPrivacy(service: "kTCCServiceCamera", client: "us.zoom.xos", systemWide: false)
      && privacy[1].removable && privacy[1].action == .resetPrivacy(service: "kTCCServiceAccessibility", client: "/usr/local/bin/gone", systemWide: false)
      && !privacy.contains { $0.name.contains("Safari") },
      "lists privacy permissions of apps that are gone, leaving macOS's own out")

// MARK: Home folder, toolchains, hand-installed tools

let fakeHome = folder("fakehome")
write("fakehome/.ssh/id_ed25519", bytes: 10)
write("fakehome/.cursor/extensions.json", bytes: 10)
write("fakehome/.zsh_history", bytes: 10)
write("fakehome/.mystery/x", bytes: 10)
write("fakehome/.DS_Store", bytes: 10)
let hidden = HomeItems.hidden(home: fakeHome, appInstalled: { _ in false }, toolFound: { $0 == "ssh" })
let byName = Dictionary(uniqueKeysWithValues: hidden.map { ($0.name, $0) })
check(byName[".ssh"]?.sensitive == true && byName[".ssh"]?.ownerGone == false && byName[".cursor"]?.ownerGone == true
      && byName[".zsh_history"]?.kind == "History" && byName[".mystery"]?.owner == nil && byName[".DS_Store"] == nil,
      "names hidden home items by their owner, flags keys, and notices tools that are gone")

write("fakehome/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc", bytes: 10)
write("fakehome/.nvm/versions/node/v20.11.0/bin/node", bytes: 10)
let chains = Toolchains.find(home: fakeHome)
check(chains.contains { $0.name == "Rust stable-aarch64-apple-darwin" && $0.removal == .command(["rustup", "toolchain", "uninstall", "stable-aarch64-apple-darwin"]) }
      && chains.contains { $0.name == "rustup" } && chains.contains { $0.name == "Node v20.11.0" && $0.removal == .trash },
      "finds Rust toolchains, rustup and Node versions (\(chains.map(\.name)))")

let bin = folder("usrlocal/bin")
try fm.createSymbolicLink(atPath: bin.appendingPathComponent("kubectl").path, withDestinationPath: "/Volumes/Docker/Docker.app/Contents/Resources/bin/kubectl")
try fm.createSymbolicLink(atPath: bin.appendingPathComponent("brewed").path, withDestinationPath: "../Cellar/brewed/1.0/bin/brewed")
try Data("#!/bin/sh\nexec xcrun --toolchain Metal \"$(basename \"$0\")\" \"$@\"\n".utf8).write(to: bin.appendingPathComponent("metal"))
write("usrlocal/bin/gsbox", bytes: 100)
let tools = HandTools.find(folders: [bin.path]) { _ in nil }
let toolNames = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
check(toolNames["kubectl"]?.kind == "Broken link" && toolNames["kubectl"]?.note?.contains("Docker") == true && toolNames["brewed"] == nil
      && toolNames["metal"]?.origin == .apple && toolNames["gsbox"]?.origin == .thirdParty,
      "finds hand-installed tools, broken links of removed apps, and Apple's shims, skipping Homebrew's")

write("fakeetc/paths.d/com.vmware.fusion.public", bytes: 0)
try Data("/Applications/VMware Fusion.app/Contents/Public\n".utf8).write(to: root.appendingPathComponent("fakeetc/paths.d/com.vmware.fusion.public"))
var pathItem = Extension(category: .searchPaths, name: "com.vmware.fusion.public", url: root.appendingPathComponent("fakeetc/paths.d/com.vmware.fusion.public"),
                         origin: .thirdParty, forAllUsers: true)
ExtensionsChecks.searchPath(&pathItem)
check(pathItem.note?.contains("which is gone") == true && pathItem.origin == .thirdParty, "notices a search path whose folder is gone")

// System-wide leftovers: a removed product's folder is listed, macOS's and those of installed software are not.
let systemRoot = folder("systemroot")
write("systemroot/Library/Application Support/VMware/a.bin", bytes: 1_000)
write("systemroot/Library/Application Support/CrashReporter/b.bin", bytes: 1_000)
write("systemroot/Library/Application Support/Mozilla/c.bin", bytes: 1_000)
write("systemroot/Library/Preferences/org.cups.printers.plist", bytes: 100)
write("systemroot/Library/Preferences/com.vendor.gone.plist", bytes: 100)
let systemLeft = Apps.systemLeftovers(root: systemRoot, cancel: Cancellation(), companyInUse: { _ in false },
                                      nameInUse: { $0 == "Mozilla" }, origin: { _ in .thirdParty }, inUse: { _ in false })
check(Set(systemLeft.map(\.bundleID)) == ["VMware", "com.vendor.gone"] && systemLeft.allSatisfy(\.forAllUsers),
      "lists system-wide leftovers, never macOS's own or what installed software uses (\(systemLeft.map(\.bundleID).sorted()))")

folder("systemroot/Applications/Gone Suite")
try fm.createSymbolicLink(atPath: root.appendingPathComponent("systemroot/Applications/Gone Suite/Gone Suite").path, withDestinationPath: "/Applications/Utilities/Gone/Gone.app")
write("systemroot/Applications/Here.app/Contents/Info.plist", bytes: 10)
try fm.createSymbolicLink(atPath: root.appendingPathComponent("systemroot/Applications/Live link").path, withDestinationPath: root.appendingPathComponent("systemroot/Applications/Here.app").path)
let shortcuts = Apps.systemLeftovers(root: systemRoot, cancel: Cancellation(), companyInUse: { _ in false },
                                     nameInUse: { $0 == "Mozilla" }, origin: { _ in .thirdParty }, inUse: { _ in false })
check(shortcuts.contains { $0.bundleID == "Gone Suite" } && !shortcuts.contains { $0.bundleID == "Live link" || $0.bundleID == "Here.app" },
      "finds folders of shortcuts to removed apps, keeping working ones")

// MARK: macOS's own clean-up

@discardableResult
func text(_ relative: String, _ content: String) -> URL {
    let url = root.appendingPathComponent(relative)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(content.utf8).write(to: url)
    return url
}

let cacheDeleteAnswer: [String: Any] = [
    "CACHE_DELETE_TOTAL_AVAILABLE": 41_000_000_000, "CACHE_DELETE_VOLUME": "/System/Volumes/Data", "CACHE_DELETE_CACHED_RESULT": kCFBooleanTrue!,
    "CACHE_DELETE_SERVICE_NAMES": ["com.apple.TMCacheDelete": "Time Machine"],
    "com.apple.TMCacheDelete": NSNumber(value: Int64(40_520_339_456)), "com.apple.fspurgeable_data": 1_014_571_008, "com.apple.MAIL": 0,
    "com.example.flag": true, "com.example.nested": ["bytes": 5], "com.example.negative": -5
]
check(CacheDelete.itemized(cacheDeleteAnswer) == ["com.apple.TMCacheDelete": 40_520_339_456, "com.apple.fspurgeable_data": 1_014_571_008,
                                                   "com.apple.MAIL": 0, "com.example.negative": 0],
      "reads macOS's purgeable space per service, without its own totals, flags or nested answers")

let gained = CacheDelete.PurgeResult(service: "s", reported: 100, freeBefore: 1_000, freeAfter: 5_000)
let filledAgain = CacheDelete.PurgeResult(service: "s", reported: 700, freeBefore: 5_000, freeAfter: 4_000)
let decoded = (try? JSONEncoder().encode(gained)).flatMap { try? JSONDecoder().decode(CacheDelete.PurgeResult.self, from: $0) }
check(gained.freed == 4_000 && filledAgain.freed == 700 && CacheDelete.PurgeResult(service: "s", error: "x").freed == 0
      && CacheDelete.PurgeResult(service: "s", reported: -3).freed == 0 && decoded == gained,
      "counts what a purge freed by the volume's gain, else by what macOS reported")
check(CacheDelete.Service.allCases.filter(\.spareFrees) == [.purgeableFiles, .macOSDownloads]
      && CacheDelete.Service.macOSDownloads.urgency == 1 && CacheDelete.Service.purgeableFiles.urgency == 3 && CacheDelete.Service.timeMachine.urgency == 3
      && CacheDelete.Service.allCases.allSatisfy { !$0.title.isEmpty && $0.about.hasSuffix(".") },
      "offers only purgeable files and macOS's unneeded downloads, each at its own urgency")

// MARK: Apple Intelligence

check(AppleIntelligence.baseLanguage("de-DE") == "de" && AppleIntelligence.baseLanguage("en_GB") == "en" && AppleIntelligence.baseLanguage("en") == "en"
      && AppleIntelligence.baseLanguage("zh-Hans-CN") == "zh" && AppleIntelligence.baseLanguage("yue-CN") == "yue",
      "compares languages without their region or script")

func aiStatus(_ system: String?, _ siri: String?, _ answer: Int?, models: Bool? = false, saved: Bool = false, vm: Bool = false) -> AppleIntelligence.Status {
    AppleIntelligence.evaluate(systemLanguage: system, siriLanguage: siri, siriEnabled: false, eligibilityAnswer: answer, modelsSelected: models,
                               savedBySpare: saved, isVirtualMachine: vm)
}
let likeThisMac = aiStatus("en-GB", "de-DE", nil)
check(likeThisMac.state == .off && likeThisMac.eligible == nil
      && likeThisMac.explanation == "Off: Siri speaks German and your Mac English, so macOS keeps Apple Intelligence switched off.",
      "explains that Apple Intelligence is off while Siri and the Mac speak different languages")
check(aiStatus("en-GB", "en-US", 4).state == .on && aiStatus("en-GB", "en-GB", nil).state == .on
      && aiStatus("en-GB", "en-US", 4).explanation.hasPrefix("On: Siri and your Mac both use English"),
      "sees Apple Intelligence on while Siri follows the Mac's language")
check(aiStatus("en-GB", "de-DE", 2, models: true).state == .releasing && aiStatus("en-GB", "en-GB", 2).state == .unavailable
      && aiStatus("en-GB", "en-GB", 4, vm: true).state == .unavailable && aiStatus(nil, nil, nil).state == .unknown
      && aiStatus(nil, nil, 2).explanation == "Off: macOS keeps Apple Intelligence switched off."
      && aiStatus("en-GB", "de-DE", 2, saved: true).explanation.hasSuffix(" Turning it on puts your Siri settings back."),
      "tells held models, Macs without Apple Intelligence, virtual machines and unknowns apart")

let siriSpeaks = ["en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "ja-JP"]
check(AppleIntelligence.offLanguage(system: "en-GB", current: "de_DE", installed: [], supported: siriSpeaks) == "de-DE"
      && AppleIntelligence.offLanguage(system: "en-GB", current: "en-GB", installed: ["en-US", "fr-FR"], supported: siriSpeaks) == "fr-FR"
      && AppleIntelligence.offLanguage(system: "en-GB", current: "en-GB", installed: [], supported: siriSpeaks) == "es-ES"
      && AppleIntelligence.offLanguage(system: "de-DE", current: nil, installed: ["it-IT"], supported: siriSpeaks) == "en-US"
      && AppleIntelligence.offLanguage(system: "en-GB", current: "en-GB", installed: [], supported: nil) == "es-ES"
      && AppleIntelligence.offLanguage(system: "en-US", current: "en-US", installed: [], supported: ["en-US", "en-GB"]) == nil,
      "picks a Siri language that switches Apple Intelligence off: the current one, then downloaded ones, then common ones")

check(AppleIntelligence.eligibilityAnswer(in: ["OS_ELIGIBILITY_DOMAIN_SIRI_MODE": ["os_eligibility_answer_t": 2, "os_eligibility_answer_source_t": 1]]) == 2
      && AppleIntelligence.eligibilityAnswer(in: ["OS_ELIGIBILITY_DOMAIN_SIRI_MODE": 4]) == 4
      && AppleIntelligence.eligibilityAnswer(in: ["OS_ELIGIBILITY_DOMAIN_GREYMATTER": ["os_eligibility_answer_t": 4]]) == nil,
      "reads macOS's answer on whether Apple Intelligence may run")

func modelCatalogState(_ objects: [Any]?) -> Data {
    var fields: [String: Any] = [:]
    if let objects {
        fields["setConfiguration"] = try? PropertyListSerialization.data(fromPropertyList: ["$archiver": "NSKeyedArchiver", "$objects": objects],
                                                                        format: .binary, options: 0)
    }
    return (try? PropertyListSerialization.data(fromPropertyList: ["SUCorePersistedStatePolicySecureCodedObjectsFields": fields],
                                                format: .binary, options: 0)) ?? Data()
}
check(AppleIntelligence.modelsSelected(in: modelCatalogState(["$null", "com.apple.fm.language.instruct_3b.base.generic_sparse"])) == true
      && AppleIntelligence.modelsSelected(in: modelCatalogState(["$null", "com.apple.fm.vision.base"])) == false
      && AppleIntelligence.modelsSelected(in: modelCatalogState(nil)) == false
      && AppleIntelligence.modelsSelected(in: Data("not a property list".utf8)) == nil,
      "tells whether the model catalog still holds Apple Intelligence's language model")

/// Siri's settings and macOS's answers, played by the checks. Eligibility catches up with a change of Siri's
/// language on the `delay`th read after it.
final class FakeSiri: SiriEnvironment {
    enum Eligibility { case follows(delay: Int), stuck(Int), unreadable }
    struct Refused: Error {}

    var system: String? = "en-GB"
    var siri: String?
    var voice: Data? = Data([1, 2, 3])
    var saved: SavedSiri?
    var supported = ["en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "ja-JP"]
    var installed: [String] = []
    var eligibility: Eligibility
    var answer: Int
    var pending: (answer: Int, reads: Int)?
    var failing: Set<String> = []
    var failSave = false
    var virtual = false
    var events: [String] = []
    var sleeps: [Double] = []

    init(siri: String, _ eligibility: Eligibility) {
        self.siri = siri
        self.eligibility = eligibility
        answer = AppleIntelligence.baseLanguage(siri) == "en" ? 4 : 2
    }

    func systemLanguage() -> String? { system }
    func siriLanguage() -> String? { siri }
    func siriEnabled() -> Bool? { false }
    func outputVoice() -> Data? { voice }
    func supportedLanguages() -> [String]? { supported }
    func installedSiriLanguages() -> [String] { installed }
    func eligibilityAnswer() -> Int? {
        switch eligibility {
        case .unreadable: return nil
        case .stuck(let fixed): return fixed
        case .follows:
            if let next = pending { if next.reads <= 1 { answer = next.answer; pending = nil } else { pending = (next.answer, next.reads - 1) } }
            return answer
        }
    }
    func write(siriLanguage: String, outputVoice: Data?) throws {
        events.append("write \(siriLanguage)" + (outputVoice == nil ? "" : " with voice"))
        guard !failing.contains(siriLanguage) else { throw Refused() }
        siri = siriLanguage
        if let outputVoice { voice = outputVoice }
        if case .follows(let delay) = eligibility {
            pending = (AppleIntelligence.baseLanguage(siriLanguage) == AppleIntelligence.baseLanguage(system ?? "") ? 4 : 2, delay)
        }
    }
    func loadSaved() -> SavedSiri? { saved }
    func save(_ saved: SavedSiri?) throws {
        events.append(saved.map { "save \($0.siriLanguage)" } ?? "forget")
        if failSave { throw Refused() }
        self.saved = saved
    }
    func sleep(_ seconds: Double) { sleeps.append(seconds) }
    func isVirtualMachine() -> Bool { virtual }
}

func purger(_ fake: FakeSiri) -> () -> CacheDelete.PurgeResult {
    { fake.events.append("purge"); return CacheDelete.PurgeResult(service: CacheDelete.Service.macOSDownloads.rawValue, reported: 12_000_000_000) }
}
var steps: [String] = []

let switchingOff = FakeSiri(siri: "en-GB", .follows(delay: 3))
switchingOff.installed = ["de-DE"]
let switchedOff = AppleIntelligenceSwitch.turnOff(switchingOff, purge: purger(switchingOff)) { steps.append($0) }
check(switchedOff.done && switchedOff.error == nil && switchedOff.siriLanguage == "de-DE" && switchedOff.purge?.reported == 12_000_000_000
      && switchingOff.events == ["save en-GB", "write de-DE", "purge"] && switchingOff.saved?.siriLanguage == "en-GB"
      && switchingOff.saved?.outputVoice == Data([1, 2, 3]) && switchingOff.sleeps == [1, 1, 15]
      && steps.contains("Switching Siri to German (Germany)…") && steps.last == "Asking macOS to delete them…",
      "switches Apple Intelligence off through Siri's language, saving Siri's settings first (\(switchingOff.events), \(switchingOff.sleeps), \(steps))")

let stubborn = FakeSiri(siri: "en-GB", .stuck(4))
let stubbornOutcome = AppleIntelligenceSwitch.turnOff(stubborn, purge: purger(stubborn)) { _ in }
check(!stubbornOutcome.done && stubbornOutcome.error?.hasPrefix("macOS still lets Apple Intelligence run with Siri in Spanish (Spain).") == true
      && stubborn.events == ["save en-GB", "write es-ES", "write en-GB with voice", "forget"] && stubborn.siri == "en-GB" && stubborn.saved == nil
      && stubborn.sleeps == Array(repeating: 1, count: 8),
      "puts Siri back as it was when macOS keeps Apple Intelligence on (\(stubborn.events))")

let blindOff = FakeSiri(siri: "en-GB", .unreadable)
let blindOffOutcome = AppleIntelligenceSwitch.turnOff(blindOff, purge: purger(blindOff)) { _ in }
check(blindOffOutcome.done && blindOff.sleeps == [8, 15] && blindOff.events.last == "purge",
      "waits a fixed time when it can't ask macOS (\(blindOff.sleeps))")

let refusedOff = FakeSiri(siri: "en-GB", .follows(delay: 1))
refusedOff.failing = ["es-ES"]
let refusedOffOutcome = AppleIntelligenceSwitch.turnOff(refusedOff, purge: purger(refusedOff)) { _ in }
check(!refusedOffOutcome.done && refusedOffOutcome.error == "macOS didn't accept the new Siri language. Siri is as it was."
      && refusedOff.events == ["save en-GB", "write es-ES", "write en-GB with voice", "forget"] && refusedOff.siri == "en-GB",
      "undoes a change of Siri's language that macOS refused")

let unsaved = FakeSiri(siri: "en-GB", .follows(delay: 1))
unsaved.failSave = true
let unsavedOutcome = AppleIntelligenceSwitch.turnOff(unsaved, purge: purger(unsaved)) { _ in }
check(!unsavedOutcome.done && unsaved.events == ["save en-GB"] && unsaved.siri == "en-GB", "changes nothing when Siri's settings can't be saved first")

let backOn = FakeSiri(siri: "de-DE", .follows(delay: 1))
backOn.voice = nil
backOn.saved = SavedSiri(siriLanguage: "en-GB", outputVoice: Data([1, 2, 3]), savedAt: Date())
let backOnOutcome = AppleIntelligenceSwitch.turnOn(backOn)
check(backOnOutcome.done && backOn.siri == "en-GB" && backOn.voice == Data([1, 2, 3]) && backOn.saved == nil
      && backOn.events == ["write en-GB with voice", "forget"],
      "switches Apple Intelligence back on with Siri's saved language and voice, then forgets them")
let followOn = FakeSiri(siri: "de-DE", .follows(delay: 1))
followOn.system = "en-NZ"
let followOnOutcome = AppleIntelligenceSwitch.turnOn(followOn)
check(followOnOutcome.done && followOnOutcome.siriLanguage == "en-US" && followOn.events == ["write en-US"],
      "without saved settings, sets Siri to the language closest to the Mac's")

let held = FakeSiri(siri: "de-DE", .follows(delay: 2))
steps = []
let released = AppleIntelligenceSwitch.release(held, purge: purger(held)) { steps.append($0) }
check(released.done && released.siriLanguage == "de-DE" && held.siri == "de-DE" && held.events == ["write en-GB", "write de-DE with voice", "purge"]
      && held.sleeps == [1, 20, 1, 15] && steps.first == "Switching Siri to English (UK) for a moment…",
      "gets macOS to let go of models it still holds, and puts Siri back (\(held.events), \(held.sleeps))")

let neverAvailable = FakeSiri(siri: "de-DE", .stuck(2))
let neverReleased = AppleIntelligenceSwitch.release(neverAvailable, purge: purger(neverAvailable)) { _ in }
check(!neverReleased.done && neverAvailable.siri == "de-DE" && !neverAvailable.events.contains("purge")
      && neverReleased.error == "macOS didn't make Apple Intelligence available, so it can't let go of the models. Siri is back as it was.",
      "puts Siri back when macOS never makes Apple Intelligence available")

let blindRelease = FakeSiri(siri: "de-DE", .unreadable)
let blindReleased = AppleIntelligenceSwitch.release(blindRelease, purge: purger(blindRelease)) { _ in }
check(blindReleased.done && blindRelease.sleeps == [30, 20, 30, 15] && blindRelease.siri == "de-DE",
      "releases on fixed waits when it can't ask macOS (\(blindRelease.sleeps))")

let refusedRelease = FakeSiri(siri: "de-DE", .follows(delay: 1))
refusedRelease.failing = ["en-GB"]
let refusedReleased = AppleIntelligenceSwitch.release(refusedRelease, purge: purger(refusedRelease)) { _ in }
check(!refusedReleased.done && refusedReleased.error == "macOS didn't accept the change. Siri is back as it was."
      && refusedRelease.events == ["write en-GB", "write de-DE with voice"] && refusedRelease.siri == "de-DE",
      "puts Siri back when macOS refuses the brief switch")

let alreadyOn = FakeSiri(siri: "en-US", .stuck(4))
let alreadyOnOutcome = AppleIntelligenceSwitch.release(alreadyOn, purge: purger(alreadyOn)) { _ in }
check(alreadyOnOutcome.error?.hasSuffix("Switch it off first.") == true && alreadyOn.events.isEmpty, "changes nothing while Apple Intelligence is on")

let virtualMac = FakeSiri(siri: "en-GB", .stuck(2))
virtualMac.virtual = true
let virtualOff = AppleIntelligenceSwitch.turnOff(virtualMac, purge: purger(virtualMac)) { _ in }
let virtualRelease = AppleIntelligenceSwitch.release(virtualMac, purge: purger(virtualMac)) { _ in }
check(!virtualOff.done && !virtualRelease.done && virtualMac.events.isEmpty && virtualOff.error?.contains("virtual machine") == true,
      "leaves Siri alone in a virtual machine")

// MARK: macOS's downloads and what keeps them

let assetFolders: [String: SystemAsset.Feature] = [
    "com_apple_MobileAsset_UAF_Siri_UnderstandingASRHammer": .siriSpeech, "com_apple_MobileAsset_SpeechEndpointMacOSAssets": .siriSpeech,
    "com_apple_MobileAsset_TTSAXResourceModelAssets": .voices, "com_apple_MobileAsset_MacinTalkVoiceAssets": .voices,
    "com_apple_MobileAsset_VoiceServices_CombinedVocalizerVoices": .voices, "com_apple_MobileAsset_UAF_FM_GenerativeModels": .appleIntelligence,
    "com_apple_MobileAsset_UAF_FM_Visual": .appleIntelligence, "com_apple_MobileAsset_UAF_IF_Planner": .appleIntelligence,
    "com_apple_MobileAsset_UAF_Siri_AnswerSynthesis": .appleIntelligence, "com_apple_MobileAsset_UAF_Photos_SpatialPhotosRelive": .photos,
    "com_apple_MobileAsset_UAF_LinguisticData": .languageData, "com_apple_MobileAsset_LinguisticData": .languageData,
    "com_apple_MobileAsset_UAF_Translation_Assets": .languageData, "com_apple_MobileAsset_MetalToolchain": .metal,
    "com_apple_MobileAsset_DictionaryServices_dictionary3macOS": .dictionaries, "com_apple_MobileAsset_Font7": .fonts,
    "com_apple_MobileAsset_MobileSoftwareUpdate_MacUpdateBrain": .updates
]
let misfiled = assetFolders.filter { SystemAsset.Feature.of($0.key) != $0.value }.map(\.key)
check(misfiled.isEmpty, "knows which feature each of macOS's asset folders serves (\(misfiled))")

let assetsRoot = folder("assets")
write("assets/com_apple_MobileAsset_UAF_Siri_Understanding/a/model.bin", bytes: 1_200_000)
write("assets/com_apple_MobileAsset_MetalToolchain/x.bin", bytes: 10_000)
write("assets/com_apple_MobileAsset_UAF_FM_GenerativeModels/sealed/model.bin", bytes: 10_000)
let sealed = assetsRoot.appendingPathComponent("com_apple_MobileAsset_UAF_FM_GenerativeModels/sealed")
chmod(sealed.path, 0)
let measuredAssets = SystemAssets.measure(root: assetsRoot)
chmod(sealed.path, 0o755)
check(measuredAssets.map(\.feature) == [.appleIntelligence, .siriSpeech] && measuredAssets.first?.hidden == true
      && measuredAssets.first?.measurable == false && (measuredAssets.last?.bytes ?? 0) >= 1_200_000 && measuredAssets.last?.hidden == false,
      "keeps downloads macOS won't let Spare measure, and leaves out tiny ones (\(measuredAssets.map(\.feature.rawValue)))")

let subscriptions = [
    ("com.apple.siri.embeddedspeech", "assistant.de_DE"), ("com.apple.siri.embeddedspeech", "assistant.en_GB"),
    ("com.apple.siri.embeddedspeech", "hammer.en_US"), ("com.apple.siri.tts", "com.apple.siri.tts.voice.de_DE.de-DE-D.neural.premium"),
    ("com.apple.ProofReader", "com.apple.ProofReader.LinguisticData.de.DataDeliveryService_0"),
    ("com.apple.ProofReader", "com.apple.ProofReader.LinguisticData.mul_Latn.DataDeliveryService_0"),
    ("com.apple.DictionaryServices", "com.apple.DictionaryServices;en_US;com.apple.dictionary.NOAD.DataDeliveryService_0"),
    ("com.apple.DictionaryServices", "com.apple.DictionaryServices;en_GB;com.apple.dictionary.NOAD.DataDeliveryService_1"),
    ("com.apple.DictionaryServices", "com.apple.DictionaryServices;de_DE;com.apple.dictionary.Duden.DataDeliveryService_0"),
    ("com.apple.mediaanalysisd", "photos.spatial.relive"), ("com.apple.handwritingd", "handwriting.synthesis.en"),
    ("com.apple.intelligence.summarizationkit", "summarization.base"), ("model-catalog", "safety.guardrail")
].map { AssetSubscriptions.Subscription(client: $0.0, name: $0.1) }
func holder(_ feature: SystemAsset.Feature, _ list: [AssetSubscriptions.Subscription] = subscriptions) -> String? {
    AssetSubscriptions.holder(of: feature, in: list, siriLanguage: "de-DE", systemLanguage: "en-GB")
}
check(holder(.siriSpeech) == "Kept for Siri in German and English, even with Siri off." && holder(.voices) == "Kept for Siri's voices in German."
      && holder(.languageData) == "Kept for spelling and typing suggestions in German."
      && holder(.dictionaries) == "Kept for 2 dictionaries in the Dictionary app." && holder(.photos) == "Kept for Photos."
      && holder(.appleIntelligence) == "Kept for Apple Intelligence's handwriting, summaries and safety checks."
      && holder(.updates) == nil && holder(.siriSpeech, []) == nil,
      "says what keeps each kind of macOS download (\(holder(.siriSpeech) ?? "nil"))")
check(AssetSubscriptions.siriLanguages(in: subscriptions) == ["de-DE", "en-GB"], "finds the languages Siri keeps speech models for")

let subscriptionsFile = folder("asset subscriptions").appendingPathComponent("UAF Subscriptions.db")
var database: OpaquePointer?
if sqlite3_open(subscriptionsFile.path, &database) == SQLITE_OK {
    sqlite3_exec(database, """
        CREATE TABLE Subscriptions (k0 TEXT, k1 TEXT, k4 TEXT);
        INSERT INTO Subscriptions VALUES ('com.apple.siri.embeddedspeech', 'assistant.fr_FR', 'u1'), ('com.apple.siri.embeddedspeech', 'assistant.fr_FR', 'u2'),
            ('com.apple.DictionaryServices', 'com.apple.DictionaryServices;en_US;com.apple.dictionary.NOAD.DataDeliveryService_0', 'u1');
        """, nil, nil, nil)
}
sqlite3_close(database)
let storedSubscriptions = AssetSubscriptions.live(database: subscriptionsFile.path)
check(storedSubscriptions == [AssetSubscriptions.Subscription(client: "com.apple.DictionaryServices", name: "com.apple.DictionaryServices;en_US;com.apple.dictionary.NOAD.DataDeliveryService_0"),
                              AssetSubscriptions.Subscription(client: "com.apple.siri.embeddedspeech", name: "assistant.fr_FR")]
      && AssetSubscriptions.live(database: root.appendingPathComponent("missing.db").path) == nil,
      "reads macOS's subscriptions database read-only, each subscription once")

// MARK: Update leftovers

let installData = folder("install data")
write("install data/UpdateBundle/AssetData/payload.bin", bytes: 50_000)
write("install data/InstallAssistant.pkg.integrityDataV1", bytes: 1_000)
write("install data/Locked Files/BridgeOS.bundle", bytes: 1_000)
let sproduct: [String: Any] = ["Packages": [["Identifier": "com.apple.pkg.InstallAssistant.macOSSequoia", "Version": "24.6.231",
                                             "Size": 15_653_022_048, "URL": "InstallAssistant.pkg"]]]
(sproduct as NSDictionary).write(to: installData.appendingPathComponent("index.sproduct"), atomically: true)
let lastYear = Date().addingTimeInterval(-400 * 86_400)
for item in [installData] + (try fm.contentsOfDirectory(at: installData, includingPropertiesForKeys: nil)) {
    try fm.setAttributes([.modificationDate: lastYear], ofItemAtPath: item.path)
}
let installedAfter = text("systems/after/SystemVersion.plist", "<plist/>")
let installedBefore = text("systems/before/SystemVersion.plist", "<plist/>")
try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-800 * 86_400)], ofItemAtPath: installedBefore.path)
let leftover = UpdateLeftovers.find(folder: installData, systemVersion: installedAfter)
let waiting = UpdateLeftovers.find(folder: installData, systemVersion: installedBefore)
check(leftover?.isLeftover == true && waiting?.isLeftover == false && leftover?.product == "macOS Sequoia installer (24.6.231)"
      && Set(leftover?.items.map(\.lastPathComponent) ?? []) == ["UpdateBundle", "InstallAssistant.pkg.integrityDataV1", "index.sproduct"]
      && (leftover?.bytes ?? 0) >= 50_000 && leftover?.downloaded != nil,
      "finds what an update left behind without touching Locked Files, and tells it from an update still waiting")
check(UpdateLeftovers.find(folder: root.appendingPathComponent("no install data")) == nil, "finds nothing without the folder")
check(UpdateLeftovers.productName(["Packages": [["Identifier": "com.apple.pkg.InstallAssistant.macOSBigSur", "Version": "20.6"]]]) == "macOS Big Sur installer (20.6)"
      && UpdateLeftovers.productName(["Packages": [["Identifier": "com.apple.pkg.macOSBrain", "Version": "26.1"]]]) == "macOS update (26.1)"
      && UpdateLeftovers.productName([:]) == nil,
      "names the macOS an update was for")

// MARK: Cloud downloads

check(CloudDownloads.providerName("OneDrive-Personal") == "OneDrive (Personal)"
      && CloudDownloads.providerName("GoogleDrive-anna@example.com") == "Google Drive (anna@example.com)"
      && CloudDownloads.providerName("Dropbox") == "Dropbox" && CloudDownloads.providerName("Box-Box") == "Box"
      && CloudDownloads.containerName("57T9237FN3~net~whatsapp~WhatsApp") == "WhatsApp" && CloudDownloads.containerName("iCloud~md~obsidian") == "Obsidian"
      && CloudDownloads.containerName("com~apple~CloudDocs") == "iCloud Drive",
      "names cloud providers and iCloud's app folders")
let cloudHome = folder("cloudhome")
let keptOnMac = write("cloudhome/Library/CloudStorage/OneDrive-Personal/Documents/report.pdf", bytes: 20_000)
write("cloudhome/Library/Mobile Documents/com~apple~CloudDocs/Desktop/note.txt", bytes: 20_000)
write("cloudhome/Library/Mobile Documents/57T9237FN3~net~whatsapp~WhatsApp/Accounts/backup.bin", bytes: 20_000)
let keptAttributes = CloudDownloads.attributes(of: keptOnMac.path)
check(CloudDownloads.scan(home: cloudHome, cancel: Cancellation()).isEmpty
      && CloudDownloads.removeDownloads(under: cloudHome.appendingPathComponent("Library"), cancel: Cancellation()) == CloudDownloads.Removal()
      && keptAttributes?.purgeable == false && keptAttributes?.allocated == blocks(keptOnMac.path),
      "finds no downloads among files kept on this Mac, and removes none")

// MARK: Simulators and Docker

let simulatorDevices = Data(#"""
{"devices": {
  "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
    {"lastBootedAt": "2026-09-30T08:12:44Z", "dataPath": "/Users/x/Library/Developer/CoreSimulator/Devices/A1/data", "dataPathSize": 2147483648,
     "logPath": "/Users/x/Library/Logs/CoreSimulator/A1", "udid": "A1", "isAvailable": true, "logPathSize": 4096,
     "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro", "state": "Shutdown", "name": "iPhone 16 Pro"}],
  "com.apple.CoreSimulator.SimRuntime.xrOS-2-0": [
    {"dataPath": "/Users/x/Library/Developer/CoreSimulator/Devices/B2/data", "dataPathSize": 1048576, "udid": "B2", "isAvailable": false,
     "availabilityError": "runtime profile not found", "state": "Shutdown", "name": "Apple Vision Pro", "lastBootedAt": "2025-02-01T10:00:00.123Z",
     "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro"}],
  "com.apple.CoreSimulator.SimRuntime.watchOS-11-1": []
}}
"""#.utf8)
let devices = Simulators.devices(json: simulatorDevices)
check(devices.map(\.name) == ["iPhone 16 Pro", "Apple Vision Pro"] && devices[0].runtime == "iOS 18.2" && devices[0].isAvailable
      && devices[0].bytes == 2_147_483_648 && devices[0].dataURL?.lastPathComponent == "data" && devices[0].lastBooted != nil
      && devices[1].runtime == "visionOS 2.0" && !devices[1].isAvailable && devices[1].problem == "runtime profile not found" && devices[1].lastBooted != nil,
      "reads Xcode's simulators")
let simulatorRuntimes = Data(#"""
{"6E5B4C3A-0000-4000-8000-000000000001": {"build": "22C150", "deletable": true, "identifier": "6E5B4C3A-0000-4000-8000-000000000001",
   "kind": "Disk Image", "lastUsedAt": "2026-09-30T08:12:44Z", "platformIdentifier": "com.apple.platform.iphonesimulator",
   "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-2", "sizeBytes": 8682459843, "state": "Ready", "version": "18.2"},
 "6E5B4C3A-0000-4000-8000-000000000002": {"build": "21R355", "deletable": false, "identifier": "6E5B4C3A-0000-4000-8000-000000000002",
   "kind": "Bundled with Xcode", "platformIdentifier": "com.apple.platform.watchsimulator", "sizeBytes": 3400000000, "state": "Ready", "version": "10.0"}}
"""#.utf8)
let runtimes = Simulators.runtimes(json: simulatorRuntimes)
check(runtimes.map(\.name) == ["iOS 18.2", "watchOS 10.0"] && runtimes[0].bytes == 8_682_459_843 && runtimes[0].deletable && runtimes[0].build == "22C150"
      && runtimes[0].lastUsed != nil && runtimes[0].identifier == "6E5B4C3A-0000-4000-8000-000000000001"
      && runtimes[1].kind == "Bundled with Xcode" && !runtimes[1].deletable,
      "reads Xcode's simulator runtimes")
check(Simulators.runtimeName("com.apple.CoreSimulator.SimRuntime.tvOS-17-4") == "tvOS 17.4"
      && Simulators.runtimeName("com.apple.CoreSimulator.SimRuntime.xrOS-1-0") == "visionOS 1.0" && Simulators.runtimeName("odd") == "odd",
      "names simulator runtimes")

let dockerUsage = Docker.usage(lines: """
    {"Active":"2","Reclaimable":"1.2GB (45%)","Size":"2.66GB","TotalCount":"5","Type":"Images"}
    {"Active":"1","Reclaimable":"0B (0%)","Size":"12.3kB","TotalCount":"3","Type":"Containers"}
    {"Active":"0","Reclaimable":"512.4MB","Size":"512.4MB","TotalCount":"21","Type":"Build Cache"}
    WARNING: not JSON
    """)
check(dockerUsage.count == 3 && dockerUsage[0] == Docker.Usage(kind: "Images", count: 5, active: 2, bytes: 2_660_000_000, reclaimable: 1_200_000_000)
      && dockerUsage[1].bytes == 12_300 && dockerUsage[1].reclaimable == 0 && dockerUsage[2].reclaimable == 512_400_000,
      "reads what Docker's images, containers and build cache take")
check(Docker.bytes("1.23GB") == 1_230_000_000 && Docker.bytes("512.4MB (40%)") == 512_400_000 && Docker.bytes("0B") == 0
      && Docker.bytes("1.2kB") == 1_200 && Docker.bytes("1.5GiB") == 1_610_612_736 && Docker.bytes("N/A") == nil && Docker.bytes("3 parsecs") == nil,
      "reads the sizes Docker prints")
let dockerHome = folder("dockerhome")
write("dockerhome/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 30_000)
write("dockerhome/.colima/_lima/colima-dev/diffdisk", bytes: 20_000)
write("dockerhome/.local/share/containers/podman/machine/applehv/podman-machine-default-arm64.raw", bytes: 10_000)
write("dockerhome/.orbstack/data/data.img", bytes: 0)
let diskImages = Docker.diskImages(home: dockerHome)
check(diskImages.map(\.app) == ["Docker Desktop", "Colima (dev)", "Podman"] && diskImages.first.map { $0.bytes == blocks($0.url.path) } == true,
      "finds the virtual disks of Docker Desktop, Colima and Podman by the space they take")

// MARK: Browser extensions

let browserHome = folder("browserhome")
let chrome = "browserhome/Library/Application Support/Google/Chrome"
text("\(chrome)/Local State", #"{"profile": {"info_cache": {"Default": {"name": "Personal"}, "Profile 1": {"name": "Work"}}}}"#)
text("\(chrome)/Default/Preferences", #"{"extensions": {"settings": {"aaaa": {"state": 1}}}}"#)
text("\(chrome)/Default/Secure Preferences", #"{"extensions": {"settings": {"bbbb": {"disable_reasons": [1]}}}}"#)
text("\(chrome)/Default/Extensions/aaaa/1.9.0_0/manifest.json",
     #"{"name": "__MSG_appName__", "default_locale": "en", "version": "1.9.0", "update_url": "https://clients2.google.com/service/update2/crx"}"#)
text("\(chrome)/Default/Extensions/aaaa/1.9.0_0/_locales/en/messages.json", #"{"appName": {"message": "Old Helper"}}"#)
text("\(chrome)/Default/Extensions/aaaa/1.10.0_0/manifest.json", #"""
    {"name": "__MSG_appName__", "default_locale": "en", "version": "1.10.0", "update_url": "https://clients2.google.com/service/update2/crx",
     "content_scripts": [{"matches": ["<all_urls>"], "js": ["page.js"]}]}
    """#)
text("\(chrome)/Default/Extensions/aaaa/1.10.0_0/_locales/en/messages.json", "\u{FEFF}" + #"{"APPNAME": {"message": "Page Helper"}}"#)
text("\(chrome)/Default/Extensions/bbbb/2.0_0/manifest.json", #"{"name": "Side Tool", "version": "2.0", "host_permissions": ["https://example.com/*"]}"#)
text("\(chrome)/Default/Extensions/cccc/1.0_0/manifest.json", #"{"version": "1.0", "description": "A helper without a name"}"#)
text("\(chrome)/Profile 1/Preferences", "{}")
text("\(chrome)/Profile 1/Extensions/dddd/3.1_0/manifest.json",
     #"{"name": "Everywhere", "version": "3.1", "permissions": ["https://*/*", "tabs"], "update_url": "https://updates.example.com/x.xml"}"#)
text("browserhome/Library/Application Support/com.operasoftware.Opera/Preferences", "{}")
text("browserhome/Library/Application Support/com.operasoftware.Opera/Extensions/eeee/1.0_0/manifest.json",
     #"{"name": "Opera Thing", "version": "1.0", "update_url": "https://extension-updates.opera.com/api/omaha/update/"}"#)
let chromiumExtensions = BrowserExtensions.chromium(home: browserHome)
let chromiumByID = Dictionary(chromiumExtensions.map { ($0.extensionID, $0) }) { first, _ in first }
let pageHelper = chromiumByID["aaaa"], sideTool = chromiumByID["bbbb"], everywhere = chromiumByID["dddd"], operaThing = chromiumByID["eeee"]
check(chromiumExtensions.count == 4 && chromiumByID["cccc"] == nil
      && pageHelper?.name == "Page Helper" && pageHelper?.version == "1.10.0" && pageHelper?.allSites == true && pageHelper?.enabled == true
      && pageHelper?.fromStore == true && pageHelper?.profile == "Personal" && pageHelper?.browser == .chrome && (pageHelper?.bytes ?? 0) > 0
      && pageHelper?.id == "Google Chrome|Personal|aaaa"
      && sideTool?.enabled == false && sideTool?.allSites == false && sideTool?.fromStore == nil
      && everywhere?.profile == "Work" && everywhere?.allSites == true && everywhere?.fromStore == false && everywhere?.enabled == nil
      && operaThing?.browser == .opera && operaThing?.profile == nil && operaThing?.fromStore == true,
      "reads Chromium browsers' extensions: newest version, translated name, site access, store and on or off (\(chromiumExtensions.map(\.name)))")

let firefoxSupport = "browserhome/Library/Application Support/Firefox"
text("\(firefoxSupport)/profiles.ini", "[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/x1y2z3.default-release\nDefault=1\n\n[General]\nStartWithLastProfile=1\n")
let xpi = write("\(firefoxSupport)/Profiles/x1y2z3.default-release/extensions/blocker@example.org.xpi", bytes: 30_000)
text("\(firefoxSupport)/Profiles/x1y2z3.default-release/extensions.json", """
    {"schemaVersion": 36, "addons": [
     {"id": "blocker@example.org", "type": "extension", "location": "app-profile", "version": "1.62.0", "active": true, "path": "\(xpi.path)",
      "defaultLocale": {"name": "Blocker"}, "signedState": 2, "installTelemetryInfo": {"source": "amo"},
      "userPermissions": {"permissions": ["storage"], "origins": ["<all_urls>"]}},
     {"id": "side@example.org", "type": "extension", "location": "app-profile", "version": "0.3", "active": false, "path": "/nowhere/side.xpi",
      "defaultLocale": {"name": "Sideloaded"}, "signedState": 0, "installTelemetryInfo": {"source": "file-url"},
      "userPermissions": {"origins": ["https://example.com/*"]}},
     {"id": "formautofill@mozilla.org", "type": "extension", "location": "app-builtin", "defaultLocale": {"name": "Form Autofill"}},
     {"id": "langpack-de@firefox.mozilla.org", "type": "locale", "location": "app-profile", "defaultLocale": {"name": "Deutsch"}}
    ]}
    """)
let firefoxExtensions = BrowserExtensions.firefox(home: browserHome)
check(firefoxExtensions.map(\.name) == ["Blocker", "Sideloaded"] && firefoxExtensions[0].profile == "default-release"
      && firefoxExtensions[0].allSites && firefoxExtensions[0].fromStore == true && firefoxExtensions[0].enabled == true
      && firefoxExtensions[0].bytes == blocks(xpi.path) && firefoxExtensions[0].browser == .firefox
      && firefoxExtensions[1].enabled == false && firefoxExtensions[1].fromStore == false && !firefoxExtensions[1].allSites && firefoxExtensions[1].bytes == nil,
      "reads the extensions people added to Firefox, leaving out Firefox's own")

// pluginkit's output on a real Mac, with the apps moved into the temporary folder, plus a few made-up entries.
let apps = root.appendingPathComponent("Apps").path
text("Apps/Bitwarden.app/Contents/PlugIns/safari.appex/Contents/Resources/manifest.json",
     #"{"name": "__MSG_extName__", "default_locale": "en", "permissions": ["<all_urls>", "storage"]}"#)
text("Apps/Bitwarden.app/Contents/_MASReceipt/receipt", "receipt")
text("Apps/Reader.app/Contents/PlugIns/Extension.appex/Contents/Resources/manifest.json",
     #"{"name": "__MSG_extension_name__", "default_locale": "en", "host_permissions": ["https://example.com/*"]}"#)
text("Apps/Reader.app/Contents/PlugIns/Extension.appex/Contents/Resources/_locales/en/messages.json", #"{"extension_name": {"message": "Reader Mode"}}"#)
let legacyInfo: NSDictionary = ["NSExtension": ["NSExtensionPointIdentifier": "com.apple.Safari.extension", "SFSafariWebsiteAccess": ["Level": "All"]]]
folder("Apps/Legacy.app/Contents/PlugIns/Legacy.appex/Contents")
legacyInfo.write(to: root.appendingPathComponent("Apps/Legacy.app/Contents/PlugIns/Legacy.appex/Contents/Info.plist"), atomically: true)
let pluginkitSample = """
         com.bitwarden.desktop.safari(2026.9.0)
    \t            Path = /Applications/Bitwarden.app/Contents/PlugIns/safari.appex
    \t            UUID = E9E184FB-84AD-468A-8CEC-CE982A496253
    \t       Timestamp = 2026-09-28 14:54:44 +0000
    \t             SDK = com.apple.Safari.web-extension
    \t   Parent Bundle = /Applications/Bitwarden.app
    \t    Display Name = Bitwarden
    \t      Short Name = Bitwarden
    \t     Parent Name = Bitwarden
    \t        Platform = macOS

    +    com.example.reader.Extension(1.4)
    \t            Path = /Applications/Reader.app/Contents/PlugIns/Extension.appex
    \t             SDK = com.apple.Safari.web-extension
    \t   Parent Bundle = /Applications/Reader.app
    \t    Display Name = Extension
    \t     Parent Name = Reader

    -    com.example.blocker.Rules(2.0)
    \t            Path = /Applications/Blocker.app/Contents/PlugIns/Rules.appex
    \t             SDK = com.apple.Safari.content-blocker
    \t   Parent Bundle = /Applications/Blocker.app
    \t    Display Name = Blocker Rules
    \t     Parent Name = Blocker

         com.example.legacy(1.0)
    \t            Path = /Applications/Legacy.app/Contents/PlugIns/Legacy.appex
    \t             SDK = com.apple.Safari.extension
    \t   Parent Bundle = /Applications/Legacy.app
    \t    Display Name = Legacy Helper
    \t     Parent Name = Legacy

         com.example.reader.Extension(1.2)
    \t            Path = /Old/Reader.app/Contents/PlugIns/Extension.appex
    \t             SDK = com.apple.Safari.web-extension
    \t    Display Name = Extension
    \t     Parent Name = Reader

     (5 plug-ins)
    """.replacingOccurrences(of: "/Applications/", with: apps + "/")
let safariExtensions = BrowserExtensions.safari(pluginkit: pluginkitSample)
let safariByID = Dictionary(safariExtensions.map { ($0.extensionID, $0) }) { first, _ in first }
let bitwarden = safariByID["com.bitwarden.desktop.safari"], reader = safariByID["com.example.reader.Extension"]
check(safariExtensions.count == 4 && bitwarden?.name == "Bitwarden" && bitwarden?.version == "2026.9.0" && bitwarden?.enabled == nil
      && bitwarden?.allSites == true && bitwarden?.fromStore == true && bitwarden?.containingApp?.lastPathComponent == "Bitwarden.app"
      && bitwarden?.url?.lastPathComponent == "safari.appex" && (bitwarden?.bytes ?? 0) > 0
      && reader?.name == "Reader Mode" && reader?.version == "1.4" && reader?.enabled == true && reader?.fromStore == false && reader?.allSites == false
      && safariByID["com.example.blocker.Rules"]?.enabled == false && safariByID["com.example.blocker.Rules"]?.fromStore == nil
      && safariByID["com.example.blocker.Rules"]?.bytes == nil && safariByID["com.example.legacy"]?.allSites == true,
      "reads Safari's extensions from pluginkit, with their apps, site access and on or off marks (\(safariExtensions.map(\.name)))")

// MARK: Browser and app caches, Mail and Messages

let supportHome = folder("supporthome")
let slack = "supporthome/Library/Application Support/Slack"
text("\(slack)/Network Persistent State", "{}")
write("\(slack)/Cache/Cache_Data/data_1", bytes: 200_000)
write("\(slack)/Code Cache/js/index", bytes: 100_000)
write("\(slack)/Local Storage/leveldb/000003.log", bytes: 100_000)
write("\(slack)/IndexedDB/https_app.slack.com_0.indexeddb.leveldb/000003.log", bytes: 100_000)
text("supporthome/Library/Application Support/Code/Network Persistent State", "{}")
write("supporthome/Library/Application Support/Code/CachedData/0a1b2c/chrome/js/data", bytes: 150_000)
write("supporthome/Library/Application Support/Plain App/Cache/data.bin", bytes: 300_000)
let chromeData = "supporthome/Library/Application Support/Google/Chrome"
text("\(chromeData)/Local State", "{}")
write("\(chromeData)/GrShaderCache/data_0", bytes: 100_000)
text("\(chromeData)/Default/Network/Network Persistent State", "{}")
write("\(chromeData)/Default/GPUCache/data_1", bytes: 150_000)
write("\(chromeData)/Default/Service Worker/CacheStorage/abc/data", bytes: 100_000)
let supportContext = ScanContext(home: supportHome, projectRoots: [], inactiveAfter: 0, fullDiskAccess: false, isOpen: { $0 == "Google" })
let supportItems = Catalog.rule("app-support-caches")?.find(supportContext, Cancellation()) ?? []
let supportByLabel = Dictionary(supportItems.map { ($0.label, $0) }) { first, _ in first }
func cacheNames(_ label: String) -> Set<String> { Set(supportByLabel[label]?.urls.map(\.lastPathComponent) ?? []) }
check(Set(supportByLabel.keys) == ["Slack", "Visual Studio Code", "Google Chrome"]
      && cacheNames("Slack") == ["Cache", "Code Cache"] && supportByLabel["Slack"]?.suggested == true
      && cacheNames("Visual Studio Code") == ["CachedData"] && cacheNames("Google Chrome") == ["GrShaderCache", "GPUCache"]
      && supportByLabel["Google Chrome"]?.suggested == false && supportByLabel["Google Chrome"]?.detail == "Open now. Quit it first to clean this.",
      "takes only the caches of Chromium browsers and Electron apps, never their data or another app's Cache folder (\(supportItems.map(\.label)))")

let messagesHome = folder("messageshome")
write("messageshome/Library/Messages/Attachments/ab/01/GUID-1/IMG_0001.MOV", bytes: 6_000_000)
write("messageshome/Library/Messages/Attachments/cd/02/GUID-2/IMG_0002.HEIC", bytes: 1_000_000)
write("messageshome/Library/Messages/Attachments/ef/03/GUID-3/Talk.pdf", bytes: 7_000_000)
write("messageshome/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/UUID-1/Invoice.pdf", bytes: 30_000)
write("messageshome/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/UUID-2/Photo.jpg", bytes: 30_000)
let withAccess = ScanContext(home: messagesHome, projectRoots: [], inactiveAfter: 0, fullDiskAccess: true)
let withoutAccess = ScanContext(home: messagesHome, projectRoots: [], inactiveAfter: 0, fullDiskAccess: false)
let attachments = Catalog.rule("messages-attachments")?.find(withAccess, Cancellation()) ?? []
check(attachments.map(\.label) == ["Talk.pdf", "IMG_0001.MOV"] && attachments.allSatisfy { !$0.suggested && $0.detail?.hasPrefix("From ") == true },
      "lists Messages attachments of 5 MB or more, largest first, never selected (\(attachments.map(\.label)))")
let mailCopies = Catalog.rule("mail-downloads")?.find(withAccess, Cancellation()) ?? []
check(mailCopies.count == 1 && mailCopies.first?.label == "2 attachments" && mailCopies.first?.urls.count == 2 && mailCopies.first?.suggested == true
      && Catalog.rule("mail-downloads")?.find(withoutAccess, Cancellation()).isEmpty == true,
      "offers Mail's copies of opened attachments as one item, with Full Disk Access only")

// MARK: Catalog

check(Set(Catalog.rules.map(\.id)).count == Catalog.rules.count, "every rule has its own identifier")
check(Catalog.rules.filter { $0.safety == .review }.allSatisfy { $0.group == .review }, "everything that needs a decision sits under Your Call")
check(Bytes.text(1_500_000_000).hasSuffix("GB") && Bytes.text(1_500_000_000).hasPrefix("1"), "writes sizes in the decimal units Finder uses")


// MARK: Privacy and debloat

check(Set(Debloat.all.map(\.id)).count == Debloat.all.count, "every privacy setting has its own identifier")
check(Debloat.all.filter { $0.group == .intelligence }.allSatisfy(\.inProfile), "every Apple Intelligence switch is locked by the profile")
check(Debloat.setsToRemove(off: ["writing-tools"]).isEmpty, "keeps the language models while other features still need them")
let everyAI = Set(Debloat.all.filter { $0.group == .intelligence }.map(\.id))
check(Set(Debloat.setsToRemove(off: everyAI)) == Set(Debloat.modelSets.map(\.name)), "removes every model set once every feature is off")
check(Debloat.setsToRemove(off: ["photos-clean-up"]) == ["com.apple.MobileAsset.UAF.Photos.MagicCleanup"], "removes one feature's own models on their own")
check(Debloat.Value.bool(true).matches(NSNumber(value: 1)) && !Debloat.Value.bool(true).matches(NSNumber(value: 0))
      && Debloat.Value.int(2).matches(NSNumber(value: 2)) && !Debloat.Value.string("a").matches(nil),
      "reads stored preferences as defaults writes them, booleans and 0 or 1 alike")
if let data = try? Debloat.profile(["analytics", "writing-tools", "improve-siri", "photos-clean-up"]),
   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
   let parts = plist["PayloadContent"] as? [[String: Any]] {
    let restrictions = parts.first { $0["PayloadType"] as? String == "com.apple.applicationaccess" }
    let domains = parts.compactMap { ($0["PayloadContent"] as? [String: Any])?.keys.first }
    let blocks = parts.compactMap { ($0["PayloadContent"] as? [String: Any])?["com.apple.MobileAsset"] as? [String: Any] }.first
    let forced = ((blocks?["Forced"] as? [[String: Any]])?.first?["mcx_preference_settings"] as? [String: Any]) ?? [:]
    check(restrictions?["allowDiagnosticSubmission"] as? Bool == false && restrictions?["allowWritingTools"] as? Bool == false
          && restrictions?["allowGameCenter"] == nil,
          "writes a restriction for each chosen setting and none for the others")
    check(domains.contains("com.apple.assistant.support") && domains.contains(Debloat.profileIdentifier), "locks Siri's sharing and marks the profile as Spare's")
    check(forced.keys.sorted() == ["DownloadServerBaseURLOverride-com.apple.MobileAsset.UAF.Photos.MagicCleanup"],
          "keeps only the removed models from downloading again (\(forced.keys.sorted()))")
    check(plist["PayloadIdentifier"] as? String == Debloat.profileIdentifier && (try? Debloat.profile(["analytics"])).flatMap {
              (try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any])?["PayloadUUID"] as? String
          } == plist["PayloadUUID"] as? String,
          "gives the profile the same identity every time, so a new one replaces the old")
} else {
    check(false, "writes the privacy profile as a property list")
}
let chess = BuiltInApp(url: URL(fileURLWithPath: "/System/Applications/Chess.app"), bundleID: "com.apple.Chess", name: "Chess",
                       job: "application.com.apple.Chess.11.12")
check(BuiltInApps.block(of: chess, disabled: ["application.com.apple.Chess.11.12"]) == .blocked
      && BuiltInApps.block(of: chess, disabled: ["application.com.apple.Chess.9.10"]) == .lapsed
      && BuiltInApps.block(of: chess, disabled: ["application.com.apple.Chessboard.11.12"]) == .open,
      "tells a blocked app from one an update unblocked, and never mistakes another app for it")
if let listed = BuiltInApps.list().first(where: { $0.bundleID == "com.apple.Chess" }) {
    check(listed.job?.hasPrefix("application.com.apple.Chess.") == true && listed.job?.split(separator: ".").count == 6,
          "names a built-in app's launch job by its file numbers (\(listed.job ?? "none"))")
}
check(!BuiltInApps.list().contains { $0.url.lastPathComponent == "System Settings.app" }, "never offers to block System Settings")

// MARK: Undo everything

if let tweak = Debloat.all.first(where: { $0.changes.contains { if case .pref = $0 { true } else { false } } }),
   case .pref(let domain, let key, let value)? = tweak.changes.first(where: { if case .pref = $0 { true } else { false } }) {
    var journal = Debloat.Journal()
    let spares: (String, String) -> Any? = { _, _ in value.object }
    check(!Debloat.changedBySpare(tweak, journal: journal, read: spares), "leaves a setting Spare never changed to the person")
    journal.entries["pref:\(domain):\(key)"] = .init(previous: .pref(nil), date: Date())
    journal.entries["dock:com.apple.Chess"] = .init(previous: .dock([]), date: Date())
    let undoable = Debloat.undoable(apps: [], disabled: [], journal: journal, read: spares)
    check(Debloat.changedBySpare(tweak, journal: journal, read: spares) && undoable.tweaks == [tweak.id] && undoable.blocked.isEmpty,
          "undoes only what Spare recorded changing, and never the Dock (\(undoable))")
    check(!Debloat.changedBySpare(tweak, journal: journal, read: { _, _ in nil }) || value.matches(nil),
          "leaves a setting the person changed back since")
    if let keys = Debloat.all.first(where: { $0.id == "media-keys" }) {
        var quitting = Debloat.Journal()
        quitting.entries["quit:com.apple.Music"] = .init(previous: .quits(false), date: Date())
        check(keys.changes == [.quit("com.apple.Music")] && !keys.inProfile, "keeps Music closed with the helper, not by switching off the play keys")
        check(Debloat.changedBySpare(keys, journal: quitting, read: { _, _ in ["com.apple.Music"] })
              && !Debloat.changedBySpare(keys, journal: quitting, read: { _, _ in nil }), "undoes the helper quitting Music only while it does")
    } else {
        check(false, "has the play keys setting")
    }
    check(Debloat.Value.bool(true).matches("YES") && Debloat.Value.bool(false).matches("no") && !Debloat.Value.bool(true).matches("NO"),
          "reads `defaults write … YES` as on")
} else {
    check(false, "the catalog has a setting outside the profile")
}

// MARK: Finder

let pathbar = FinderOptions.all.first { $0.id == "pathbar" }!
let warning = FinderOptions.all.first { $0.id == "extension-warning" }!
let scope = FinderOptions.all.first { $0.id == "search-here" }!
check(!pathbar.isOn(nil) && pathbar.isOn(NSNumber(value: true)) && pathbar.value(on: false) == nil && pathbar.value(on: true) == .bool(true),
      "shows the path bar only when switched on, and switching it off removes Spare's value")
check(warning.isOn(nil) && !warning.isOn(NSNumber(value: false)) && warning.value(on: true) == nil && warning.value(on: false) == .bool(false),
      "keeps a setting macOS has on unless switched off")
check(!scope.isOn("SCev") && scope.isOn("SCcf") && scope.value(on: true) == .string("SCcf"),
      "searches the folder you're in with Finder's own code for it")
check(Set(FinderOptions.all.map(\.id)).count == FinderOptions.all.count, "gives every Finder setting its own name")

print(failures == 0 ? "All checks passed." : "\(failures) checks failed.")
exit(failures == 0 ? 0 : 1)
