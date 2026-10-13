# Spare

An honest Mac cleaner for Apple silicon, macOS 14 or newer. It shows what takes up space, says plainly what each thing is and what happens once it's gone, and moves only what you choose to the Trash.

## What it does

- **Cleanup**: Xcode build data and device support files; node_modules, Rust targets, Swift .build folders and other build folders beside their project file; package manager caches (npm, pnpm, Yarn, Bun, Homebrew, pip, uv, CocoaPods, SwiftPM, Gradle, Maven, Cargo, Go, Composer, Deno, Playwright and more); app caches except macOS's own; logs; crash reports. Things that come back by themselves are selected. Caches of open apps and projects touched within a month are not.
- **Your Call**: old installers and large unopened files in Downloads, iPhone and iPad backups, Xcode archives, downloaded AI models. Listed, never selected.
- **Space**: folder sizes from your home folder down, measured in parallel; any folder can be opened.
- **Apps**: size of each app plus the files it keeps in ~/Library, matched by bundle identifier or exact name only. Uninstalling quits the app, stops its login agents and moves everything to the Trash. Leftovers lists files named after bundle identifiers that no installed app, running process or background job uses.
- **Background Items**: every launchd job in ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons, plus jobs inside apps, with owner, schedule, state and plain notes for common ones. Jobs whose program is gone and helper tools nothing starts are flagged. Removing system jobs goes through macOS's administrator prompt.
- **History**: every move, with Put Back, until the Trash is emptied.

## Honesty rules

- Nothing is deleted by Spare. Items go to the Trash; History records where each came from.
- Sizes are allocated blocks on disk. A file hard-linked from elsewhere (for example a pnpm store) is shown as shared and not counted as freed. APFS clones can't be told apart, so a cloned file counts in full.
- macOS's own caches, documents, photos, mail and messages are never offered.
- Without Full Disk Access, Spare doesn't open guarded folders at all, so macOS never asks for them one by one; they're shown as locked.
- No background process, no menu bar item, no notifications, no network access except optional update checks.

`.build/debug/Spare --report` prints what a cleanup would find without changing anything.

## Build and verify

Requires the Swift 6.2/macOS 26 SDK; the package uses swift-tools-version 5.9 and macOS 14 deployment.

```sh
swift run SpareChecks
bash scripts/build-app.sh
open dist/Spare.app
```

The app is arm64 with embedded Sparkle 2.10.0, bundle id com.opyuii.spare, and signed with a stable local identity (Spare Local Signing, created once by scripts/signing-identity.sh) so Full Disk Access survives updates. Regenerate the icon with `swift scripts/icon.swift work` followed by `iconutil -c icns work/Spare.iconset -o Sources/Spare/Resources/AppIcon.icns`.

## Releases

Download: https://github.com/lumen-xx/spare-releases/releases/latest. The raw appcast is https://raw.githubusercontent.com/lumen-xx/spare-releases/main/appcast.xml; automatic checks are opt-in.

`updates/config.json` holds the feed and public key; the private key lives only in the login Keychain under account `spare`. `updates/signing-certificate.txt` pins the code signing certificate so Full Disk Access survives updates. Do not generate a replacement for either on an existing release stream. docs/RELEASE_README.md is the release repository's README.

```sh
bash scripts/prepare-release.sh 0.1.1 2
bash scripts/publish-release.sh 0.1.1
```

Build numbers must increase. Source stays private in lumen-xx/spare; binaries are public in lumen-xx/spare-releases.
