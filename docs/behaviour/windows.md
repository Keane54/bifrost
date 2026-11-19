# Frames and the window layout: behaviour

Bifrost's interface is one main window, with a side bar on the left and a canvas for everything
else. On the canvas, frames can overlap or snap together, and each frame shows a panel, such as a
chat or the session list, or several panels stacked as tabs. This page covers the rules of the
frames and the layout, how dragging, snapping and stacking work, how the main window is shown,
and the side bar. The Electron app was a reference for behaviour only (user rule, 2026-11-16), and
the places where the native app differs from it on purpose are listed in
`docs/ports/windows/DELIBERATE-DIFFERENCES.md`.

The layout rules are in `BifrostLayout`, which covers the layout itself, its geometry, hit tests,
drags and the UI state. `BifrostWindows/Model` holds the display mode, the window state and the
typed views of the UI state, and `BifrostWindows/UI` holds the canvas, the side bar and the
window. The file formats are in `docs/behaviour/stores.md`.

## Frames and panels

The layout is the list of frames on the canvas, plus a memory of where each panel was last, so
that a panel opens again where the user left it.

- A frame holds one panel, or a stack of panels as tabs. The layout keeps the frames in z-order,
  with the last one on top, and remembers the last rect of each panel.
- All sizes are in layout units, and every result is a whole number. One unit is
  `interfaceScale / 100` points, so the Interface scale setting zooms the whole canvas. A value
  rounds with `rounded()`, so a half goes away from zero (row W17).
- There are 18 kinds of panel, each with a default size, for example 720 x 480 for a chat, 760 x
  360 for the Overview and 720 x 540 for Settings. A panel ID is the name of its kind, or for some
  kinds the name with a part after it: `overview:<1 to 99>`, `overview-settings:<1 to 99>`,
  `chat:<session ID>`, `show-info:<session ID>` or `module:<module ID>:<panel ID>`. The case of the
  letters in a session ID doesn't matter, because the app keeps the ID in lower case and both
  forms name the same panel. A frame ID is `f<number>`.
- Opening a panel that's already in a frame makes it the active tab, restores the frame and
  brings it to the top. A new panel gets its remembered rect (clamped to the canvas), or else its
  default size in the centre. If a frame that's showing already has that default rect, the new one
  moves 24 units down and to the right until it finds a free place, and the steps stop at the edge
  of the canvas.
- Closing the active tab makes the tab to its left active, or else the first tab. Closing the last
  panel closes the frame, and its rect goes into the memory. `replace` puts one panel in another's
  place and keeps the frame, its rect and its place in the z-order.
- A frame is at least 200 x 120 and stays inside the canvas. The saved rect doesn't change when the
  canvas shrinks: the screen shows a clamped rect, and the frame goes back to its saved rect when
  the canvas grows again.
- The clamp rounds the size first and then the place, so a rect with half units (from a file)
  never passes the edge of the canvas (row W16).
- A locked frame can't move, be resized or give its tabs away. A minimised frame doesn't show and
  isn't a target for anything. Focusing a frame moves it to the top of the z-order.
- The frame on top has the focus, which it shows with a darker fill, a stronger border and the
  cyan glow, and only a chat in that frame counts as focused. A click on the empty background of
  the canvas, with any mouse button, takes the focus away from every panel (row W21). The window
  itself gets the keyboard focus, so no chat terminal or field keeps it, and the top frame loses
  its focus look but keeps its place. Esc and the other keys then act as they do with no panel
  focused (`docs/behaviour/keys.md`), so Esc opens Settings rather than interrupting a chat. The
  keys that work on the top frame, such as Close Panel and the previous and next tab, still act
  on it, even without its focus look.
- This also works on the click that brings Bifrost back from another app, but only on the
  background: a first click on a frame just makes the window active, as everywhere in macOS.
- Clicking a frame, even the one on top, gives the focus back, and so does anything else that
  brings a frame to the front: opening a panel, restoring a minimised frame, or stacking or
  tearing out a tab. While a dialog is showing, a click on the background changes nothing. A
  click outside the Panel menu closes the menu and then counts as a click on the background,
  while a click outside a right-click menu only closes that menu (`WindowLayout.focusedFrame`,
  `CanvasView`).
