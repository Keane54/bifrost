# Keys: behaviour

This page covers Bifrost's keyboard shortcuts: which shortcuts exist, how you change them, how a
key you press is matched to a shortcut, and where in the window each shortcut is allowed to act.
The Electron app is a reference for behaviour only (user rule, 2026-11-16), and the places where
the native app differs from it on purpose are listed in
`docs/ports/keys/DELIBERATE-DIFFERENCES.md`. For a picture of how one key travels through the app,
see the [keyboard input explainer](../explainers/keyboard-input.html).

The rules live in the `BifrostKeyboard` module. Its `Model` folder holds the shortcuts, the
matching, the focus zones and the rules of the key editor in Settings, and its `UI` folder turns
AppKit events into key events (`KeyEvents.swift`) and reads where the focus is
(`FocusTargets.swift`). The window side is in `BifrostWindows/UI`: the window key filter
(`WindowKeyFilter`), the commands each shortcut runs (`KeyCommands`) and the main menu. The key
recorder of Settings > Keys is `BifrostSettings/UI/KeyRecorderView.swift`, and the dictation hold
key belongs to the chat input, in `BifrostDictation/Services/ChatInput.swift`.

## Slots and bindings

Each shortcut that Bifrost knows is called a slot, and each slot has one binding: the key and
modifiers that trigger it, or Off. There are 84 slots in four groups, which are also the sections
of the key editor in Settings:

| Group | Slots | What they are |
| --- | --- | --- |
| Always | 49 | Shortcuts with Cmd that work at all times, such as Cmd+N for a new session or Cmd+. to interrupt |
| Single | 24 | Plain keys, such as O to open or the arrow keys to move between rows, that work outside a chat window or a text box |
| Hold | 10 | Keys you hold while you click a session row, to run an action on that row: O, M, I, J, X and 1 to 5 |
| Dictation | 1 | The key you hold in a chat window to dictate, Space by default |

In settings.json a slot is named by an ID of the form `<command>[.<number>]:<variant>`, for
example `select-row.3:mod`, where the variant is `mod`, `key`, `key2` or `hold`. A binding is
stored as text with `Mod` standing for Cmd, such as `Mod+Shift+M`, and Bifrost always writes the
parts in the order Mod, Control, Alt, Shift, then the key. When it reads a binding it's more
relaxed: modifiers can come in any order and any case (Mod, Cmd, Command and Meta all mean Cmd,
Ctrl means Control, and Option means Alt), named keys can be in any case, and Esc, Return, Up,
Down, Left and Right work as short names. A text with no key, two keys, the same modifier twice or
a part Bifrost doesn't know isn't a binding. The app reads these texts once, when the settings
load, and works with typed slots and chords (`KeySlot`, `Chord`, `KeyMap`) from then on.

You can change any slot or turn it Off. Setting a slot back to its default binding removes its
entry from the file, and Off is stored as `null`. The `keys` value in settings.json stays raw
JSON so that it survives across versions: on load, Bifrost ignores an entry it can't use but keeps
a conflict that's already in the file, and a save rewrites only the slots that changed. An entry
for a slot this version doesn't know, or a binding that a later version wrote, is left alone.

A new binding must first parse as a binding. Bifrost then runs these checks in order and reports
the first one that fails:

| Check, in order | Message when it fails |
| --- | --- |
| The dictation slot needs a plain key that types a character: Space, a letter, a digit or a punctuation key. | "For dictation, use Space, a letter, a number or a symbol, without Cmd, Ctrl, Option or Shift." |
| A hold slot needs a plain letter or digit. | "A hold key must be a single letter or number, without Cmd, Ctrl, Option or Shift." |
| A menu slot (Close Panel or Toggle Fullscreen) needs Cmd. | "A menu shortcut needs Cmd." |
| The binding can't be one that macOS keeps, such as Cmd+Tab, Cmd+Space, Cmd+H, Cmd+M, Cmd+Q or Control+Space. | "macOS keeps this shortcut for itself." |
| The binding can't be one that the Edit menu, the app menu or the View menu's zoom items use, such as Cmd+C, Cmd+Z or Cmd+=. | "A Bifrost menu already uses this shortcut." |
| No other slot of the same class can have the binding. | The other action's name, as in "Event log already uses this key." |

