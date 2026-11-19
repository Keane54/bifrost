# The stores: behaviour

Bifrost keeps its settings and state in a few JSON files in its support folder. This page covers
how it reads and writes them: the safe write that every store shares, what a store does with a
file it can't fully use, and the rules of each file. The Electron app was a reference for
behaviour only (user rule, 2026-11-16), and the places where the native app differs from it on
purpose are listed in `docs/ports/stores/DELIBERATE-DIFFERENCES.md`.

The shared file code is in `BifrostFoundation/Services` (`JSONFile`, `FileSaver` and `StoreLog`),
and each store lives with its module: `SettingsStore` and `Settings` in `BifrostSettings`,
`UIStateStore` and `UIState` in `BifrostLayout`, and `WindowStateStore` and `WindowState` in
`BifrostWindows`. The registry's own file, `registry.json`, has its rules in
`docs/behaviour/registry.md`.

## The safe write

Every store writes its file the same way, so a crash or a power cut never leaves half a file
behind.

- A write goes to a temporary file in the same folder, named with a new UUID and ending in `.tmp`,
  and opened with `O_EXCL` so that it can never take over a file that's already there. The write
  syncs that file with `F_FULLFSYNC` (falling back to `F_BARRIERFSYNC`, then `fsync`) and then
  renames it over the real file, which gets the mode 0600. If any step fails, the temporary file
  is removed and the old file stays as it was.
- The text uses two spaces of indent, sorted keys, `/` left unescaped and a final newline.
- The UI state store and the window state store each have one save task (`SaveQueue`), which
  writes the newest state off the main actor, one write at a time. A state that's waiting while a
  write runs gives its place to any newer state, so the file always ends up with the newest one.
- Opening a store decodes the file once, and a save encodes the value once.
- The stores log to the macOS unified log under the category `stores`: a read error, a kept copy,
  a failed copy, a refused value, a failed write of the UI or window state, and the settings keys
  that fell back to their defaults. Paths and error texts are kept private in the log.

## Loading a file

These rules decide what a store does with a file that's missing or that it can't fully use. The
aim is that Bifrost always starts, and never writes over data it didn't manage to read.

- A missing file, or a file whose values the store can't use, gives the defaults, and saving
  works as normal.
