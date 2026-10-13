# Spare

An honest Mac cleaner for Apple silicon, macOS 14 or newer. It shows what takes up space, says plainly what each thing is and what happens once it's gone, and moves only what you choose to the Trash.

![Spare's Cleanup](docs/images/cleanup.png)

| | |
|---|---|
| ![Apps](docs/images/apps.png) | ![Background Items](docs/images/background.png) |
| ![Packages](docs/images/packages.png) | |

## Install

macOS 14 or newer · Apple silicon

1. [Download Spare](https://github.com/lumen-xx/spare/releases/latest), unzip it and move **Spare.app** to **Applications**.
2. Open it. If macOS blocks it, go to **System Settings → Privacy & Security → Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Spare.app`. Spare is signed but not notarized yet.
3. Optional: give it **Full Disk Access** so it can also look at Downloads, iPhone backups and other apps' data. Without it, Spare skips the folders macOS protects and says which.

Spare is open source under the [MIT License](LICENSE). It never deletes anything itself: everything goes to the Trash, and History can put it back. It has no background process and only goes online when you check for updates.

Screenshots in docs/images are made from sample data: `swift build`, run `.build/debug/Spare -demo YES -section Cleanup -AppleLocale en_US`, capture the window, then `swift scripts/marketing.swift <window.png> <out.png> <headline> <subtitle> work/marketing/icon.png`.

## What it does

Every topic has its own page in the sidebar.

**Free Up Space**
- **Cleanup**: Xcode build data and device support files; node_modules, Rust targets, Swift .build folders and other build folders beside their project file; package manager caches; app caches except macOS's own; the caches Chromium browsers and Electron apps such as Slack and VS Code keep beside their data; copies Mail saved of attachments you opened; logs; crash reports. Things that come back by themselves are selected; caches of open apps, projects touched within a month and anything a running program has open are not. **Your Call** lists old downloads, Messages attachments of 5 MB or more, device backups, Xcode archives and AI models, never selected.
- **Space**: folder sizes from your home folder down.
- **Purgeable Space**: what macOS counts as System Data and gives back by itself when it runs low, part by part as macOS's own clean-up service reports it (Time Machine snapshots, files apps marked purgeable, cloud copies, app container caches, the Spotlight index, thumbnails). **Free Now** asks macOS to remove the files apps marked purgeable and downloads nothing uses any more, one service at a time, after checking that macOS will limit the purge to that service. The service is private to macOS, so it's called from a short-lived child copy of Spare; a change in macOS can then only stop the child. Time Machine's local snapshots are listed below and deleted with `tmutil deletelocalsnapshots` after a password prompt.
- **macOS Downloads**: what macOS downloaded for itself. **Free** moves what an update or upgrade left in "macOS Install Data" to the Trash after a password prompt, once it's older than the running system, and asks macOS to remove the downloads no feature needs any more. Apple Intelligence's models stay while it's on: **Switch Off** sets Siri to another language, which makes macOS switch Apple Intelligence off and remove them, after a sheet that names the language and says it syncs to iPhone and iPad; **Switch On** puts Siri's language and voice back. Everything else in /System/Library/AssetsV2 is listed by feature with what keeps it, read from macOS's asset subscriptions (Siri in German and English, three dictionaries), and the setting that would let it go. System Integrity Protection guards these folders, so no app can delete them directly.
- **Cloud Downloads**: files iCloud Drive, OneDrive, Google Drive, Dropbox and other File Provider apps keep downloaded while they're also online, per folder. Removing a download is what Finder's Remove Download does: the file stays in the cloud and in its folder. Only files that are fully uploaded and free of conflicts are touched, and folders that are online only are never opened, so nothing downloads.

**Apps & Software**
- **Apps**: each app with the files it keeps in ~/Library, matched by bundle identifier or exact name; uninstalling quits it, stops its login agents and moves everything to the Trash.
- **Leftovers**: files in ~/Library and /Library named after software no installed app, process or background job uses; folders of shortcuts to removed apps in /Applications. In /Library, nothing of macOS's and nothing of a company whose software is still installed is listed.
- **Packages**: Homebrew formulae and casks with what needs what, and global npm, pnpm, Bun, Cargo, uv and pipx packages, removed with each manager's own command.
- **Toolchains**: Rust toolchains and rustup (removed with rustup), Node, Python and Ruby versions, conda, SDKs and Xcode's Command Line Tools.
- **Command-Line Tools**: commands in /usr/local no package manager tracks, with broken links of removed apps and Apple's own shims marked.
- **Simulators**: Xcode's simulators with their size and when each last started, and the simulator systems (iOS, watchOS, tvOS, visionOS disk images) with how many simulators use each. Simulators that can't run any more are deleted together; others can be erased or deleted, and systems deleted, with Xcode's `simctl` after a confirmation. simctl is found through `xcode-select`, so a Mac without Xcode is never asked to install developer tools.
- **Docker**: the disk file of Docker Desktop, OrbStack, Colima or Podman with the space it really takes, and what's inside as `docker system df` counts it. Build cache, images no container uses and stopped containers are cleared with Docker's own prune commands; volumes can hold databases, so they're only shown.
- **Browser Extensions**: extensions in every profile of Chrome, Edge, Brave, Arc, Vivaldi, Opera, Firefox and Safari, with the ones that can read and change every website marked. Spare only lists them, since removing one in its browser is what stops it syncing back.

**Startup**
- **Login Items** and **Background Items**: tables with multiple selection. Launchd jobs can be turned off (`launchctl disable` + `bootout`), on, or removed; items apps register with macOS (from `sfltool dumpbtm`) link to Login Items settings; helper tools nothing starts are flagged.

**System Additions**: System Extensions (removed only with their app, so each says how), Drivers, Plug-ins, Fonts, Input Methods, Installer Packages (what a receipt still has on disk goes to the Trash and macOS forgets the receipt) and Search Paths (/etc/paths.d). Origin comes from installer receipts and Apple's code signature: macOS's own is locked, Apple's optional additions are labelled.

**System Changes**: hidden Accounts installers created (`dscl . -delete`), added Printers (`lpadmin -x`), VPN configurations and configuration Profiles (changed in Settings), and Privacy permissions given to apps (reset with `tccutil`; needs Full Disk Access to read).

**Home Folder**: Hidden Items in your home folder named by their owner, with keys marked and leftovers of removed tools flagged; the Shared Folder.

**History** lists every move, with Put Back, until the Trash is emptied. **Settings** holds project folders, Full Disk Access and updates.

## Honesty rules

- Nothing is deleted by Spare except when you empty the Trash. Items go to the Trash; History records where each came from. Some things belong to a tool that removes them itself: package managers, Xcode's simulators, Docker, macOS's own clean-up and cloud apps' downloads. Accounts, printers and privacy decisions aren't files. Spare says so, and whether it can be undone, before any of these run.
- Everything that needs an administrator in one action goes in one request, through one script per session, so macOS's five-minute grace period applies.
- Nothing a running program has open is offered or moved (open files are read through libproc, as lsof does), so the Trash never ends up holding files an app still writes to.
- Sizes are allocated blocks on disk. A file hard-linked from elsewhere (for example a pnpm store) is shown as shared and not counted as freed. APFS clones can't be told apart, so a cloned file counts in full.
- macOS's own caches, documents and photos are never offered. From Mail only its copies of attachments you opened are, since the messages keep theirs; Messages attachments are listed under Your Call and never selected.
- Without Full Disk Access, Spare doesn't open guarded folders at all, so macOS never asks for them one by one; they're shown as locked.
- No background process, no menu bar item, no notifications, no network access except optional update checks.

How Spare looks, moves and feels, with the motion, texture and accessibility specs, is in [docs/DESIGN.md](docs/DESIGN.md).

`.build/debug/Spare --report` prints what a cleanup would find, and `--inventory` what has been added to the Mac, without changing anything.

## Build and verify

Requires the Swift 6.2/macOS 26 SDK; the package uses swift-tools-version 5.9 and macOS 14 deployment.

```sh
swift run SpareChecks
bash scripts/build-app.sh
open dist/Spare.app
```

The app is arm64 with embedded Sparkle 2.10.0, bundle id com.opyuii.spare, and signed with a stable local identity (Spare Local Signing, created once by scripts/signing-identity.sh) so Full Disk Access survives updates. Regenerate the icon with `swift scripts/icon.swift work` followed by `iconutil -c icns work/Spare.iconset -o Sources/Spare/Resources/AppIcon.icns`.

## Releases

Releases are published here, with the signed appcast as a release asset: https://github.com/lumen-xx/spare/releases/latest/download/appcast.xml. Automatic checks are opt-in.

`updates/config.json` holds the feed and public key; the private key lives only in the login Keychain under account `spare`. `updates/signing-certificate.txt` pins the code signing certificate so Full Disk Access survives updates. Do not generate a replacement for either on an existing release stream.

```sh
bash scripts/prepare-release.sh 0.1.1 2
bash scripts/publish-release.sh 0.1.1
```

Build numbers must increase. Versions up to 0.3.1 were published in lumen-xx/spare-releases and read their feed from there; publishing copies each new signed feed into it (with docs/LEGACY_README.md as its README), so those copies update to a build that reads the feed here.

## Thanks

Purgeable Space and the Apple Intelligence switch build on the research [MacSpace](https://github.com/1architect/macspace-releases) published about macOS's own clean-up service and about how Siri's language decides whether Apple Intelligence runs.

## License

[MIT](LICENSE). Third-party notices, including Sparkle's and the Bricolage Grotesque typeface's, are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