The classes are ordinary shortcuts (the always and single groups together), hold keys and the
dictation key, so the same key can be both a single key and a hold key. If two slots of one class
still end up with the same binding, for example because the file already had one, the slot that
comes first in the standard slot order keeps it.

## Changing a key

Settings > Keys lists every slot under its group, in the order of the table above, with its current
key, or "No key" when it's Off, and a mark on each slot you've changed (`KeyEditor.groups`). A key
shows the symbols of its modifiers in the order the macOS menus use, ⌃ ⌥ ⇧ ⌘, then the key, with a
space between the parts, such as `⇧ ⌘ T` or `⌘ ↑`. The arrows, Enter (↵), Backspace (⌫), Delete (⌦),
Tab (⇥) and Space (␣) are symbols too, Escape is "Esc", and every other key keeps its name, such as
F5 or PageDown (`Chord.shown`). The search of Settings reads the same form, so you can search for a
key exactly as the list shows it.

Each row has Change, Clear and Reset. Clear turns the slot Off, and Reset gives it its default key
again, and both save only that slot. A slot whose saved key this version can't read shows its
default key and isn't marked as changed, so its Reset is off and its entry stays in the file.
To change a key you record it: Change starts the key recorder on that row, under the prompt "Press
the new shortcut. Esc cancels.", and you press the shortcut you want. Change on another row moves
the recorder there and ends the first recording.

While the key recorder records, it gets every key you press before anything else in Bifrost can
act on it. The window gives it each key event and each key equivalent first (`WindowKeyFilter`),
so Cmd+W, Ctrl+Cmd+F and even Cmd+Q are recorded instead of closing a panel, changing the display
mode or quitting, and no Bifrost shortcut runs. The menu bar still shows its keys during the
recording. The recorder isn't a text field, so no input method gets between you and the key.

The recorder saves the key the way the shortcut matching reads it (`Chord(event:)`), so the key you
pressed is the key that runs the shortcut, whatever your keyboard layout. When the key types a
letter, digit or symbol that a binding can name, and that binding matches the key exactly, that's
the key it saves: Cmd+Shift+Y on a German keyboard is Cmd+Shift+Y, Shift+7 there (which types /) is
Shift+/, and Cmd+A on a French one is Cmd+A, which Bifrost then refuses because Select All uses it.
Otherwise it saves the key at that place on a US keyboard, which is how the matching reads a letter
of another script, a dead key, a letter typed with Option or a symbol that no binding can name, such
as the ! of Shift+1. So Option+O is Alt+O, Shift+1 is Shift+1, and the key at the place of F on a
Russian keyboard is F. A key that the matching can't read as any binding, such as Ö on a German
keyboard with no modifier, is refused. The dictation key is the one exception: the chat input finds
it by its place on the keyboard, so the recorder saves the US key at that place (`Chord(placeOf:)`).
The space bar is always Space.

A few keys belong to the recorder itself (`KeyRecording.step`):

- Esc stops the recording without a change, whatever modifiers you hold.
- Backspace or Delete with no modifier also stop it without a change. With a modifier, as in
  Shift+Backspace, they're recorded like any other key.
- A key repeat, or a modifier pressed on its own, isn't a new key.

The recording also stops when the focus moves somewhere else, when the recorder or the part of
Settings that holds it is hidden, when the window stops being the active window or closes, and when
Settings closes. A click on the prompt doesn't stop it, because the prompt can't take the focus.
When it stops, the recorder lets go of the focus, so the shortcuts work again straight away. The
prompt goes away with it, and the focus moves to the Settings panel, or to the search field while a
search is on, rather than to the window, so Enter, Space, the arrows and the hold keys still don't
act (the Control zone below).

