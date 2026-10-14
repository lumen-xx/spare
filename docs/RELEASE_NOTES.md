# Spare 0.5.1

- **Uninstall waits until Spare knows what it changed.** Opened straight from the Apps page, it could show “nothing to undo” and uninstall before the list was ready.
- **Undo leaves your own choices alone.** It only offers changes of Spare's that are still in place. A setting you changed back yourself in System Settings stays as you set it.
- **Deleting a privacy permission macOS refuses to change** now says so and tells you where to remove it, rather than only that it's still there.
- Finder switches show the right state for settings once made with `defaults write … YES`, and update when you come back to Spare.
- Removing an audio driver always asks first, as sound stops for a moment, calls too.
- The sidebar no longer fades over the first page when you're at the top, and the arrow keys keep working after you fold the section you're in.
