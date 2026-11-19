# The Overview: behaviour

The Overview is Bifrost's session table. Its rows are the Claude Code sessions, and each tab along
its top shows a filtered, sorted part of the list. A window can hold several Overviews, each with
its own set of tabs, called its config. This page covers the rules under the table, which live in
`BifrostWindows/Model/Overview/`, and the table, the tab bar and the Overview Settings panel,
which live in `BifrostWindows/UI/Overview/`. `docs/ports/overview/DELIBERATE-DIFFERENCES.md` lists
where they deliberately differ from the Electron app.

## Tabs and columns

- The standard config, named Default, has six tabs. All shows the running sessions (working,
  alert, error and idle), Alerts shows those with an alert box, Watched shows the watched
  sessions in any state, and Working, Idle and Parked show one state each. All starts active.
- A config has 1 to 12 tabs. A new tab is called "Tab <n>", filters like All, takes the next of
  the first six tab colours and becomes active. Closing the active tab activates the one to its
  left, or the first tab, and the last tab can't close. Watched is `t0` and added tabs count up
  from `t6`, so IDs never clash.
- A tab name is 1 to 24 characters after trimming and the set name 1 to 40. An emoji or a
  letter with an accent counts as one character, as in the names of saved layouts.
- The columns are kind (the session icon, with no header text), Name, Priority, State, Project,
  Branch, Model, Context %, Cost and Activity. A new tab shows kind, Name, State, Project and
  Activity, and kind is always first and visible.
- A tab keeps the order of all ten columns, hidden ones included, so a column you turn back on
  shows where it was. A hidden column can move too, and a move before kind lands just after it.
  Dropping a header on one to its right puts it after that one, and on one to its left, before.
- The table shows the visible columns in the tab order, each at its width. Dragging the edge
  between two headers resizes the column on its left. A width is rounded and kept between 24 and
  600, and a column with no saved width has its default (184 for Name, 200 for Project and so
  on).
- A header click sorts by that column, and a second click reverses it. Context %, Cost and
  Activity start from the highest value. A hidden column never sorts, so hiding the sort column
  switches to Name ascending, or to the first visible column after kind when Name is hidden.
- A reset restores the tab's default columns, order, widths and filter (All's filter for an added
  tab), and keeps its name and colour. An action on an unknown tab, with a bad value or with no
  effect changes nothing, and `apply` reports whether the config changed.

## Rows

- A tab shows a row when the row's state and kind are in its filter and, if the filter asks, the
  row has an alert box or is on the watchlist.
- Name, Project, Branch and Model sort in English order with numbers: case and accents don't
  count, and a run of digits sorts as a number, so `s2` comes before `s10`. Project sorts by the
  label it shows. State sorts by state alone (error, alert, working, idle, parked), so a row stays
  put when its yellow box turns red, and kind puts owned sessions first.
- A missing value, an empty text or a number that isn't a number goes last in both directions.
  Rows with equal values keep the order of the session list.

## Cells and the icon

- Project shows the last two parts of the folder, or of the repository for a folder in a Claude
  worktree (`<repo>/.claude/worktrees/<name>`).
- Cost shows `≈$` and two decimals, because Claude Code's cost is an estimate from token counts
  and public API prices. Above zero and below one cent it shows `<$0.01`, and a cost exactly
  halfway between two cents rounds up.
- Context % is a whole percent, with a half rounding up. Its bar is low below 40, mid from 40 and
  high from 70, judged on the rounded number, so 39.6 shows 40% in the mid colour.
- Activity shows the age in whole units (`59 s`, `1 min`, `1 h`, `1 d`), and the table gets the
  time until the text changes, at most an hour, so it updates the cell just then. Both come from
  the shared time texts (`TimeText`, see [usage](usage.md)).
- State shows Working, Alert, Error, Idle or Parked: red for an error or an alert, yellow for an
  alert with a yellow box. A message preview shows its first three lines with text, trimmed.
