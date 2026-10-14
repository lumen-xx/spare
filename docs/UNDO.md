# Undoing what Spare changed

Everything Spare changes under **Privacy & Debloat**, and in **Settings › Finder**, can be undone, with Spare or by hand. Files Spare moved to the Trash are a different matter: put them back with **History** or from the Trash.

## With Spare

- **One setting:** switch it back on, on its page, and click **Apply**. Spare puts back exactly the value you had before, which it keeps in `~/Library/Application Support/Spare/Debloat.json`.
- **Several at once:** **Settings › Undo and Uninstall › Undo…** lists everything Spare changed: the “Spare Privacy” profile, each other setting, and each blocked Apple app. Tick what to put back.
- **The profile on its own:** **Remove Profile…** at the top of the Apple Intelligence and Data Sharing pages, or on **Profiles**.
- **Finder settings:** switch them back in **Settings › Finder**. Switching one back to how macOS has it removes Spare's value, so nothing stays behind.

The Dock is never part of an undo: icons you took out stay out. Put one back on **Apple Apps**, or drag it from Applications into the Dock.

## By hand, without Spare

### The “Spare Privacy” profile

Most settings are kept off by one configuration profile, “Spare Privacy”. Removing it switches all of those back on at once.

- **System Settings › General › Device Management**: select “Spare Privacy” and click **−**.
- Or in Terminal: `sudo profiles remove -identifier com.opyuii.spare.debloat`

Apple Intelligence's models download again by themselves once the profile is gone and Apple Intelligence is on.

### Each setting

`defaults delete` puts back **macOS's default**. If you had changed a setting yourself before Spare did, Spare's own undo is the only way back to exactly your value.

### Apple Intelligence

| Setting | How to undo it by hand |
|---|---|
| Siri | Remove the “Spare Privacy” profile |
| ChatGPT and other AI extensions | Remove the “Spare Privacy” profile |
| Writing Tools | Remove the “Spare Privacy” profile |
| Genmoji | Remove the “Spare Privacy” profile |
| Image Playground | Remove the “Spare Privacy” profile |
| Mail summaries and smart replies | Remove the “Spare Privacy” profile |
| Notification summaries | Remove the “Spare Privacy” profile |
| Messages summaries | Remove the “Spare Privacy” profile |
| Safari summaries | Remove the “Spare Privacy” profile |
| Notes transcription summaries | Remove the “Spare Privacy” profile |
| Inline text predictions | Remove the “Spare Privacy” profile |
| Spatial Photos | Remove the “Spare Privacy” profile |
| Photos Clean Up | Remove the “Spare Privacy” profile |
| Xcode predictive code completion | Remove the “Spare Privacy” profile |

### Data Sharing

| Setting | How to undo it by hand |
|---|---|
| Mac Analytics | Remove the “Spare Privacy” profile |
| Personalised ads | Remove the “Spare Privacy” profile |
| Improve Siri and Dictation | Remove the “Spare Privacy” profile |
| Improve Search | Remove the “Spare Privacy” profile |
| Spotlight internet results | Remove the “Spare Privacy” profile |
| Look Up suggestions | Remove the “Spare Privacy” profile |
| Safari search suggestions | Remove the “Spare Privacy” profile |
| Game Center | Remove the “Spare Privacy” profile |

### Apple Apps

| Setting | How to undo it by hand |
|---|---|
| Apple Music in the Music app | Remove the “Spare Privacy” profile |
| The Book Store | Remove the “Spare Privacy” profile |
| Play keys opening Music | `launchctl enable gui/$(id -u)/com.apple.rcd`<br>then log out and back in |

### Annoyances

| Setting | How to undo it by hand |
|---|---|
| Clicking the wallpaper hides every window | `defaults delete com.apple.WindowManager EnableStandardClickToShowDesktop` |
| Widgets on the desktop | `defaults delete com.apple.WindowManager StandardHideWidgets`<br>`defaults delete com.apple.WindowManager StageManagerHideWidgets` |
| iPhone Mirroring | Remove the “Spare Privacy” profile |
| Recent apps in the Dock | `defaults delete com.apple.dock show-recents`<br>then `killall Dock` |
| .DS_Store files on network drives | `defaults delete com.apple.desktopservices DSDontWriteNetworkStores` |
| Saving new documents to iCloud | `defaults delete -g NSDocumentSaveNewDocumentsToCloud` |

### Blocked Apple apps

A block lasts until the next macOS update replaces the app. To lift every block now:

```bash
launchctl print-disabled gui/$(id -u) | awk -F'"' '/"application\.com\.apple\..*=> disabled/ {print $2}' | while read job; do launchctl enable "gui/$(id -u)/$job"; done
```

### Finder

Then run `killall Finder` so it takes the change in; its windows come back.

| Setting | How to undo it by hand |
|---|---|
| Path bar | `defaults delete com.apple.finder ShowPathbar` |
| Status bar | `defaults delete com.apple.finder ShowStatusBar` |
| Full path in the title | `defaults delete com.apple.finder _FXShowPosixPathInTitle` |
| All filename extensions | `defaults delete -g AppleShowAllExtensions` |
| Hidden files | `defaults delete com.apple.finder AppleShowAllFiles` |
| Folders on top | `defaults delete com.apple.finder _FXSortFoldersFirst` |
| Folders on top on the Desktop | `defaults delete com.apple.finder _FXSortFoldersFirstOnDesktop` |
| Search the folder you're in | `defaults delete com.apple.finder FXDefaultSearchScope` |
| Ask before changing an extension | `defaults delete com.apple.finder FXEnableExtensionChangeWarning` |
| Empty old Trash items | `defaults delete com.apple.finder FXRemoveOldTrashItems` |
| No .DS_Store files on USB drives | `defaults delete com.apple.desktopservices DSDontWriteUSBStores` |
| External disks on the Desktop | `defaults delete com.apple.finder ShowExternalHardDrivesOnDesktop` |
| Library folder | `chflags hidden ~/Library` |
| New folders open as | `defaults delete com.apple.finder FXPreferredViewStyle` |

## What can't be undone

Deleted hidden accounts, removed printers and reset privacy permissions aren't files, so there's nothing to put back: an app asks for a permission again the next time it needs it. Spare says so before any of these run.

## Uninstalling Spare

**Settings › Undo and Uninstall › Uninstall…** first lists what Spare changed, to tick what to put back. Spare then undoes those, moves itself and its files to the Trash, and quits. What you leave unticked stays as it is; it can still be undone by hand as above.

By hand: quit Spare, undo what you want as above, then move these to the Trash:

- `/Applications/Spare.app`
- `~/Library/Application Support/Spare`
- `~/Library/Caches/com.opyuii.spare`
- `~/Library/Preferences/com.opyuii.spare.plist`
- `~/Library/HTTPStorages/com.opyuii.spare` and `~/Library/Saved Application State/com.opyuii.spare.savedState`, if they're there

Spare has no background process or login item, so nothing else is left running.
