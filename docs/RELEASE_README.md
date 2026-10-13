# Spare

An honest Mac cleaner. It shows what takes up space, says plainly what each thing is and what happens once it's gone, and moves only what you choose to the Trash. Everything stays on your Mac.

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

- **Cleanup**: Xcode build data, node_modules and other build folders in projects you haven't touched for a month, package manager caches, app caches, logs and crash reports. Only things that come back by themselves are selected.
- **Your Call**: old downloads, iPhone backups, Xcode archives and AI models. Listed, never selected for you.
- **Space**: which folders take the most room, as deep as you like.
- **Apps**: uninstall an app together with the files it keeps in your Library, and find leftovers of apps you already removed.
- **Background Items**: everything that starts on its own, which app it belongs to, and which ones were left behind.
- **History**: everything Spare moved to the Trash, with Put Back.

Spare never deletes anything itself, has no background process or menu bar icon, and never sends anything anywhere.

Updates: **Spare → Check for Updates…**

The source repository is private.