- A file that doesn't parse at all is copied to `<file>.unreadable` once, just before the first
  save over it. If the copy fails, the store turns saving off and the old file stays. A file
  doesn't parse when the JSON parser refuses it, or when a raw value or an unknown field holds a
  value with no JSON form (a number that `Double` can't hold, or a lone surrogate), also in a file
  of another version, and the decode then throws `NoJSONForm`. The same kind of value in a typed
  field is just a bad value, so that field gets its default, as in the Electron app.
- A read error, such as a folder at the path or no permission, gives the defaults and turns saving
  off, so the store never writes over a file it didn't read.
- Each stored type keeps the unknown top-level fields of its file and writes them back when it
  saves, so a file from a newer app loses nothing. A known key never counts as an unknown field.
- A bad field gets its default, and the other fields stay.

## settings.json

The settings file holds every preference the user can change. Bifrost checks each change as a
whole before it writes anything, so the file only ever holds valid settings.

The version is the whole number 1, and any other version gives the defaults. A file of a later
version is copied to `settings.v<version>.backup.json` once, before the first write over it. The
name shows the version as a whole number with no `.0`, or as the decimal text of the number when
it isn't a whole number.

The settings with a range or a set of choices:

| Setting | Allowed values | Default |
| --- | --- | --- |
| Poll | 1, 2, 3, 5 or 10 s | 2 s |
| Panel transparency | 0 to 50 %, in steps of 5 | 15 % |
| Interface scale | 80 to 150 %, in steps of 10 | 100 % |
| Escalation | 0 to 120 minutes (0 turns it off) | 10 minutes |
| Snap distance | 0 to 32 units | 8 units |
| Terminal font size | 9 to 24 | 13 |
| Reviews: sessions at once | 1 to 10 | 3 |
| Reviews: pause | 15, 30, 60, 120, 240 or 480 minutes | 60 minutes |
| Reviews: poll | 1, 2, 5 or 10 minutes | 2 minutes |

The text settings have their own rules:

- Slash commands: at most 12, each one only once. A command starts with `/`, the character after
  it isn't white space, it has no CR or LF (these checks look at Unicode scalars), and it has at
  most 200 characters. The first bad command refuses the edit.
- The terminal font family has 1 to 64 characters, none of `" ' \ ; { } < >` and no control
  character. The size and the family are checked separately.
- Text values are trimmed. White space means `Character.isWhitespace` (the Unicode White_Space
  property), so NEL counts as white space and U+FEFF doesn't. The trim removes whole
  `Character`s, so a combining mark on a space at either end goes with it.
- The Reviews ignore list holds at most 50 entries of the form `owner/repo` or `owner/*`, in lower
  case and each only once. The owner is 1 to 39 ASCII characters and starts with a letter or a
  digit, and the repo is `*` or 1 to 100 ASCII characters.
- Every length limit counts `Character`s, so an emoji counts as one.

Two settings pick the apps of Open project and Open in terminal, which
`docs/behaviour/actions.md` describes. The rules are in `Settings.swift`.

- The terminal app is Warp, Ghostty, iTerm2 or Terminal, or Automatic (no value), which means the
  first installed one of that list. The same list, in the same order, is the order in which Open
  in terminal looks for a terminal app.
- The project app is the default app of Open project, which the Open project key uses. Its
  Settings select offers the installed apps without Finder. A saved Finder, which an older file
  can hold, still loads and shows as Automatic.
- The default app is never Finder. It's the saved app when that's installed, then VS Code, then
  Zed, then the first terminal app of the installed list, and with none of them there's no
  default.

Every change to the settings is an edit, a closure that changes them, for example
`try await store.edit { $0.rowFlash = false }`.

- The store checks the result as a whole (`Settings.validated()`). The first bad field refuses
  the edit with its reason (`.refused(SettingsRefusal)`), and the settings stay as they were. The
  check also gives back the clean form of the text values, trimmed and with the ignore entries in
  lower case. An edit that changes nothing writes nothing.
- A good edit writes the file first and then updates the settings. A failed write throws
  `.notSaved` with the error of the write (`FileError`) and keeps the old settings. When saving is
  off, the settings change but nothing is written.
- Edits run one at a time, in the order of the calls, and each runs on the newest settings after
  the earlier ones end, so two quick changes never start from the same old value.
- The app follows the settings through observation (`Observations`), and `waitForWrites` lets the
  quit wait for each edit that's running or waiting.
- `keys` stays as raw JSON, so a save keeps any entry that a later version wrote.
  `Settings.validated()` leaves `keys` alone, so a change of the keys is checked before its edit
  starts, against the keys the store holds. `dailyUpdate` is a typed block that keeps its unknown
  fields (see `daily-update.md`), and `validated()` checks its limits.
- A key edit names the slots it changes, each with a binding or `null` for Off (`KeyEdit`). Each
  name has to be a slot that Bifrost knows, and each value has to be a binding that the slot can
  take, under the same rules as loading the file. The edit is also refused when it gives two
  actions of one class the same key, with "Two actions can't share the same key." A conflict
  that's already in the file can stay, so an edit of another slot, or of the same two slots with
  the same key, still saves. The edit changes only the slots it names, and an edit that gives
  each slot the key it already has writes nothing. The key recorder of Settings > Keys checks its
  key the same way before it saves (`docs/behaviour/keys.md`, "Changing a key").
- Decoding the file (`StoredSettings`) gives the settings, the sorted list of keys whose stored
  values fell back to their defaults (the load logs them on one line), and the version of a file
  of a later app. A list that lost an item, or a font with a bad part, is on that list too. A file
  that the Electron app or an older build wrote loads the same, and a save of the same settings
  writes the same bytes.

## ui-state.json

This file remembers the canvas: the current layout, the layouts the user has saved by name, the
config of each Overview, the history of the New session dialog, and a raw value that a later
panel will use.

- It holds the current layout, at most 20 named layouts, the Overview configs (`overviews`), the
  dialog history (`history`) and the raw state of the Performance panel (`performance`). The
  configs and the history follow their own rules, which `docs/behaviour/windows.md` describes. A
  version other than the whole number 1 gives the empty state, but its unknown fields are kept.
- A layout name is trimmed and has 1 to 40 characters. Saving under a name that's already there
  puts the new snapshot in that layout's place, and a new name goes at the end. A 21st new name is
  refused because the list is full. Two names are the same when they're equal Swift strings, so
  two forms of one accented letter are one name, and a load keeps the first of them.
- On load, a bad item goes and the others stay: a repeated layout name, a frame with no good
  panel ID, or a rect that isn't finite or has no size. An active panel that isn't one of its
  frame's panels gives way to the first panel. `locked` and `minimised` are only true when the
  file says `true`.
- A state of more than 1,000,000 bytes of compact JSON is refused and logged, and nothing is
  written. The check counts the compact size of the text about to be written, so the state isn't
  encoded twice.
- The store saves 500 ms after the last change, and holds its saves during a drag. When the
  window closes and when the app quits, `saveNow` saves any change at once and waits for the
  write.
- A file that an older build wrote loads the same, and a save of the same state writes the same
  bytes.

## window-state.json

This file remembers how the main window was last shown: its display mode and the bounds of the
normal window, which means the window when it isn't full screen or borderless.

- Saved bounds smaller than 400 x 300 are dropped. The saved bounds are used only when at least
  100 x 40 points of the top 40 points of the window lie inside one screen's work area, so the
  user can grab the title bar. Otherwise the window opens in the centre at 1440 x 900. The window is
  never smaller than 800 x 500.
- The file's origin is the top-left corner of the primary screen, with y going down, as in the
  Electron app. The shell converts the AppKit frames to and from this form, and it waits 500 ms
  after the last move or resize before it saves.

A few Electron pieces had no place in a single native process and weren't carried over: the store
of the main process, the IPC reads of the page, the IPC patch type (`Partial<Settings>`) and the
change listeners of the settings. A store on the main actor, the edit closure and the observed
settings do those jobs instead.