- The icon takes one of eight colours from a 32-bit FNV-1a hash of the repository path, so a
  project's sessions share a colour. Its glyph is the Bifrost mark for an owned session and a
  terminal for an external one, and any parked session shows the Bifrost mark in the parked grey.
  When Bifrost knows which app is showing a session, the icon is that app's icon instead (see
  [Which app the icon shows](#which-app-the-icon-shows)).

## The table

Each Overview panel shows the rows of its active tab in an AppKit table (`OverviewRowsView`), with
the tab bar above it and, when the session list has a problem, an error line below it. All the
Overviews share one model (`OverviewModel`), so they share the selection and the session rows,
while each keeps its own config.

- The table has one column for each visible column of the tab, in the tab's order and at its
  width. Rows are 22 units high and the header 18, and every size follows the Interface scale.
- The column work of the header is the table's own (`NSTableView`'s column reordering, resizing
  and header clicks), so it behaves like the header of any Mac list. Clicking a header sorts by
  that column, and the sort column shows ▲ or ▼ after its label. A press that turns into a drag
  or a resize isn't a click. The pressed header gets the cyan tint.
- Dragging a header moves its column live, and letting go saves the one move to the config. The
  kind column never moves, and no column can go in front of it. Dragging the edge between two
  headers resizes just the column on its left.
- A long text ends with an ellipsis, and the Project cell's tooltip shows the full folder. The
  row icon's tooltip names the kind of session (Owned, External or Parked session), or the app
  when the icon is an app's own.
- Bifrost keeps the selection itself, and the table never selects a row. A click selects a row,
  unless a hold key is down: then the click runs the hold command on the row and the selection
  stays. A double-click also opens the row, except during a hold. A right-click, or a
  Control-click, asks for the row menu at the click point without changing the selection, and a
  right-click away from the rows does nothing.
- A click anywhere in the rows or on the header gives the keyboard focus to the rows, so the
  Bifrost keys act on this Overview. When the selection changes, for example after an arrow key,
  its row scrolls into view.
- When no Bifrost shortcut uses them, the usual scroll keys scroll the rows, as in the Electron
  app. Page Up and Page Down scroll a page, Home and End go to the top and the bottom, Space and
  Shift+Space scroll a page down and up, and Left and Right scroll the columns sideways by 40 units
  when they're wider than the panel. A scroll key held with Command, Control or Option doesn't
  scroll, and every other key carries on to the rest of the window.
- The header keeps the panel colour, so rows that scroll under it don't show through.
- While a New session is starting, every tab shows it after its own rows as a Starting… row with
  the name, "Starting…" in the dim colour and the project, until the session list has the real
  row. A Starting… row has no icon, takes no click or menu, and scrolls into view when it appears
  ("New session" in [actions](actions.md)).
- With no sessions at all the table says "No sessions.", and when the tab's filters hide every
  session it says "No sessions match the filters of this tab.". Neither shows while a Starting…
  row is in the table. While the session list fails to
  load, or when Claude Code can't be found, the error line at the bottom gives the friendly reason.
- One timer for each table updates the Activity texts when the next Activity text is due to
  change. No timer runs while the Activity column is hidden or the table isn't in a window, and
  when a hidden Overview comes back, for example after a switch of stack tabs, its texts show the
  time of now straight away.
- Until the app has its full set of session actions, a double-click opens the chat of an owned
  session that isn't parked, and does nothing for any other row.

### Row colours and the icon

The colours of a row come from the selection, the open chats, the pointer and the watchlist.

- The selected row is the accent at 15 %. A hovered row, and a row whose chat is open in any frame,
  are white at 5 %. Pressing a row gives it a short cyan tint, the accent at 12 %.
- A watched row has its watch colour at 12 % behind the selection and the hover, and a 3-unit
  stripe of the full colour along its left edge, which stays on top of everything else.
- A parked row's text is the parked grey (`#6b7280`). State labels and priorities keep their own
  colours, as described under Cells and the icon.
- The icon draws its glyph in the project colour, and in the parked grey for a parked session. The
  Bifrost mark is a hexagon until the logo exists. A session that an app is showing gets that
  app's icon instead, in its own colours, as the next section explains.
- A row with a box has four corner brackets around the glyph, 2 units thick with arms 30 % of the
  side, in the yellow (`#e2b93b`) or red (`#f5766d`) of the box. While the Row flash setting is
  on, the brackets fade to 25 % and back once a second.
- The project colours are eight blues and greens (`#93c5fd`, `#60a5fa`, `#2dd4bf`, `#4ade80`,
  `#34d399`, `#7aa2d6`, `#38bdf8` and `#a3d63a`), so none can be mistaken for a box or for the
  parked grey.

