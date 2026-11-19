# Settings: behaviour

Settings is the panel where you change how Bifrost works. This page covers how the panel is laid
out, how its search finds a setting, how your changes are saved, and how the list of slash
commands is edited. The Electron app is a reference for behaviour only (user rule, 2026-11-16), and
the places where the native app differs from it on purpose are listed in
`docs/ports/settings/DELIBERATE-DIFFERENCES.md`. What the settings file holds, and the checks each
value has to pass before it's written, are in the settings.json part of `docs/behaviour/stores.md`.

The rules on this page live in `BifrostSettings/Model`: the sections (`SettingsSection`), the row
labels (`SettingsRows.swift`), the search (`SettingsSearch`), the save tracker and the draft rule
(`SaveTracker.swift`), the slash list edits (`SlashList`) and the effects of a change
(`SettingsEffects`). The panel that uses them is in `BifrostSettings/UI`, where `SettingsModel`
holds the current tab, the search and the saves, `SettingsPanel` draws the panel with the shared
rows of `SettingsRowViews.swift`, `GeneralSection`, `SlashSection`, `KeysSection`, `LiveSection`
and `SkillsSection` draw their sections, `LiveModel` holds the state of Live details and the
skills, and `SettingsPanels` gives the canvas its body. The shell makes the panel's model once
the settings store opens, and hands it its links to the window and the services at that point
(`SettingsLinks`, built by `Shell.settingsLinks`). The login
item behind Start at login is in `BifrostSettings/Services` (`LoginItem.swift`). The rules of
the key editor belong with the other key rules, in `BifrostKeyboard/Model` (`KeyEditor.swift`
and `KeyRecording.swift`).

## The panel

You open Settings with the gear button at the bottom of the side bar, with Cmd+, or with Esc,
which opens Settings when it isn't the front panel and closes it when it is (the Esc rule in
`docs/behaviour/keys.md`). If Settings is already open behind another frame, or minimised, each of
these brings it to the front instead of opening a second one. The panel keeps the tab you last
used, even after you close it.

From top to bottom the panel has the search field, a row of tabs, the current section in a
scrolling area, and a footer with the Save button.

Clicking a part of the panel that has no control gives the focus to the panel itself, so Cmd+F
still reaches the search. A change can also take away the field you're typing in, for example when
a search or a switch to another tab hides its row. The focus then doesn't drop to the window: it
moves to the search field while a search is on, and to the panel otherwise (`SettingsHost`). Tab
never stops on the panel itself.

While the panel itself has the focus, it counts as a control for the shortcuts (the Control zone in
`docs/behaviour/keys.md`). Enter, Space, Tab, the arrows, Home, End and the hold keys don't act
there, while the other single-key shortcuts, such as a single letter, still do, and so do the Cmd
shortcuts, Cmd+F included.

## The sections

Settings has nine sections, shown as tabs in this order:

| Tab | What it holds |
| --- | --- |
| General | The settings that apply to the whole app, listed below |
| Slash commands | Your favourite slash commands, which show in the Slash commands menu of a session |
| Keys | The key editor, with a row for every shortcut |
| Reviews | Watching the code host for review requests and fixing review comments |
| Daily update | The daily update reminder and the drafts Claude writes for each channel |
| Live details | The Claude Code plugin that sends Bifrost its live session details |
| Skills | The Bifrost skills plugin |
| Modules | The installed modules |
| Updates | Automatic updates of Bifrost |

