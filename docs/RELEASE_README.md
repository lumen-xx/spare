# Spare

An honest Mac cleaner. It shows what takes up space, says plainly what each thing is and what happens once it's gone, and moves only what you choose to the Trash. Everything stays on your Mac.

![Spare's Cleanup: what each thing is and what happens once it's gone](images/cleanup.png)

## Install

macOS 14+ · Apple silicon

1. [Download Spare](https://github.com/lumen-xx/spare-releases/releases/latest), unzip and move **Spare.app** to **Applications**.
2. Open it. If macOS blocks it, go to **System Settings → Privacy & Security → Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Spare.app
```

Spare is not notarized yet. Only run this for Spare downloaded here.

3. Optional: give it **Full Disk Access** (System Settings → Privacy & Security) so it can also look at Downloads, iPhone backups and other apps' data.

## Use

Every topic has its own page in the sidebar:

- **Free Up Space**: Cleanup (caches, build folders, logs, with plain explanations), Space, Time Machine Snapshots, and what macOS downloaded for Apple Intelligence, dictation and voices.
- **Apps & Software**: Apps with their files, Leftovers of removed apps (yours and system-wide), Packages (Homebrew, npm, pnpm, Bun, Cargo, uv, pipx), Toolchains (Rust, Node, Python versions, Xcode's tools), and Command-Line Tools in /usr/local.
- **Startup**: Login Items and Background Items. Select several, then turn them off, on, or remove them.
- **System Additions**: System Extensions, Drivers, Plug-ins, Fonts, Input Methods, Installer Packages and Search Paths.
- **System Changes**: hidden Accounts installers created, Printers, VPN, Profiles and Privacy permissions given to apps.
- **Home Folder**: hidden items in your home folder, named by their owner, and the Shared folder.
- **History**: everything Spare moved to the Trash, with Put Back.

Everything that is part of macOS is marked and locked. Nothing a running app has open is moved.

![Uninstall an app with every file it keeps](images/apps.png)

![Login and background items, with leftovers of removed apps marked](images/background.png)

![Homebrew, npm and other packages, with what needs each one](images/packages.png)

Spare never deletes anything itself, has no background process or menu bar icon, and never sends anything anywhere.

Updates: **Spare → Check for Updates…**

The source repository is private.