### Which app the icon shows

The row icon also shows where you have a session open, such as a Bifrost chat window or a Warp
tab. `SessionIconRules.holder` makes the choice and `SessionAppIcons` supplies the images, which
the Overview, the Watchlist and the Selected Item panel all share.

- A session that one of Bifrost's chat windows is attached to shows the icon of the running app,
  so the development build shows its own icon, and the tooltip says Bifrost. The chats know their
  own attaches (see [chat](chat.md)), so this needs no process read, and it changes the moment a
  chat attaches or closes.
- Otherwise a session that a terminal app is showing gets that app's icon, with the app's name as
  the tooltip. For an external session that's the app its process runs in. A background session
  runs inside Claude Code's background service, so Bifrost uses the app of its newest
  `claude attach` client instead, which the [registry](registry.md) finds.
- When a chat window and a terminal are both showing the session, the chat wins. Bifrost is
  certain about its own attach, and the chat sits in the same window as the Overview, one click
  away. Close the chat and the terminal's icon comes back.
- A parked session always shows the mark in the parked grey. An owned session that nothing is
  showing keeps the mark, and an external session with no known app keeps the terminal glyph.
- Bifrost looks up each terminal app's icon once, from the path of its app bundle, off the main
  thread. Until the lookup finishes the row shows its glyph.

## The tab bar

Above the table, each Overview has a row of tabs (`OverviewTabsView`), one for each tab of its
config, followed by a + button for adding a tab. It's SwiftUI in its own host view, which
`OverviewPanel` places in the 22-unit strip above the rows.

- The tabs appear in the config's order, each in its own tab colour. The active tab has a 2-unit
  line in its colour underneath, and the others sit at 70 % opacity until the pointer is over them.
  When the tabs don't fit, they scroll sideways with no visible scroll bar.
- Clicking a tab makes it active, and the table switches to that tab's rows straight away.
- After a click on a tab, on + or on any item of the tab menu except Rename..., the rows get the
  keyboard focus, so Tab, the arrows and the other Bifrost keys act on this Overview. A filter or
  column item keeps the menu open, so the rows get the focus when the menu closes.
- Double-clicking a tab, or choosing Rename... from its menu, swaps the tab for a name field
  labelled "Tab name" with the whole name selected. Esc puts the old name back, and every other
  way out saves the name: Enter, a click on another tab, on + or on any item of the tab menu, a
  click on the rows or anywhere else on the canvas, a switch to another app, and starting a
  rename of another tab. After Enter or Esc the keyboard focus goes back to the rows. The field
  takes at most 24 characters, and an empty name doesn't save.
- The + button adds a tab and makes it active. At 12 tabs it's greyed out, and its tooltip says
  "The Overview can have up to 12 tabs." instead of "Add tab".
- Right-clicking a tab, or Control-clicking it, opens its tab menu at the pointer. It's a Bifrost
  menu (`docs/behaviour/menu.md`): Rename..., Filter (the five states, "Only rows with a box" and
  "Only watched sessions"), Columns (every column except kind), Reset, Move left, Move right and
  Remove tab. A filter or column item is a check box with a tick while it's on: choosing it flips
  it and the menu stays open, so you can change several in one go. Reset is greyed out for a tab
  that already has its default columns and filter, and Remove tab for the last tab, and the
  tooltip of a greyed-out item gives the reason. Moving the first tab left, or the last tab right,
  does nothing. Rename... shows the name field once the menu has closed. A press outside the menu
  only closes it, so it doesn't also switch tabs or select a row. With VoiceOver, the "Show menu"
  action of a tab opens the same menu below the tab.
- Neither the tabs nor the + button take the keyboard focus, so a frame that moves never makes
  AppKit rebuild the window's Tab loop. Only the name field takes the focus, while you rename.

## Overview Settings

The Overview Settings panel (`overview-settings:<n>`) edits the tabs of the Overview with the same
number, and you open it from "Overview settings…" in that Overview's Panel menu. It changes a
config through the same actions as the tab bar, the tab menu and the table header, so a change
looks the same whichever place it came from. The panel lives in `OverviewSettingsPanel` and its
rules in `OverviewSettingsRules`.

