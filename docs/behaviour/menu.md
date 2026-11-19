# The Bifrost menu: behaviour

Every menu inside Bifrost's window is a Bifrost menu: a small dark box with the app's own colours
and font, which you can drive with the pointer or the keys. The Panel menu of a frame uses it, and
so do the right-click menu of an Overview row (see "The row menu" in `actions.md`) and the tab menu
of an Overview (see "The tab bar" in `overview.md`). With one menu type, every menu in the window
looks and behaves the same way, as the menus of the Electron app did (user decision, 2026-11-16).

Two kinds of menu stay standard macOS menus. One is the system menu bar at the top of the screen.
The other is the pop-up pickers inside a dialog or Settings: the Recent, Model and Permission mode
pickers of the New session dialog, and the pop-ups of the Settings rows. Those are native pop-up
buttons, which are fine for now (user decision, 2026-11-17); a later build may move them to the
Bifrost menu, but that has a very low priority.

The Electron menus had no tests of their own, because the menu library they were built on tests
itself. So each rule on this page has its own new test, with the value or the key of the Electron
menus as its source. The places where the native menu differs on purpose are listed in
`docs/ports/menu/DELIBERATE-DIFFERENCES.md`.

The rules of the keys and the pointer are plain values in `BifrostWindows/Model`: `MenuRow.swift`
describes the rows, and `MenuNavigation.swift` decides where the highlight goes and when a submenu
opens or a row is chosen. The window side is in `BifrostWindows/UI`: `BifrostMenu.swift` shows the
menu and carries out those decisions, `MenuPanel.swift` holds the panel and the views that take
the pointer and speak to VoiceOver, and `MenuView.swift` and `MenuRowViews.swift` draw the rows in
SwiftUI. The sizes and colours are in `ThemeTokens.Menu`.

## Rows

The owner of a menu describes it as a list of rows, and gets back the ID of the row the user
chooses. A row is one of these:

| Row | What it does |
| --- | --- |
| Item | Acts and closes the menu. |
| Check box | Shows a square box, empty while it's off and with a check mark while it's on, like Lock in the Panel menu. Choosing it keeps the menu open, so you can see the change. |
| Check | Shows a check mark while it's on and nothing while it's off, like the filters and columns of an Overview tab. Choosing it keeps the menu open too. |
| Radio | One row of a group with a check mark on the current choice. Choosing it closes the menu. |
| Submenu | Opens a further menu of rows at its right. |
| Field | A label above a text box. Enter saves the text, and the menu stays open. |
| Separator | A line between two groups of rows. |

An item, check box, check, radio or submenu row can be disabled, in which case it's faded, can't be
chosen, and shows the reason in a tooltip. That tooltip takes its width and its edges from the
screen rather than the small menu panel, so it flips to the left of the row at the edge of the
screen. A row can also carry a small colour square before its label, such as the colour of a
priority, or keep the space of one with no colour, so a "None" row lines up with the coloured
rows above it. After a change, the owner gives the menu its new rows, so a check mark or a saved
name shows straight away. The row menu does the same whenever its row changes: while it's open,
its entries follow the session, so an entry that a Stop or a new prompt turns off greys out at
once, as in the Electron app.

## The look

The values come from the classes of the Electron menus, and all sizes are in layout units, so
they grow with the Interface scale:

| Part | Value | Electron class |
| --- | --- | --- |
| The box | At least 144 wide, a border of 1 in the panel edge colour, the title colour as fill, 4 above and below the rows, no shadow | `min-w-36 border border-panel-edge bg-title py-1` |
| Text | The UI font at 12 points in the text colour | `text-xs text-text` |
| A row | 20 high, 8 at each side, 8 between its parts | `h-5 px-2 gap-2` |
| The highlighted row | White at 10 % | `bg-text-strong/10` |
| A pressed row that isn't disabled | The accent at 12 % | `bg-accent/12` |
| A disabled row | 40 % opacity, with its reason in a tooltip at its right, 6 away | `opacity-40` and `Tip` |
| A separator | A line of 1 in the panel edge colour, with 4 above and below | `my-1 h-px bg-panel-edge` |
| A submenu row | An arrow of 12 at its right end, with 4 at its right | `ChevronRight`, `pr-1` |
| The row of an open submenu | White at 5 % while the highlight is inside the submenu | `aria-expanded:bg-hover` |
| A check box row | The square of the Bifrost check box: 14 by 14 in the background colour, with a border of 1 in the dim text colour while it's off and the text colour while it's on, and a check of 10 in the strong text colour while it's on | `CheckBox`: `size-3.5 border border-text-dim bg-bg`, `group-data-checked:border-text`, `Check size={10}` |
| A check or radio row | A column of 12 for a check mark of 12 | `w-3`, `Check` |
| A colour square | 8 by 8 | `size-2` |
| A field row | The label, 4 below it a box in the background colour with a border, 8 by 4 inside the box; the border is white at 30 % while the box has the focus | `gap-1`, `border bg-bg px-2 py-1`, `focus:border-text-strong/30` |

A menu opens at the point of a right-click, with its top left corner at the pointer, or below a
button, 4 units under it. It always stays inside the visible part of its screen: at the right
edge it flips to the left of the point, and at the bottom edge it flips above the point or the
button. If it fits on neither side, it moves along until it's inside. A submenu opens at the right
of its row and 5 units higher than the row, so its first row lines up with the row, and it flips
to the left of the row at the edge of the screen.

## Keys and the pointer

The keys follow the menus of the Electron app, which loop at the ends, look rows up as you type,
and open a submenu under the pointer:

- Up and Down move the highlight over the rows, and wrap round at the ends. Home and End go to
  the first and the last row. A separator is skipped, but a disabled row takes the highlight, as
  the Electron menus kept a disabled item focusable: its reason shows in its tooltip straight
  away, and Return or Space on it does nothing. With no highlight, Down starts at the first row
  and Up at the last.
- Right opens the submenu of the highlighted row and highlights its first row. Left closes the
  submenu and puts the highlight back on its row. A disabled submenu never opens.
- Return and Space choose the highlighted row, and on a submenu row they open it. Holding either
  key down chooses only once, so a held Space changes Lock once. Esc closes the innermost open
  submenu, then the menu itself.
- Typing a letter highlights the next row whose label starts with the typed text, ignoring case.
  Letters typed within 750 ms of each other build up a longer text, so typing "res" goes past
  "Rename" to "Resume". After a 750 ms pause the text starts again. Typing the same letter again,
  quickly or not, moves on to the next row with that letter, so repeating it cycles through those
  rows. Space while you're typing adds a space to the text, so "open p" reaches "Open project";
  otherwise Space chooses the highlighted row.
- The pointer highlights the row under it, disabled rows included. Resting on a submenu row for
  100 ms opens its submenu, and moving to another row in the same menu closes it. There's no
  "safe triangle", so a diagonal move towards a submenu across other rows closes it. A press tints
  an enabled row, and releasing on it chooses it.
- You can also press, drag and release: the highlight follows the pointer during the drag, and the
  release chooses the row under the pointer, whether the press started on a row or on the button
  that opened the menu. A release that isn't over a row chooses nothing.
- A field takes the focus when the keys reach it or when you click it. While it has the focus it
  takes the typed text and the keys that edit it (the arrows to the sides, Home, End, Space and
  Backspace), and the pointer doesn't move the highlight away from it. Up and Down leave the
  field, Enter saves it and Esc closes the menu. After a save the field shows the saved text, so
  a name the owner refused goes back to the saved one.
- Tab does nothing, and every other key stays in the menu. While a menu is open, only the
  shortcuts of the menu bar act, because macOS gives a key to the menu bar before the window.

## The panel

Each menu is a borderless panel that floats above the window at the level of a pop-up menu, with
no title, no shadow and a clear background behind the SwiftUI box. Each open submenu is one more
panel.

- As with every macOS menu, the window under the menu stays the key window. It passes each key
  press to the open menu, and the key rules treat everything else as happening in a dialog, so no
  Bifrost shortcut acts while the menu is open. A key you were already holding when the menu
  opened still reaches its chat when you let it go, so a held dictation key stops dictating, and
  the chat keeps its focus throughout. The other way round, a key the menu took never reaches a
  chat, not even after the menu closed: a held Return that chose a row doesn't then type into
  the chat.
