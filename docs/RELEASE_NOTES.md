# Spare 0.2.1

- **Installer packages can be removed.** Spare reads what a package installed, moves whatever is still there to the Trash, stops its background jobs and has macOS forget it, after one password prompt. Packages whose files are already gone lose only their record. Folders other software shares, and anything of macOS's, are never touched.
- **System extensions say how they go.** macOS removes one only with its app, so each row tells you whether to uninstall its app, restart, or reinstall a removed app and delete it. States read On, Off and Removed at restart, and the app can be uninstalled from there.
- **Select all leftovers** with one click in Apps › Leftovers.
- **Time Machine snapshots** show what macOS actually reports: emptied snapshots as 0 KB, and the purgeable total they belong to. macOS gives no size per snapshot.
- Homebrew uninstalls that need your password say so, with the command to run in Terminal.
