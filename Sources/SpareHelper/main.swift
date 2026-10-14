import AppKit

// Quits the apps Spare was asked to keep closed the moment they open; QuitWatcher in SpareCore starts and stops it.
// The list is read again each time, so a change in Spare applies at once.
// Another preferences domain can be named for trying it out without touching Spare's own.
let domain = (CommandLine.arguments.dropFirst().first ?? "com.opyuii.spare") as CFString
let key = "quitWhenOpened" as CFString

func listed() -> Set<String> {
    CFPreferencesAppSynchronize(domain)
    return Set(CFPreferencesCopyAppValue(key, domain) as? [String] ?? [])
}

func quit(_ apps: [NSRunningApplication]) {
    let ids = listed()
    for app in apps where app.bundleIdentifier.map(ids.contains) == true { app.forceTerminate() }
}

// Nothing to quit: done, and launchd leaves it stopped.
if listed().isEmpty { exit(0) }
quit(NSWorkspace.shared.runningApplications)
// The list of running apps changes as soon as one starts, before it has finished opening and shown a window.
let watching = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { _, change in
    quit(change.newValue ?? [])
}
withExtendedLifetime(watching) { RunLoop.main.run() }