- The panel always edits the active tab of its Overview. The Tab picker at the top shows that
  tab's name in its colour, and choosing another tab there also switches the Overview to it, so
  every change shows in the table straight away.
- The Colour row has 12 swatches, one for each tab colour, and the chosen one has a white outline.
  Clicking a swatch picks its colour and gives the row the keyboard focus, after which the arrow
  keys move through the colours as described below. Each swatch's tooltip names its colour (Cyan,
  Light blue, Green, Teal, Blue, Mint, Red, Amber, Yellow, Lime, White and Sky blue).
- Below that, two tabs switch between the Columns part and the Filters part. Columns has a check
  box for each column and a drag handle, and while you drag a row a line shows where it will land.
  Filters has the groups States, Kinds (Owned and External), Boxes ("Only rows with a box") and
  Watchlist ("Only watched sessions").
- Reset to default at the bottom restores the tab. It stays in view below the part that scrolls,
  and it's greyed out for a tab that already has its default columns and filter, with the tooltip
  "This tab already has the default columns and filter."
- The kind row's tooltip explains the lock: "The kind column always stays first and on."
- The check boxes are Bifrost's own small dark squares with a white tick.
- If the Overview isn't in any frame, the panel just says "This Overview is closed.". A minimised
  Overview still counts as open.
- None of the panel's SwiftUI controls take the keyboard focus, for the same reason as the tab
  bar. The Colour row can, because it's an AppKit control (`TabColourPicker`), and Bifrost's own
  shortcuts leave its arrow keys to it.

The rules behind the panel:

- The column list shows every column of the tab in its order, so the top row is the leftmost
  column. Kind comes first with the label Kind, and it's locked: it can't be hidden or moved.
  Turning a column on or off, moving it and resetting the tab all use `apply`.
- The filter switches show or hide one state or one kind, or limit the tab to rows with an alert
  box or to watched rows. The states always keep the order working, alert, error, idle, parked,
  and the kinds owned then external, whatever order the saved filter had. A switch on an unknown
  tab, or one that changes nothing, leaves the config as it was.
- You reorder the columns by dragging their rows, and the dragged row fades while you drag.
  Dropping on the upper half of a row puts the dragged row before it, and on the lower half,
  after it. Dropping a row on itself, or on the lower half of the row above it, leaves the order
  alone, and nothing goes before kind. Letting go more than 24 units outside the list cancels the
  drag. The list has 4 units of space above and below its rows, and the 24 units count from its
  edge.
- In the Colour row, the left and right arrow keys pick the previous or next of the 12 tab
  colours, wrapping round at the ends, and any other key leaves the colour alone.
- A drag only starts once the pointer has moved 4 units, as for a frame, so a plain click on a row
  just flips its check box, and the release of a drag never does.

## The Panel menu of an Overview

When the active panel of a frame is an Overview, its Panel menu has two more items around Lock.
"Overview settings…" above Lock opens the Overview Settings panel of that Overview, or brings it
to the front. Below Lock, a "Tab set name" field shows the saved name of the Overview's tab set.
Pressing Enter saves the name and the field then shows the saved name again, so an empty name
just snaps back to the old one. The field takes at most 40 characters, and leaving it without Enter
doesn't save. The app gives the canvas the Overview model (`CanvasView.overviews`), and without it
the menu only has Lock.

## The saved config

- Each Overview's config is saved in ui-state.json under the Overview's panel ID. An Overview
  whose config can't be read shows the standard config, and the others aren't affected
  (`docs/behaviour/windows.md` has the details). The config and each tab keep the fields that
  this app doesn't know, and a save writes them back, while the filter and the sort keep only
  their own.
- Reading it back repairs what it can. A tab with a bad ID, a bad name or a repeated ID goes, and
  only the first 12 stay. Unknown columns and filter values go, widths are rounded and clamped, a
  bad colour becomes the automatic colour of the tab's place, and a bad sort or one on a hidden
  column falls back as above. A config with no good tab isn't read.
- A tab saved without a column order keeps its visible columns in their saved order. A filter
  saved without kinds or a watchlist flag shows both kinds and the unwatched rows. A tab `t2`
  named "Needs you" becomes "Alerts", and no other tab is renamed.
- The next tab number stays between 1 and 9999 and above every saved tab number. After a saved
  tab `t9999` it's 10000, and no tab can be added.
