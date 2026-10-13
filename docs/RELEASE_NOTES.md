# Spare 0.2.0

Everything added to your Mac since it was new, in one place, and safer cleaning.

- **Login Items** and **Background Items** are now tables: select several with ⌘ or ⇧ and turn them off, back on, or remove them together. They include what apps register with macOS themselves, read from the same list as System Settings, plus helper tools left behind by removed apps.
- **Packages** lists Homebrew formulae and apps, and global npm, pnpm, Bun, Cargo, uv and pipx packages, with what each one is needed by. Uninstall several at once, or remove Homebrew formulae nothing needs any more.
- **Drivers & Extensions** lists system extensions, kernel extensions, audio drivers and plug-ins, camera and printer drivers, input methods, Quick Look and Spotlight plug-ins, settings panes, screen savers, fonts, services and installer packages.
- **System Data** shows Time Machine's local snapshots, which you can delete, and what macOS downloaded for Apple Intelligence, dictation, voices and updates, with the setting that removes each.
- Everything that is part of macOS is marked and locked, so it can't be removed by mistake.
- Spare never moves anything a running app has open. Moving such folders kept the app writing into the Trash, which Finder then couldn't empty. Items in use are shown as in use, and macOS's own service caches are no longer offered.
- Remove in background items works; one confirmation asks for an administrator password once for everything selected.
- Settings is now the last page in the sidebar, inside the main window.
- Leftovers no longer list command-line tool caches or recent files of companies whose other apps are installed, and Watchman is no longer credited to GitHub Desktop.