Each recorded key is checked against your current keys (`KeyEditor.checkRecorded`) before anything
is saved. A refused key leaves the recording running and shows its reason, so you can press
another key:

| Refused because | Reason shown |
| --- | --- |
| The key has no binding: a digit of the keypad, F13 and above, the key left of 1 on an ISO keyboard, or a key that the matching can't read as any binding | Bifrost can't use this key. Try another one. |
| It's a dead key with no Cmd or Ctrl, such as Option+E, which types an accent with the next key. Cmd+Option+E is a normal shortcut. | That key types a character. Try another one. |
| It's on the space bar, and the slot isn't the dictation key | The space bar can't be a shortcut. Try another one. |
| One of the binding checks above fails | The message of that check, such as "Event log already uses this key." |

A key that passes is saved straight away. The save rewrites only that slot's entry in
settings.json and leaves every other entry as it was, including the ones a later version wrote
(`KeyChanges.stored(keeping:)`).

Reset all keys first asks "This puts every key back to its Bifrost default.", and once you confirm
it puts every slot back to its default (`KeyEditor.resetAll`). It removes each entry this version
can read and keeps the ones it can't, such as a slot it doesn't know or a binding a later version
wrote, so a reset never throws away the keys of a newer version. The question uses the same
in-window confirm dialog as the session actions (`DialogHost`), and if another dialog is already
open, the reset doesn't ask and changes nothing.

All the saves of the Keys section share one error. It shows on the row of the key that failed to
save, and at the top of the section after a failed Reset all keys or when a search hides that row.

Outside Settings, the keys can also change through a key edit, which names some slots with their
new keys (`KeyEdit`). Its checks are in the settings.json part of `docs/behaviour/stores.md`.

## Reading a key event

Before it can match a shortcut, Bifrost turns each AppKit event into a key event of its own. The
window key filter does this for every key down, key up and modifier change (AppKit's
flags-changed event). The key event keeps the macOS key code, which names a physical place on the
keyboard; the characters the key typed; the characters it would type without modifiers other
than Shift; the binding modifiers (Shift, Control, Option and Command); whether it's a key down or
a key up; whether it's a key repeat; and whether an input method is in the middle of composing
text. Caps Lock, fn and the keypad flag aren't binding modifiers, which matters because macOS sets
fn on the arrow keys.

A modifier change counts as the key down or key up of the modifier key that changed, and Bifrost
uses the device flags to tell the left and right keys apart, so letting go of one Shift while the
other is still held reads correctly.

Bifrost then works out which key the event names:

- A modifier key, or a named key such as Enter, Tab, an arrow or F1 to F12, gives its name.
- A key that types nothing, such as Option+E, is a dead key.
- With Control or Command held, the key is what it would type without those two modifiers, with
  Shift still applied. So Control+C reads as "c" and Cmd+Shift+M as "M".
- Otherwise the key is the text it typed, with Shift and Option applied.

One table in `KeyCode.swift` gives the character of each key on a US keyboard, and a binding
always names a US letter, digit or punctuation key, or a key name. The match by position, the
hold keys and the dictation key all use this table. When the match compares a typed key with a
binding it treats the typed key as one Unicode scalar, and a typed letter whose upper case is
more than one scalar, such as ß, keeps its own case.

## Matching a key to a shortcut

A key event can match a binding in three ways, each with a score, and only the matches with the
best score act.

| Score | When it applies |
| --- | --- |
| 3 | The typed key is the binding's key, and the modifiers are the same. |
| 2 | The typed key is the binding's key, but the layout needed Shift to type it (an implicit Shift), as with a symbol on a shifted key. The Turkish dotless ı also matches I at this score. |
| 1 | The typed key can't name a shortcut, so its place on a US keyboard stands in. This covers a key from another script, a dead key, a key of the digit row, a symbol typed with Shift and a letter typed with Option. |