- Each frame has a Panel menu, which opens below the menu button of its title bar. It's a Bifrost
  menu with the check box Lock, and for an Overview also "Overview settings…" and the name of its
  tab set. `docs/behaviour/menu.md` covers the menu and its rows.
- Loading a layout replaces the frames. A panel that an earlier frame already has is dropped, a
  frame with no panel or no finite rect is dropped, and each frame gets a new ID.
- A value that isn't finite stops where it comes in: the layout refuses such a rect or canvas
  size, and a pointer movement that isn't finite counts as 0, so the rules after it only ever see
  finite values (row W18).

## Dragging, snapping and stacking

These rules decide how a frame follows the pointer and where it lands when the user lets go.

- A move or a resize follows the pointer with no snapping. On release, each axis snaps to a line
  within the snap distance (the Snap distance setting, 8 units by default): first the edges of the
  canvas, then the edges of the other frames that overlap on the other axis. The closest line
  wins, and the first edge wins a tie.
- A mark with an arrow shows each snap. When two marks are less than 8 units apart on both axes,
  they'd cover each other at the corner, so each moves to the middle of its own frame edge.
- Dropping a frame by its title bar onto another title bar stacks the two, but only after the
  pointer has moved 4 units from where the drag started. If the body of a higher frame covers that
  point, nothing stacks.
- A tab leaves its stack (a tear-out) when the pointer goes more than 12 units from the title bar.
  The new frame's top-left corner is 60 units left of the pointer and 14 units above it, and the
  frame has the panel's saved size. Pressing the only tab of a frame moves the frame.
- A frame keeps its backdrop blur only while it overlaps a lower frame that's showing. Rects that
  only touch don't overlap, and during a drag the live rect of the dragged frame counts.

## The main window

The main window remembers where it was and how it was shown, and it can be a normal window, a
borderless window that covers the screen, or a native full-screen window.

- The window is at least 800 x 500. It opens at its saved place, or at 1440 x 900 in the centre
  (see `docs/behaviour/stores.md` for when the saved place is used). macOS doesn't restore it.
- The window's position is saved 500 ms after the last move or resize, at once when a live resize
  ends, and at once when the window closes. Full screen, the borderless mode and a zoomed window
  give no new normal bounds.
- The display mode is Window, Borderless or Fullscreen. Borderless changes at once. A native full
  screen change follows the full-screen callbacks of AppKit, so it ends when AppKit reports the
  new state or a failure. A failed enter leaves the window in Window, and a failed exit keeps it
  in Fullscreen. During a change, the menu and the file keep the mode from before the change.
- One change runs at a time, and a request that comes during a change waits. A newer request
  replaces the waiting one, and a second toggle cancels a waiting toggle.
- The Fullscreen toggle goes back to the mode before the full screen, or else to Window, and it
  reads the mode when it starts rather than while it waits. The green button and Esc change the
  mode without any request. AppKit only changes the full screen of a window that's showing, so a
  full-screen request for a hidden or minimised window does nothing.
- Each new mode is saved. The View menu shows the mode, because AppKit checks the View items
  every time the menu opens.
- With a test home, the window shows without taking the focus, and it never takes it. A headless
  test home (`BIFROST_TEST_HEADLESS=1`) shows no window and no Dock icon, and counts as visible
  and focused. A test home never applies a saved full screen.

## The side bar and layouts

The side bar on the left gives quick access to the Overviews, the Selected Item, the other
panels, the two session actions that need no row, the minimised frames and the layouts the user
has saved.

- The Overview button focuses the top Overview that's showing, or else a minimised one, or else
  opens a new `overview:1`.
- The New Overview button below it opens another Overview, with the lowest number from 1 to 99
  that isn't in a frame yet. A minimised frame or a back tab of a stack still counts as in a
  frame, and closing an Overview frees its number. With all 99 open, the button is greyed out at
  40 % and does nothing. Each Overview keeps its own tabs, so you can, say, keep one on your
  working sessions and another on the ones waiting for you.
