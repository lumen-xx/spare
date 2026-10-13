import Foundation
import Security
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
    \t\t   64571      - \tapplication.cc.ffitch.shottr.63416020.63416029
    \t\t       0      0 \tcom.vendor.agent
    \t}
    }
    """
let services = Launchd.parse(printed)
check(services["com.vendor.agent"] == Launchd.Status(loaded: true, pid: nil), "reads a loaded job that isn't running")
check(services["application.cc.ffitch.shottr.63416020.63416029"]?.pid == 64571, "reads a running job's process")

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

// MARK: Catalog

check(Set(Catalog.rules.map(\.id)).count == Catalog.rules.count, "every rule has its own identifier")
check(Catalog.rules.filter { $0.safety == .review }.allSatisfy { $0.group == .review }, "everything that needs a decision sits under Your Call")
check(Bytes.text(1_500_000_000).hasSuffix("GB") && Bytes.text(1_500_000_000).hasPrefix("1"), "writes sizes in the decimal units Finder uses")

print(failures == 0 ? "All checks passed." : "\(failures) checks failed.")
exit(failures == 0 ? 0 : 1)