Letters compare without case but with their accents, and with no compatibility mapping, so
Option+0, which types º, doesn't match Option+O. A named key matches only its own name with
exactly the same modifiers, a modifier key on its own never matches, and a key typed while an
input method is composing never matches anything.

## Where a shortcut can act

Whether a shortcut acts depends on where the keyboard focus is. Bifrost looks at the first
responder (the view that has the focus) and the views around it, and puts it in one of six focus
zones:

| Zone | Where the focus is |
| --- | --- |
| Modal | A dialog, a sheet, an alert, a menu, a list box, a view in another window such as a popover, or the key recorder. No Bifrost shortcut acts here. |
| Chat | The terminal of a chat window. |
| Send box | The send box of the Selected Item panel. |
| Text | A text field or a text view. |
| Control | A button, a tab, a check box or another control, including the side bar. |
| Other | Anywhere else, including the window itself. |

Each kind of shortcut then has its own rule:

- The dictation key acts only in a chat.
- A hold key acts only in the other zone.
- A shortcut with Cmd acts in every zone except modal.
- A shortcut with Control but no Cmd acts everywhere except modal and chat.
- Any other shortcut, with neither Cmd nor Control, acts in the other zone, and on a control
  unless its key is Enter, Space, Tab, an arrow, Home or End, which the control keeps for itself.
- Escape has a rule of its own, described below.

When the focus moves into a chat window, Bifrost selects that chat's session, so the session
shortcuts act on it. It only does this when the session has a row in the session list, even one
that no Overview tab shows, and isn't selected already.
When the focus moves to the key recorder, Bifrost forgets any held hold keys.

## What happens when you press a key

The window key filter sees every key event before any view does. It runs the Bifrost shortcuts
first, then, in a chat window, the chat input (the dictation hold key, stopping a dictation, and
Shift+Enter), and only then lets the views have the event. A key that acts as a shortcut never
reaches a view, and a key down acts again on each key repeat.

Two slots, Close Panel and Toggle Fullscreen, live in the menu bar. macOS offers a key to the menu
before the window, so the menu gets those two keys first.

### Hold keys

A hold key lets you act on a session row with the mouse: hold the key, click a row, and the hold
key's action runs on that row instead of a normal click. While you hold one, a double-click
doesn't select or open a row. This only works while exactly one hold key is down.

If you press and release a hold key without clicking a row, it does what the single key with the
same binding does, so O opens the selected row. It acts when you let go rather than when you
press, because until then Bifrost can't tell whether a click is coming, and it only acts when its
key down matched and no other key went down in between.

Bifrost forgets every held key when the window loses the focus or hides, when the focus moves to
the key recorder, and when Cmd goes down or up, because macOS sends no key up for a key released
while Cmd is held. Letting go of a hold key always removes it, even when its key up didn't act or
came with a modifier, so a fast rollover can't leave a stale key behind that turns the next row
click into a hold click.

### Escape

Escape follows the Esc rule (user decision, 2026-11-06):

- In the send box, Esc leaves the send box. The window takes the focus, so the plain keys and
  the next Esc work as they do anywhere else, and the draft stays in the box.
- In the other zone or on a control, Esc closes Settings when Settings is the active panel of the
  top frame, and otherwise opens Settings and brings it to the front. It waits until every view
  has had the key, and acts only if nothing else took it first, such as a popover or a drag.
- A chat, a text field, a dialog, a menu and the key recorder keep their own Esc. A click on the
  empty background of the canvas takes the focus out of a chat, a text field or the key recorder
  (`docs/behaviour/windows.md`), so the next Esc is the window's Esc.
- A key repeat of a held Esc does nothing, and Esc never clears the selection.

An Esc or a Tab that nothing used goes on to AppKit, so Esc can still leave full screen and Tab
still moves the focus through the window.

## Which shortcuts work today

Every slot runs a command now:

- Close Panel and Toggle Fullscreen.
- The previous and next tab of the top frame, which wrap around.
- Load layout 1 to 9, which loads the saved layout at that place in the side bar, and Save
  layout, which opens the Layouts popover.
- Focus Overview, which picks the focused Overview (described below), else the top Overview in
  the side bar, else opens a new one, and then gives that Overview's rows the keyboard focus.
- Tab and Shift+Tab, the next and previous Overview tab keys, which switch the focused Overview
  to the tab after or before its active one and wrap around at the ends.
- Select row 1 to 9, and the previous and next row, which stop at the ends. With no row selected,
  next picks the first row and previous picks the last. These keys work on the rows of the
  focused Overview's active tab, in the order you see them, so its filters and its sort count.
- Open, which opens the chat of the selected row when it's an owned session that isn't parked,
  and the O hold click, which does the same for the row you click.
- The session keys: Send message, Run slash command, Interrupt, Rename, Show Info, Copy session
  ID, Open project, Open in terminal, Take control, Resume, Set priority, Stop and Delete. Each
  one hands its session action to the action runner (`docs/behaviour/actions.md`), which reads
  the row by its ID at the moment you press the key. So the key always acts on the row as it is
  now, and an action that's off for that row does nothing, just as its greyed-out button would.
  When an action runs and fails, its reason shows in the error line. The runner only exists once
  Bifrost has found `claude`, so until then these keys and the two below do nothing.
- New session and Resume all, which need no row. New session opens its dialog, and Resume all
  resumes the parked sessions that were running when Bifrost last closed.
- The hold clicks of O, M, I, J, X and 1 to 5, which run Open, Send message, Show Info, Open in
  terminal, Interrupt and Set priority on the row you click. The click itself doesn't select the
  row, but Send message then selects it, because its send box belongs to the selected row.
- The Event log and Usage HUD keys, Cmd+L and Cmd+U by default, which open their panel, or bring
  it to the front and restore it if it's minimised.
- Settings, on Cmd and the comma key, which opens Settings or brings it to the front, and Esc,
  which follows the Esc rule above.
- The dictation key.

With more than one Overview open, the Overview tab keys and the row keys need to know which one
you mean. That's the focused Overview: the Overview whose rows have the keyboard focus, which they
get when you click them, click in that Overview's tab bar or press Focus Overview. When no
Overview's rows have the focus, for example while you type in a chat, it's the Overview that's the
active panel of the highest frame showing. With no such Overview these keys do nothing, so they
never act on an Overview you can't see.

A session key acts on the selected row. When the focus moves into a chat window, Bifrost
selects that chat's session (see "Where a shortcut can act"), so a key you press in a chat acts
on its session, and if you then select another row, the key follows the selection. With no row
selected, or with a selected session that's no longer in the list, a session key does nothing.
While a dialog is open, such as the confirmation of Stop or Delete, no session key acts, so a
second press of Backspace can't open a second dialog or stop anything.

Two of the session keys take a value. Set priority 1 to 5 sets that priority, and Set priority 0
clears it. Open project opens the session's folder in the default project app: the app you chose
in Settings when it's installed, otherwise VS Code, then Zed, then the first installed terminal
app. Finder never counts as the default, so with only Finder installed the key does nothing.

## The dictation hold key

The dictation key's own rules, such as the 250 ms wait before dictation starts, are in
`docs/behaviour/dictation.md`.

## Not carried over from Electron

The Electron accelerator strings, the DOM focus read and the bubble phase of a DOM event have no
place here, because AppKit gives the first responder and the responder chain directly. The key
event has no DOM `key` or `code` names and none of the browser's special values: no "Unidentified"
key, no "Process" key and no key code 229. AppKit marks a key of a composition through the marked
text of the first responder instead. There's also no text form of a recorded key, like the
Electron recorder's "Mod+[KeyS]", because the key recorder builds its chord straight from the key
event (`Chord(event:)`).