- The Selected Item button opens the Selected Item panel, or brings it to the front.
- Next come the panel buttons, in the same order as in the Electron app: the Watchlist, the Event
  log, the Usage HUD, Service status, Reviews, the Daily update and Performance. Each opens its
  panel, or brings it to the front and restores it if it's minimised. Reviews, the Daily update
  and Performance also show a small dot on their button while something there needs you; their
  own pages (`reviews.md`, `daily-update.md` and `health.md`) say when.
- After a separator come New session and Resume all, the session actions that don't need a row
  (`docs/behaviour/actions.md`). Each button shows the state the action model gives it: Resume
  all is greyed out while it runs or when no parked session was running at the last close, and
  its tooltip then gives the reason on a second line. The labels follow the label set, so with
  the space labels they read Launch and Reactivate all. A click on a greyed-out button does
  nothing. While a dialog is open, both buttons are greyed out with no reason, because the
  dialog's backdrop covers only the canvas and not the side bar.
- Below those come the minimised frames in z-order, after a second separator that only shows
  while a frame is minimised.
- Named layouts save the current layout, up to 20 of them, with names of 1 to 40 characters. Two
  names are the same when they're equal Swift strings, so two forms of one accented letter are
  one name. Loading a name that doesn't exist does nothing.
- A chat or Show Info panel takes the name of its session's row as its title. An Overview's title
  is followed by the name of its tab set in brackets, in the dim text colour, as in "Overview
  (Default)" or "Overview 2 (Waiting)", so two Overviews are easy to tell apart. The name shows in
  the frame's title and in its tab of a stack, and a rename in the Panel menu shows straight away.
  The side bar's buttons for minimised frames show the title alone.

## The Overviews and the dialog history in the UI state

Besides the layouts, ui-state.json keeps the config of each Overview and the history of the New
session dialog. `UIState` in `BifrostLayout` holds both as plain JSON, because the types that know
their rules live in modules that come after it: `OverviewConfig` in `BifrostWindows` and `History`
in `BifrostSessions`. `overviewConfig`, `updateOverview` and `dialogHistory`
(`BifrostWindows/Model/UIStateValues.swift`) read and write them through those types.

- Each config sits under the panel ID of its Overview. Loading drops a key that isn't an
  `overview:<n>` ID, and an `overviews` value that isn't an object gives no configs at all. A save
  writes the keys in sorted order, and leaves out `overviews` when there are no configs.
- An Overview with no saved config, or with one that the Overview rules can't read, shows the
  standard config, and its first change starts from there. The other configs, the layouts and the
  history all survive a config that can't be read.
- A change saves only the config of its own Overview, and a change that has no effect saves
  nothing. So a config that can't be read stays in the file as it came until its own Overview
  saves over it. `docs/behaviour/overview.md` covers what a config holds.

The dialog history remembers what you used last, so the next new session starts from it:

- It keeps up to 10 recent folders, newest first, and the model and permission mode of the last
  session you started. The model is Default, Opus, Sonnet or Haiku, and the mode is acceptEdits,
  auto, manual, dontAsk or plan, or none for Claude Code's own default.
- It also keeps up to 8 recent slash commands, newest first. Running a command puts its trimmed
  text at the top, and text that Settings wouldn't accept as a slash command isn't remembered.
- On load, each list keeps its first good entries, without repeats, up to its limit. A folder has
  to start with `/`, and a command has to pass the slash command check of Settings with no spaces
  at its ends. An unknown model or mode falls back to the default, a value that isn't an object
  gives an empty history, and fields this app doesn't know are kept.
- The dialog offers the recent folders first and then each session's project folder (the
  repository, for a folder in a Claude worktree), up to 10 in all and without repeats.
- Two folders or commands match when they're equal strings, so two forms of one accented letter
  count as one entry. The 200-character limit of a command counts an emoji or an accented letter
  as one character, as Settings does.

Some Electron pieces belonged to the web page and weren't carried over: the shape of the React
reducer, the page zoom in CSS pixels, the DOM drag events and the effects that followed the
layout. AppKit events and the layout model do those jobs. The model sends each change to one
receiver, which passes it on in a fixed order: the canvas, then the chats, then the UI store.
