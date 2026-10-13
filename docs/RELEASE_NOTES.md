# Spare 0.2.2

- **Empty Trash works when Finder won't.** With Full Disk Access, Spare empties the Trash itself, item by item: locked files and read-only folders are unlocked first, items owned by the system are deleted after one password prompt, and anything left is named. Finder gives up on the first item it can't handle and only says "The operation can't be completed".
- **Messages leave after two seconds**, but stay while the pointer is on them, so Undo stays in reach. Failures show a warning instead of a tick.