Every section works except Modules, which keeps its tab and shows "This section comes in a later
build of Bifrost Dev." until the module system arrives (see "Still to come" at the end of this
page), so every section is already where you'd expect it to be. This page covers General, Slash
commands and Keys in full, and the other sections have their own pages: Reviews in
`docs/behaviour/reviews.md` ("Settings > Reviews"), the Daily update in
`docs/behaviour/daily-update.md` ("Settings > Daily update"), Live details and Skills in
`docs/behaviour/live.md` and `docs/behaviour/skills.md` ("Settings > Live details" and "Settings >
Skills"), and Updates in `docs/behaviour/updates.md` ("Settings > Updates"). While Live
details or Claude Code needs your attention, the Live details tab shows a small white square after
its title, the same dot as the Settings gear of the side bar ("The warning dot" in `live.md`).

The General section has these rows, in this order. The label is the one thing that names a row:
it's what the row shows and what the search looks for, and `GeneralRow` holds each one exactly as
it appears.

| Row | Label | Control |
| --- | --- | --- |
| 1 | Labels | Plain or Space, as two choice buttons |
| 2 | Terminal app | A menu: "Automatic (first installed: Warp, Ghostty, iTerm2, Terminal)", then each installed terminal app |
| 3 | Default app for "Open project" | A menu: "Automatic (VS Code, else Zed, else your terminal app)", then each installed app except Finder |
| 4 | Escalation time | Minutes from 0 to 120, where 0 turns escalation off |
| 5 | Row flash | A check box |
| 6 | macOS notification | A check box |
| 7 | Sound for a red box | A check box |
| 8 | Start at login | A check box |
| 9 | Account usage from Anthropic | A check box, with the hint "Shows usage from all your devices. Bifrost reads your Claude Code login from the Keychain. macOS may ask you to allow this." |
| 10 | Poll interval | A menu: 1, 2, 3, 5 or 10 seconds |
| 11 | Snap distance | Pixels from 0 to 32 |
| 12 | Panel transparency | A menu from "0% (solid)" to 50%, in steps of 5 |
| 13 | Animated background | A check box, with the hint "Slowly shifting colours behind the panels. Turn it off to save battery." |
| 14 | Interface scale | A menu from 80% to 150%, in steps of 10 |
| 15 | Terminal font | The family as a text field with a menu of common families beside it, and the size in points from 9 to 24 |
| 16 | Display mode | Window, Borderless or Fullscreen, as three choice buttons |
| 17 | Introduction | A "Show introduction" button that opens the Setup dialog again ("The Setup dialog" in `docs/behaviour/live.md`) |

A few rows need more than their control to explain them:

- The two app menus only list apps that are installed on this Mac. Bifrost looks for them when
  General opens, and again whenever you change the Terminal app, because the list for "Open
  project" ends with the chosen terminal app. A saved app that isn't installed any more stays in
  its menu with "(not installed)" after its name, such as "Ghostty (not installed)".
- Finder is never a choice for "Open project". A settings file that still names Finder, from an
  older version, shows Automatic.
- The font menu offers SF Mono, Menlo, Monaco and Courier New, and a family you pick there saves
  straight away. A typed family is trimmed and checked first, and a bad one gets "Use 1 to 64
  characters, without quotes or ; { } < >."
- Display mode isn't a setting, because the window keeps its own mode in window-state.json. The row
  shows the window's mode and follows a change from the View menu, the Fullscreen key or the green
  button. Picking a mode in the row changes the window the same way the View menu does.
- When a change of the login item fails, the reason stays under the Start at login row until a
  later change works (see "Start at login" below). If macOS is waiting for your approval, the row
  also has an "Open System Settings" button, which opens Login Items & Extensions.

Below the last row, General shows the version of the app, such as "Bifrost 0.0.1"
(`SettingsModel.appVersion`, from the app's bundle). Above the first row, a notice shows when
Claude Code is older than the version Bifrost needs, or when Bifrost can't find it
(`SettingsModel.versionNotice`, which the shell takes from the version check of the live model).
Neither shows while a search is on.

## The search

The search field sits above the tabs. While it's empty, or holds only spaces, you see the tabs and
the current section. As soon as you type a word, the results replace the tabs: every section with
a match, in the order of the tabs, each under its title and showing only the rows that matched.

### What the search looks at

Each section offers the search a set of rows, and each row has a text:

- A General row is found by its label only. The hint under a row and the choices of a menu aren't
  searched, so "Automatic" doesn't find the Terminal app row.
- A slash command is found by the command itself, such as `/compact`.
- A Keys row is found by the name of its action, such as "Take control", or by its key.
- Live details and Skills are each one row made of their words: the title, the state line, the
  button labels and, for Skills, the name of each skill. So "hand-over" finds the Skills section.

A section with no rows isn't searched at all. That's how a section that still shows the later-build
text stays out of the results, even when you type its title, and it's also true of Live details
or Skills before they have any words. The one exception is Slash commands with an empty list: its
title still finds it, because that's where you'd go to add your first command.

### How a word matches

The query is split into words at white space, and each word has to appear somewhere in the text,
ignoring case and in any order. A word can be part of a longer word, so "open proj" finds
`Default app for "Open project"`, while "flash sound" finds nothing, because "Row flash" has no
"sound" in it.

When the query matches a section's title, as "slash" matches "Slash commands", the whole section
shows with all its rows.

### Finding a key

In Keys you can also search by the key itself, the way the list shows it (`⇧ ⌘ T`, or `⌘⇧T` with
no spaces) or the way you'd type it (`cmd shift t`, `cmd+shift+t`, `Command + Shift + T`). Each part
of the query must name a part of the key, in any order. These are the names the search knows:

| Part | Names |
| --- | --- |
| Cmd | ⌘, cmd, command, mod, meta |
| Control | ⌃, ^, ctrl, control |
| Option | ⌥, alt, opt, option |
| Shift | ⇧, shift |
| ↑ ↓ ← → | the arrow symbol, up, down, left, right, arrowup, arrowdown, arrowleft, arrowright |
| Backspace | ⌫, backspace, delete |
| Delete | ⌦, delete, del, forwarddelete |
| Enter | ↵, ↩, enter, return |
| Escape | ⎋, esc, escape |
| Tab | ⇥, tab |
| Space | ␣, space |
| Home and End | ↖, home and ↘, end |
| Page Up and Page Down | ⇞, pageup, pgup and ⇟, pagedown, pgdn |
| Any other key | its own name in lower case, such as t, 1, `,` or f5 |

The caret `^` counts as Control, because the list's ⌃ looks just like it. The symbols can be
written with no space between them, and `+` works as a space.

A part of one character must be a whole name, so "t" only means the key T and "cmd shift t" doesn't
find Cmd+Shift+Tab. A longer part only needs to be the start of a name, so "sh" means Shift and
"cmd shift ta" does find Cmd+Shift+Tab. A row whose key is Off is never found by a key.

You can mix the kinds of words too. Each part of the query can match the section's title, the row's
label or a part of its key, so "keys take" and "take cmd" both find Take control. In a mixed query
a one-character part still has to be a key name, which keeps "cmd shift t" an exact key search.

### Counts, Esc and Cmd+F

- For a screen reader, a hidden line announces the number of matching rows: "1 setting matches."
  or "3 settings match.". With no match it reads the same line the panel shows, such as
  `No settings match "xyz".`, with the query trimmed. With no search the line is empty.
- Esc in the search field clears the query. Esc in an empty field closes Settings, just as Esc does
  outside a text field. While an input method is composing text, Esc only cancels the composition
  and does neither.
- Cmd+F moves the focus to the search field while the focus is in Settings, or while nothing has
  the focus and Settings is the front panel. The caret goes to the end of the search text, and a
  search field you're already typing in keeps its selection. Only Cmd+F with no other modifier
  counts, and it matches the way every Bifrost shortcut does (`docs/behaviour/keys.md`): on a
  Russian or Greek layout the F key still works, while on Dvorak it's the key that types F. A key
  pressed while an input method is composing text isn't Cmd+F. If you've given Cmd+F to one of
  Bifrost's own shortcuts, that shortcut wins and the search field doesn't take the focus.

## Saving

Every change in Settings saves straight away through the settings store. If a change is refused
or can't be written, its row shows the reason, and the error stays until you close it or a later
save of that row works.

The Save button at the bottom first ends the edit of the field you're typing in, so that text saves
just as if you'd clicked away. Then it waits until every save has finished, and only then closes
Settings. If any row still has a failed save, Settings stays open so you can see the error. Only one
Save runs at a time: while it waits, the button, the tabs, the search field and the other text
fields are off, so nothing you type can slip in after Save has looked at the fields, and no row can
disappear before its save comes back. The rules behind it (`SaveTracker`, driven by
`SettingsModel`):

- The last save a row started decides the state of that row, whatever order the results come back
  in. A good save of one row never clears the error of another.
- Save waits for every save that's running, including one that starts while it waits.
- Closing a row's error clears its failure, but a save of that row that's still running still
  counts when it ends.
- When a row goes away, because the search hides it, you switch to another tab or you close
  Settings, its failure and its error go with it, and the results of its saves that are still
  running no longer count. Save still waits for them to finish.

Some fields hold a draft: text you've typed that only saves on demand, such as a new slash command.
Before Save waits, it saves each draft that has text in it, in the order the drafts were added. A
draft that saves empties its field before its save counts as finished, so a second Save never adds
the same command twice. A draft that you've just sent with Enter is still saving, so Save waits for
that save instead of starting another, and if it fails the draft goes back to Save. A draft with
nothing but spaces has nothing to save. If a draft is refused, Settings stays open while that text
is still there. Typing in the field clears the reason, and clearing the field is enough to let Save
close Settings. A draft lives only while its field shows: switching to another tab, or a search that
hides the field, throws the text away.

Other text fields save when you leave them or press Enter, such as the terminal font family, and
Esc puts back the saved value. The text is trimmed first. If the trimmed text is the value that's
already saved, nothing is saved and the field shows the saved value again. An empty field still
tries to save, so that you see why it's refused (`DraftRule`). A number field refuses text that
isn't a whole number in the range of its row before anything saves, with "Enter a whole number
from 0 to 32." or the range of that row.

## When a setting changes

Most settings need nothing more than the save to take effect. The window applies its look, the
Interface scale, the snap distance, the panel transparency, the animated background and the
terminal font of the chats included, every time the settings change, and the Overviews take Row
flash at the same time. The registry follows the escalation time and the poll interval on its
own, and the names of the session actions follow Labels because they're read from the settings
each time they're shown. A few settings reach further, into macOS or into a part of
the app that has to start, stop or rebuild something, and that work is the effect of the change
(`SettingsEffects`). Bifrost compares the settings before and after each change and runs one effect
for each of these settings that changed, always in this order:

| Order | Setting | Effect |
| --- | --- | --- |
| 1 | Start at login | The login item is registered or removed, as described below |
| 2 | The key of Close Panel or Fullscreen | The menu is built again, so it shows the new key |
| 3 | Interface scale | Nothing more: the window already applies the new scale with the rest of its look |
| 4 | Account usage from Anthropic | The account usage poll starts or stops |
| 5 | Watch GitHub | The Reviews watcher starts or stops |
| 6 | Show team requests, or Repositories to ignore | The Reviews rows are built again |
| 7 | GitHub poll interval | The next Reviews poll is planned with the new interval |
| 8 | Handle comments on my PRs automatically | The automatic handling turns on or off |
| 9 | Check for updates automatically | The updater's automatic checks and downloads turn on or off |

Only the keys of Close Panel and Fullscreen rebuild the menu, because they're the only keys the
menu shows. Every other key change goes straight to the key handling of the window. A key that's
stored but reads the same as before, such as a slot set to its own default, changes nothing.

Opening the settings when Bifrost starts runs no effects, since nothing has changed yet. Instead,
the menu takes the stored keys and the updater takes Check for updates automatically as the
settings open. A development build never starts the updater, so there the updates effect does
nothing.

If one effect fails, the ones after it still run, and the setting itself stays saved. Only the
login item effect can fail, and what happens then is described below.

## Start at login

Start at login asks macOS to open Bifrost when you log in, through the app's login item
(`SystemLoginItem`, which uses `SMAppService.mainApp`). Only the release app, running on your real
home, ever has a login item (`LoginItemRule`). In Bifrost Dev, and in any app started with a test
home, the switch saves your choice and registers nothing, so a development build never opens at
login.

You can also add or remove the login item in System Settings while Bifrost isn't running, which
leaves the settings file out of date. So each time the release app starts, it reads the real state
of its login item, and if the file disagrees, the real state wins and is saved
(`SettingsEffects.loginItemFix`).

A login item that you haven't allowed in System Settings yet counts as off, because macOS won't
open the app. Turning the switch on again in that state doesn't register anything new and gives
the reason instead, while turning it off removes the waiting login item.

When macOS can't change the login item, the switch keeps your choice and the reason goes to the
log. The services also hold on to it (`AppServices.loginItemProblem`), and Settings > General shows
its text under the Start at login row. It goes when a later change of the login item works, or
when the login item's real state agrees with the switch again: Bifrost reads that state each time
you open Settings and each time the app becomes active (`AppServices.readLoginItemAgain`), so
allowing the login item in System Settings clears the note without another click. That read only
clears the note: while Bifrost runs it never changes the switch or the settings file, and the next
start brings the file in line with the real state. The reason is one of these (`LoginItemError`):

| Reason | Text |
| --- | --- |
| The login item waits for your approval in System Settings | To open Bifrost at login, allow it in System Settings > General > Login Items & Extensions. |
| macOS can't find the app | macOS can't find this copy of Bifrost, so it can't open it at login. Move Bifrost to your Applications folder, open it from there, and try again. |
| Any other failure | Bifrost couldn't change its login item. Try again, or set it in System Settings > General > Login Items & Extensions. |

## The slash list

Slash commands is a short list that you can add to, reorder and remove from (`SlashList`), and it
holds the commands that show in the Slash commands menu of a session. The section opens with a
line that says so, then lists the commands in order, with "No commands yet." when the list is
empty, and ends with a field for a new command (`SlashSection`).

- You type a new command into the "New slash command" field and press Enter or click Add. It's
  trimmed and goes to the end of the list. Bifrost checks the command first (the rules are in
  `docs/behaviour/stores.md`), then whether it's already in the list, then whether the list is
  full, and shows the first reason that applies under the field. The field keeps your text so you
  can fix it, and typing clears the reason. Enter or Add with an empty field does nothing, and Add
  is off once the list has 12 commands.
- The field is a draft, so Save adds a command you've typed but not added yet, as described in
  "Saving" above.
- Each command has Move up, Move down and Remove. Moving the first command up, or the last one down,
  leaves the list as it is. If one of these saves fails, its reason shows under the list, apart
  from the reason under the field, so a good move never hides why a new command was refused.
- During a search the section only shows the commands that match. The line at the top, the empty
  line and the field come back when the search ends or matches the section's title.

| Refused because | Reason shown |
| --- | --- |
| It doesn't start with `/` and a character that isn't white space | Start the command with "/", with no space after it. |
| It has a line break | Keep the command on one line. |
| It's longer than 200 characters | That's too long. The limit is 200 characters. |
| It's already in the list | That command is already in the list. |
| The list already has 12 commands | You can keep up to 12 commands. |

## Keys

Keys lists every shortcut under its group (`KeysSection`). Each row shows the name of the action,
a small mark if you've changed its key, and the key itself, or "No key" when it's off. A key shows
its modifier symbols in the order the macOS menus use, then the key, with a space between the
parts, such as `⇧ ⌘ T`. Beside it are three buttons: Change records a new key,
Clear turns the shortcut off, and Reset puts back its default.

You change a key by recording it: Change starts the key recorder on that row and you press the new
shortcut. The recorder gets every key while it records, menu keys included, and Esc stops it
without a change. A key that Bifrost refuses shows its reason on the row while the recording
carries on, and a good key saves at once. Reset all keys, at the top of the section, asks first
with "This puts every key back to its Bifrost default." and then puts every shortcut back to its
default, while keeping any keys that a later version of Bifrost saved. The question is Bifrost's
in-window confirm dialog, the one the session actions use. While Save runs, Change and Reset all
keys are off, and while a dialog is open, Save is off, so nothing can start a save after Settings
has closed. Clear and Reset stay on, since Save waits for their saves.

If a key fails to save, the reason shows on the row of that key. It moves to the top of the section
when a search hides that row, and that's also where the reason of a failed Reset all keys shows, so
Save never keeps Settings open with no error in sight. The full rules, with each reason, are in
"Changing a key" in `docs/behaviour/keys.md`.

## Still to come

Only the Modules section is still to come. It arrives with the module system in phase 7, and
until then its tab shows "This section comes in a later build of Bifrost Dev." in place of its
rows.