- The one exception is a field. While its text box edits, the panel of the root menu takes the key
  focus so the box gets the typed text, and it hands the focus back to the window as soon as the
  highlight leaves the field. A submenu panel never takes the key focus, so a field works only in
  the root menu.
- A press outside the menu closes it, in Bifrost or in another app. So does the window, or the
  menu's own panel during a field edit, losing the key focus to anything other than the menu (a
  sheet or an alert, say), Bifrost becoming inactive, a click in the menu bar and a close of the
  window. An item of the menu bar that acts, such as Close Panel or Zoom, closes it too, so the
  menu never stays open over the result. Only an edit of the menu's own field keeps it open:
  while the field edits, that's Paste, Cut or Select All, Undo and Redo, Emoji & Symbols and
  Dictation.
- What a press outside does next depends on the menu. The row menu and the tab menu open at the
  pointer, like the context menus of the Electron app, and a press outside them only closes the
  menu: it doesn't also select a row, switch a tab or press a button. A press outside the Panel
  menu, or a menu below a button, goes on to whatever it landed on, except a press on the button
  that opened the menu: that one only closes the menu, so the button doesn't open it again
  straight away.
- At each close the view that had the focus before the menu opened gets it back. The window only
  takes the key focus back after a field edit, and only when Bifrost is active and no window has
  the key focus, so a menu that closed because you switched away never pulls the focus back.
- A row that closes the menu acts after the close, so an action that moves the focus, such as one
  that opens a dialog, keeps it.

For VoiceOver, the menu is a list with the role of a menu, and each row has the role of a menu
item, apart from the separators, which are hidden. The SwiftUI drawing underneath is hidden too, so
VoiceOver only ever lands on the rows. A check box, check or radio row reports 1 while it's checked
and 0 otherwise, and a checked row gives the ✓ mark that macOS menu items give. A disabled row
reports itself as not enabled and gives its reason as its help, and the highlighted row is the
selected one. A submenu row always has a menu as its child, so VoiceOver knows it opens a
submenu, and it reports whether that submenu is open. A field row is its text field, named by its
label. Each menu and submenu announces when it opens and closes, and the row that gets the
highlight announces itself, in whichever menu it's in.

## The Panel menu

Each frame's title bar has a menu button, and the Panel menu opens below it as soon as you press
the button, 208 units wide, with its right edge at the right edge of the button and 4 units under
it. Because it opens on the press, you can drag straight to a row and release there. Pressing the
button again while the menu is open closes it.

- Every frame has the check box Lock, which locks or unlocks the frame and keeps the menu open.
  A frame has no opacity control.
- The menu of an Overview also has "Overview settings…" above Lock, which opens the Overview
  Settings panel of that Overview (`overview-settings:<n>`) and closes the menu, and the field
  "Tab set name" below Lock. The field takes at most 40 characters, counting an emoji or an
  accented letter as one (row OV6 of the Overview port). Enter saves the name with the Overview's
  rename rule, and an empty name leaves the saved name in place and shows it again.

The rows are built in `FrameMenu.swift`, and the canvas shows them on its Bifrost menu.

## Tests

The tests of the rules are in `Tests/BifrostWindowsTests/Model`, and the tests of the panel and
the Panel menu are in `Tests/BifrostWindowsTests/UI`. The windows in the tests are never shown, so
the menu panels never appear on the screen.

- `MenuNavigationTests`: each key and pointer rule, with the times of the type-ahead and the
  submenu delay on the clock of the test.
- `ThemeTokensTests` (in `BifrostLookTests`): `theMenuValuesMatchTheElectronClasses` checks each
  value of the look against its Electron class.
- `BifrostMenuTests`: the panel, the accessibility of the rows, the tooltips of disabled rows,
  each way of closing the menu and the focus that comes back, the keys, and the place of a menu
  and a submenu on the screen.
- `MenuSnapshotTests`: one row of each kind, compared with an image.
- `FrameMenuTests`: the rows of the Panel menu, Lock, the Overview items and the name field, and
  the place below the button.
