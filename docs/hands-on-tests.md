# Hands-on tests

This is the checklist for testing the real app by hand at the end of phase 4. It covers what only
a person at the Mac can judge: things you see or hear that the automated tests can't check. Most
lines come from a row in one of the `docs/ports/*/DELIBERATE-DIFFERENCES.md` tables that's marked
for the hands-on test or for a check by hand, and each of those links to its row so you can read
what changed and why. The few lines with no link are general checks. A line that depends on a
later part of phase 4 says so.

Every line that stops, deletes, resumes, renames, sends to or takes control of a session uses a
session whose name starts with `bifrost-test-`, so a slip never touches real work. Start those
sessions with New session, and give each new session a `bifrost-test-` name.

## Windows and layout

- [ ] Set the Interface scale to 90, 100 and 150 percent in turn, and look at the title bars, a
  stack of tabs (including one with more tabs than fit), the dictation meter and a dictation
  notice with its button. At each scale they should look as they did before the layout pass
  change, with the text, the buttons and the line under the active tab in the same places.
- [ ] Click between two frames and look at the cyan glow above the top edge of the frame on top.
  It should be a soft haze that fades upwards and out towards both ends of the edge, with no hard
  sides, as in the Electron app. ([windows W20](ports/windows/DELIBERATE-DIFFERENCES.md))
- [ ] Ask a `bifrost-test-` session something that takes a while, and while Claude answers, click
  the empty background of the canvas and press Esc. The chat frame should lose its focus look
  (the glow and the darker fill fade out), Settings should open, and Claude should keep
  answering. Try a right-click on the background too. Then click the chat: it should get its
  focus look back, and what you type should go to the session again.
  ([windows W21](ports/windows/DELIBERATE-DIFFERENCES.md))
- [ ] With the chat focused, click another app such as Finder, then click the empty background of
  Bifrost once and press Esc. Settings should open and Claude should keep answering. Then click
  another app again and click once on a frame: Bifrost should only come to the front, and the
  frame's focus should stay as it was. ([windows W21](ports/windows/DELIBERATE-DIFFERENCES.md))
- [ ] Open the Panel menu of a frame. It should be a dark Bifrost box with a border, 208 units
  wide, just below the menu button and lined up with its right edge. Compared with the Electron
  box, its rows are tighter (20 high, where the Electron box had a padding and gaps of 12) and
  the row under the pointer has a stronger highlight. Lock should show the square check box: an
  empty box while the frame isn't locked, and a box with a check mark while it is. Lock should
  lock and unlock the frame without closing the menu, and a click outside the menu, Esc or a
  second press on the button should close it.
  ([windows W10](ports/windows/DELIBERATE-DIFFERENCES.md))
- [ ] Press the menu button of a frame and keep the button down: the Panel menu should open at
  once. Drag to Lock and let go: the frame should lock.
  ([menu M9](ports/menu/DELIBERATE-DIFFERENCES.md))
- [ ] Move a frame to the right or bottom edge of the window and open its Panel menu. The menu may
  hang outside the window there, but it should stay fully on the screen.
  ([menu M1](ports/menu/DELIBERATE-DIFFERENCES.md))
- [ ] Open the Layouts popover from the side bar. It should be a system popover to the right of
  the button, with an arrow and rounded corners, and it should sit comfortably next to the
  button. ([windows W11](ports/windows/DELIBERATE-DIFFERENCES.md))
- [ ] In a frame with several tabs, scroll a panel or change a control in it, then switch to
  another tab and back. The panel should keep its scroll position and the state of its controls.
  ([windows W12](ports/windows/DELIBERATE-DIFFERENCES.md))
- [ ] Turn on Full Keyboard Access in System Settings and press Tab to move around the window. The
  title bar buttons, the tabs and the side bar buttons should show the system focus ring.
  ([windows W13](ports/windows/DELIBERATE-DIFFERENCES.md))
- [ ] Minimise a frame whose active panel is a chat. The minimised frame should show the chat
  icon. ([windows W14](ports/windows/DELIBERATE-DIFFERENCES.md))
- [ ] Drag a frame by its title bar, and resize one by an edge, passing over the edges of other
  frames and over a terminal. The cursor should stay the one you started with until you let go.
  ([windows W15](ports/windows/DELIBERATE-DIFFERENCES.md))
- [ ] Quit Bifrost, edit ui-state.json so that a frame has a position or size with half units
  (such as 100.5), then start Bifrost again. The frame should show fully inside the canvas, at
  most 1 unit higher or further left than the Electron app would put it.
  ([windows W16](ports/windows/DELIBERATE-DIFFERENCES.md))
- [ ] Save a layout with a name of 40 emoji. It should save, where the Electron app refused more
  than 20. Then save a layout whose name is an existing name with its accented letters in the
  other Unicode form (for example é pasted as e plus a combining accent). It should replace that
  layout rather than add a second one. ([windows U5](ports/windows/DELIBERATE-DIFFERENCES.md))
- [ ] If a full-screen change ever seems stuck, press the green button. The window should go into
  or out of full screen, and the next full-screen request should work.
  ([shell D2](ports/shell/DELIBERATE-DIFFERENCES.md))
- [ ] Press the Fullscreen key (Cmd+Control+F) quickly, many times, during the full-screen
  animation. The window should end in a clear mode, and the green button should still work
  afterwards. ([shell D5](ports/shell/DELIBERATE-DIFFERENCES.md))
- [ ] Minimise the window and press the Fullscreen key. Nothing should happen, and when you bring
  the window back it should be in the mode it was in before.
  ([shell D6](ports/shell/DELIBERATE-DIFFERENCES.md))
- [ ] Switch to Borderless, then change the resolution of the display, or plug in or unplug a
  second display. The window should cover its screen again each time, with no gap and nothing off
  screen. ([shell H7](ports/shell/DELIBERATE-DIFFERENCES.md))
- [ ] Put macOS in light mode and open About Bifrost Dev. The About panel should be dark, like the
  rest of the app, and so should an update window of Sparkle once updates are on.
  ([shell H8](ports/shell/DELIBERATE-DIFFERENCES.md))
- [ ] Look at text in the interface that has arrows, key symbols such as ⌫ and ⏎, maths signs,
  circled digits or Greek letters. They should draw in Geist Mono, matching the text around them,
  and small text should still look crisp. ([look F2](ports/look/DELIBERATE-DIFFERENCES.md))
- [ ] Start with no saved layout (a new test home). The Overview should be at the top left and
  the Selected Item to its right, 16 apart and lined up at the top.
- [ ] Look at the side bar: Selected Item should sit below New Overview, then a line, then New
  session and Resume all, with a second line above the minimised frames only while a frame is
  minimised. With no parked session to resume, Resume all should be faded, and resting on it
  should show "Resume all" and the reason on a second line. With Full Keyboard Access on, Tab
  should skip the faded button. ([windows W19](ports/windows/DELIBERATE-DIFFERENCES.md))

## Keys and menus

- [ ] Close every panel, or minimise every frame, and open the Window menu. Close Panel should be
  grey, and Cmd+W should do nothing. Then close the window and check that Window, Borderless and
  Fullscreen in the View menu are grey too. ([shell M4](ports/shell/DELIBERATE-DIFFERENCES.md))
- [ ] Look at the side bar: below New Overview (and Selected Item, once it's there) should come
  the Watchlist, Event log and Usage HUD buttons, each with its icon and its tooltip. Click each
  one, then press Cmd+L and Cmd+U. Each should open its panel, bring it to the front when it's
  already open, and bring it back when its frame is minimised.
- [ ] In a chat, press Option+Left and Option+Right in Claude Code's prompt. The cursor should
  move one word at a time. Option+Up and Option+Down should act like plain Up and Down, and
  Option+Tab shouldn't do anything surprising.
  ([chat C16](ports/chat/DELIBERATE-DIFFERENCES.md))
- [ ] Use a chat as you normally would: type, press Enter, Shift+Enter, Esc, Control+C, the arrows
  and Backspace, and check that each works in Claude Code. Then press Cmd with a letter that
  nothing uses, such as Cmd+K. Nothing should appear in the prompt.
  ([chat C17](ports/chat/DELIBERATE-DIFFERENCES.md))
- [ ] Send to a `bifrost-test-` session that's still starting, or press Interrupt on a
  `bifrost-test-` session while a send to it is waiting. The send box should show a plain
  sentence, such as "The session is still starting. Try again in a moment.", rather than a
  `refused:` text. ([input I14](ports/input/DELIBERATE-DIFFERENCES.md))
- [ ] On a `bifrost-test-` row, try the session keys: Cmd+Ctrl+3 and then 0 on its own should set
  and clear the priority, C should copy the session ID, Cmd+Shift+O should open the folder in the
  default project app, R should open Rename, and Backspace should stop the session, asking first
  while it works. Click in that session's chat and press Cmd+Ctrl+2: the priority should change
  on that row. Hold 4 and click another row: that row should get priority 4 and the selection
  should stay. Cmd+N should open New session.
- [ ] Make sure that the only parked sessions in the Overview are `bifrost-test-` sessions, since
  a Resume all that got through would resume every one of them. Then open a dialog, such as the
  confirmation of Stop on a working `bifrost-test-` row. New session and Resume all in the side
  bar should be faded and do nothing when clicked. With Full Keyboard Access on, Tab out of the
  dialog's last field and press Backspace, C and Cmd+N: none of the session keys should do
  anything until the dialog closes.
  ([actions X23](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Select a `bifrost-test-` row, click into the send box of the Selected Item and type a draft,
  then press Esc. The focus should leave the box with the draft still in it, and a second Esc
  should open Settings.
- [ ] Turn on VoiceOver and open the Panel menu, then move through it with the arrow keys.
  VoiceOver should call it a menu, read Lock as a menu item that's checked or not, and say when
  the menu opens and closes. Then move the pointer over the rows: each should read as a menu item.
  ([menu M2](ports/menu/DELIBERATE-DIFFERENCES.md))
- [ ] Hold the dictation key in a chat until dictation starts, then click the Panel menu button
  of that chat's frame with the key still down, and let go of the key. Dictation should stop, and
  the menu should stay open.
- [ ] With the animated background on, open the Panel menu of a chat frame. The background should
  keep moving while the menu is open, and after Esc typing should go straight back into the chat.
  Then open the Panel menu of an Overview and type in its name field: the background may pause
  while the field edits, and should move again once the highlight leaves the field.
  ([menu M4](ports/menu/DELIBERATE-DIFFERENCES.md))
- [ ] Open the Panel menu of an Overview and press Cmd+W: the menu should close along with the
  panel. Open it again, type in the name field, then use Paste, Cmd+Z and Emoji & Symbols
  (Ctrl+Cmd+Space). The menu should stay open each time, keep the typed name, and the emoji
  should land in the field, not in a chat. ([menu M8](ports/menu/DELIBERATE-DIFFERENCES.md))
- [ ] Open the Panel menu of a chat frame, press Cmd+Tab to another app, then come back to
  Bifrost. The menu should be closed, and typing should go to the chat.
  ([menu M8](ports/menu/DELIBERATE-DIFFERENCES.md))
- [ ] Open the Panel menu and drive it with the keys only: Up and Down should move the
  highlight, Space should toggle Lock, Tab should do nothing, and Esc should close the menu.
  ([menu M5](ports/menu/DELIBERATE-DIFFERENCES.md))

## Chats and terminals

- [ ] In a chat, Cmd+click a link that Claude Code prints, and then a plain URL in the text. Both
  should open. A plain click on a link should go to Claude Code instead.
  ([chat C10](ports/chat/DELIBERATE-DIFFERENCES.md))
- [ ] Copy some text in Claude Code, for example by dragging to select it, then paste it into
  another app. The text should be on the clipboard.
  ([chat C18](ports/chat/DELIBERATE-DIFFERENCES.md))
- [ ] Option+click in Claude Code's prompt. The prompt's cursor shouldn't move. Option+drag should
  make a normal text selection. ([chat C19](ports/chat/DELIBERATE-DIFFERENCES.md))
- [ ] After a session's attach ends and the chat shows the normal screen with a scroll bar, look
  at the scroll bar. The knob should be about 15 points wide, dim at rest and brighter under the
  pointer, and it should keep that brighter colour while you drag it.
  ([chat C21](ports/chat/DELIBERATE-DIFFERENCES.md))
- [ ] When a chat can't attach, for example because another row shares its short ID or its row
  changes during the open, the end line should read `[open failed: ...]` with a plain sentence,
  such as "This window is for another session. Open the chat again.", not a `refused:` text.
  ([chat C24](ports/chat/DELIBERATE-DIFFERENCES.md))
- [ ] Take control of an external `bifrost-test-` session. Its chat window should open at once
  with "Taking control of <name>..." and a soft band in the bottom two fifths, fading in from
  nothing at its top edge and drifting slowly from side to side. Its colours should match the
  base gradient of the window background: green, blue, violet and red. The yellow and orange
  glows of the background fields aren't in the band.
  The loader should go as soon as Claude shows in the terminal. Turn on Reduce motion (System
  Settings > Accessibility > Display) and take control again: the band should stay still.
  ([chat C25](ports/chat/DELIBERATE-DIFFERENCES.md))
- [ ] Open the chat window of an external `bifrost-test-` session, then take control of it. When
  the takeover is done, the same window should show the session by itself, with no need to close
  it and open it again. Try it once more from the row menu with no chat window open: the window
  that Take control opens should also show the session at the end.
  ([chat C26](ports/chat/DELIBERATE-DIFFERENCES.md))

## Links

These all use file links that Claude Code prints in a chat; ask it to link the file if you need
one. What opens can depend on the default apps of your Mac.

- [ ] Cmd+click a link to a program, an alias file or a package. Bifrost should show it in Finder
  rather than start the program or open the package.
  ([pty T14](ports/pty/DELIBERATE-DIFFERENCES.md))
- [ ] Cmd+click links to `.tcsh`, `.pm`, `.rbw`, `.exe`, `.ipa`, `.pyc`, `.url`, `.wflow`,
  `.mobileconfig`, `.jnlp` and `.safariextz` files, and to a plain file with a bundle extension
  such as `.saver` or `.rtfd`. Each should show in Finder rather than open in its default app.
  ([pty T14](ports/pty/DELIBERATE-DIFFERENCES.md))
- [ ] Cmd+click links to a `.js`, a `.class` and a `.swift` file. Source code should open in its
  default app, unless that app would run it (a terminal such as Warp or Terminal, or Java
  Launcher), in which case Finder shows the file instead.
  ([pty T14](ports/pty/DELIBERATE-DIFFERENCES.md))
- [ ] Cmd+click a link to a `.cer` certificate. Finder should show it, rather than Keychain Access
  opening it. ([pty T14](ports/pty/DELIBERATE-DIFFERENCES.md))
- [ ] In Finder, give one `.md` file its own Open With app in Get Info (without Change All), then
  Cmd+click a link to it. Finder should show the file rather than open it in that app.
  ([pty T14](ports/pty/DELIBERATE-DIFFERENCES.md))
- [ ] Cmd+click a link to a file that no app opens, such as `notes.xyzzy`. macOS should ask which
  app to use. ([pty T14](ports/pty/DELIBERATE-DIFFERENCES.md))
- [ ] Cmd+click a link to a plain folder whose name looks like a script, such as `tools.sh`. It
  should open in Finder as a folder. ([pty T14](ports/pty/DELIBERATE-DIFFERENCES.md))

## Dictation

- [ ] Hold the dictation key in a chat and talk. Compare the green top border, its shadow and the
  glow with the approved mock. The shadow above the border should fade out towards both ends with
  no hard sides, and the glow below it should be a soft hump over the middle of the title bar.
  While you speak, the hump should grow a little higher, brighter and wider than in the mock,
  and drop back quickly between words. In a quiet room it should look as in the mock. Small
  differences in the blur are expected.
  ([dictation D22](ports/dictation/DELIBERATE-DIFFERENCES.md))
- [ ] Leave Bifrost idle for more than 5 minutes so the speech engine is released, then click
  into a chat and straight away hold the dictation key for just over a quarter of a second. The
  microphone indicator in the menu bar shouldn't light up.
  ([dictation D14](ports/dictation/DELIBERATE-DIFFERENCES.md))
- [ ] Dictate a sentence, let go, then quickly hold and release the key again while the first
  dictation is still finishing. The microphone indicator shouldn't light up for that second short
  hold. ([dictation D24](ports/dictation/DELIBERATE-DIFFERENCES.md))
- [ ] Dictate in a chat, then close the main window. The microphone indicator should go off at
  once. Reopen the window and hold the key again. Dictation should work, though the green look
  can take a little longer to appear while the model loads again.
  ([dictation D19](ports/dictation/DELIBERATE-DIFFERENCES.md))
- [ ] Turn on VoiceOver, hold the dictation key in a chat, and move the VoiceOver cursor to the bar
  next to the mic in the title bar. It should read "Voice level" as a level indicator, with a
  value that follows your voice. ([dictation D26](ports/dictation/DELIBERATE-DIFFERENCES.md))
- [ ] On a Mac without the speech model, hold the dictation key so the download starts, then cut
  the network. After 2 minutes on the same percent, the chat should say that Bifrost can't get
  the speech model right now. Turn the network back on and hold the key again, and the download
  should start again. ([dictation D27](ports/dictation/DELIBERATE-DIFFERENCES.md))
- [ ] Only if you have a macOS 26 Mac where Apple's `SpeechTranscriber` isn't available: hold the
  dictation key there. The chat should say "Dictation isn't available in this build of Bifrost."
  ([dictation D13](ports/dictation/DELIBERATE-DIFFERENCES.md))
- [ ] Hold the dictation key and talk, then plug in or pick another microphone while you keep
  talking. The text should carry on.
- [ ] Dictate a few sentences while a big build runs. No words should be lost.

## Sessions

- [ ] Rename a `bifrost-test-` session to a name of 64 emoji, with "Also rename it in Claude Code"
  off, then rename it back. The emoji name should fit, where the Electron app refused more than
  32. ([registry D4](ports/registry/DELIBERATE-DIFFERENCES.md),
  [input I13](ports/input/DELIBERATE-DIFFERENCES.md))
- [ ] Send a `bifrost-test-` session a message that ends with a zero-width no-break space (U+FEFF,
  pasted in). The message should keep it. ([input I13](ports/input/DELIBERATE-DIFFERENCES.md))
- [ ] In the New session dialog, type a name of 64 emoji. The dialog should accept it, where the
  Electron app refused more than 32. Then choose a folder whose name is 50 emoji: the suggested name
  should start with 40 of them, where the Electron app kept 20. Cancel the dialog rather than start
  a session with either name.
  ([actions X4](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Try Take control on a `bifrost-test-` session in a terminal while you quit that session's
  `claude` at the same moment. If the session had already ended, Take control should go on and
  resume it rather than show "Bifrost couldn't stop the terminal session" or "isn't a Claude
  process". ([actions X7](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] In the row menu and the Selected Item panel, look at Hand over for a working `bifrost-test-`
  session. It should be off, and its tooltip should say "Wait until the session is idle." Once the
  session is idle, it should be on. "Hand over" at the end of this list has the full check.
  ([actions X2](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] If New session ever fails because Claude Code printed no session ID, read the notice. It
  should say "Claude Code didn't give the new session an ID. Try again in a moment.", with no
  command in it. ([actions X10](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] If a session action ever fails because a `claude` command failed, read the notice. It should
  be plain text, with no escape codes and no command line.
  ([actions X9](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] From the row menu of a `bifrost-test-` row, use Open project with each app it lists: the
  folder should open in that app. Use Open in terminal on a `bifrost-test-` session with Warp or
  Terminal and then with iTerm2 or Ghostty as the terminal app; with Ghostty or iTerm2 not running,
  Bifrost should start the app and copy the command. Use Open the worktree in the Delete dialog of a
  `bifrost-test-` worktree session, then cancel the dialog. Each should open as it did in the
  Electron app, and the worktree should open in a Finder window. Then start a `bifrost-test-`
  session in a scratch folder, rename the folder, and use Open project on it: the error should be a
  plain sentence from macOS. Last, start a `bifrost-test-` session in an empty scratch folder named
  `scratch.app`, and use Open project with Finder on it: Finder should show the folder selected, and
  nothing should start. ([actions X14](ports/actions/DELIBERATE-DIFFERENCES.md),
  [actions X27](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Make sure that the only parked sessions in the Overview are `bifrost-test-` sessions, because
  Resume all resumes every parked session that was running at the last close. Then try New session
  (naming each new session `bifrost-test-...`), Stop, Resume and Resume all, each on
  `bifrost-test-` sessions, and double-click New session and Resume all: each double click should
  start only one job. Then open Console, filter on the `sessions` category, and check that each
  command left one line saying that it ended or why it didn't, with a one-word reason such as
  `creating` for the second click of New session, and that Resume all added a line for each
  session it couldn't resume.
  ([actions X20](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Try Delete and Take control on `bifrost-test-` sessions only. Delete a running session and a
  parked one: each should leave the list and `claude agents`. Delete a worktree session with a
  commit that's on no remote: after the dialog shows the commit and you confirm twice, the worktree
  should go. Delete a running worktree session with an edited file: it should be refused before the
  session stops. Delete one of two sessions that share a worktree: it should leave the list and the
  folder should stay, and deleting the second should remove both from `claude agents`. Then take
  control of an idle `bifrost-test-` session in a terminal: its `claude` should end there and the
  session should carry on in Bifrost. Console should have a line from the `sessions` category for
  each command. ([actions X7](ports/actions/DELIBERATE-DIFFERENCES.md),
  [actions X20](ports/actions/DELIBERATE-DIFFERENCES.md),
  [actions X21](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Start Delete on a `bifrost-test-` worktree session with a large worktree (for example with an
  installed `node_modules`), and quit Bifrost while it runs. Before you start Bifrost again, wait
  until no `claude rm` runs any more, for example until `pgrep -fl "claude rm"` shows nothing: the
  lock that keeps other actions away from the session only lives in memory, so a new Bifrost
  wouldn't know about the old `claude rm`. Then start Bifrost again: the session should either be
  gone with its worktree, or still be listed with its worktree whole, never half deleted.
  ([actions X21](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Open the Delete dialog of a `bifrost-test-` worktree session with one commit that's on no
  remote. While the dialog is open, amend that commit in a terminal, then confirm twice. The Delete
  should stop with "The worktree changed after the check. Check it again, then delete." and the
  worktree and its commit should still be there.
  ([actions X22](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Make a scratch git repository in a folder under `~/.bifrost-native-dev/reviews/repos`. From
  a terminal in that repository, start a `bifrost-test-` session with a worktree, for example
  `claude --bg --worktree bifrost-test-review --name bifrost-test-review`, because New session
  offers no worktree in a review folder (if Claude Code asks you to trust the folder, run `claude`
  there once and accept). Start Delete on that session in Bifrost. The dialog should say that
  Bifrost couldn't check the session for unmerged work, and the delete should need a second click.
  Cancel it. ([actions X16](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Look at the row icon of an external session in the Overview, with the session running in
  Warp, Terminal and iTerm2 in turn. Each should be the app's own icon, as Finder shows it, and not
  a plain square. ([actions X18](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Watch the session rows while `bifrost-test-` sessions start, finish and get renamed. The rows
  should update straight away. Once phase 4e brings the Usage HUD, it should also show a new row
  name as soon as you rename. ([registry D24](ports/registry/DELIBERATE-DIFFERENCES.md))
- [ ] Start a session in a folder whose `.git` is a symbolic link to another repo's `.git` folder,
  inside an outer repo that's on another branch. The row should show the linked repo's branch,
  not the outer repo's. ([registry D26](ports/registry/DELIBERATE-DIFFERENCES.md))
- [ ] If the session list ever fails to load, for example while Claude Code updates itself, look
  at the error line of the Overview. It should give a short, friendly reason with no raw error
  text or path, and Console should have the details in one line from the `sessions` category.
  ([registry D27](ports/registry/DELIBERATE-DIFFERENCES.md))
- [ ] Right-click a `bifrost-test-` row in the Overview. The row menu should be a Bifrost menu at
  the pointer, with its entries in three groups. Rest on a greyed-out entry: its tooltip should
  give the title and the reason. Open Set priority: the current priority should have a tick, and
  each number its colour square. Pick a priority, and the row should change. Open the menu again
  and click another row: the menu should close, and the other row shouldn't be selected.
- [ ] Open the row menu of a `bifrost-test-` row and rest on Set priority until its submenu opens.
  Then move the pointer diagonally towards the submenu, across the rows below Set priority: the
  submenu should close as soon as the pointer is over another row. Resting on Set priority for a
  moment should open it again. ([menu M7](ports/menu/DELIBERATE-DIFFERENCES.md))
- [ ] Choose Delete session... on a `bifrost-test-` row whose worktree has a commit that isn't
  merged. The notice line should say "Checking for unmerged work..." first, then the dialog
  should name the work, with Open worktree on the left. Open worktree should show the worktree in
  Finder and keep the dialog. Click the confirm button once: it should change to "Delete anyway",
  and a fast second click should do nothing. Press Esc, and nothing should be deleted. The canvas
  should be dimmed while the dialog shows, and the side bar should not.
  ([actions X23](ports/actions/DELIBERATE-DIFFERENCES.md),
  [actions X24](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] With a dialog open, try to open another one (Rename from the row menu, or New session from
  the side bar). It shouldn't open, and the notice line should say "Another dialog is open.
  Finish that one first." ([actions X23](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Rename a `bifrost-test-` row with the check box off, keeping the `bifrost-test-` start of the
  name: the name should change in the row at once. Tick "Also rename it in Claude Code" and save,
  again with a `bifrost-test-` name: the session should get `/rename` and the
  row should show the new Claude Code name. Click the dimmed canvas while the dialog shows, and it
  should close with no change.
- [ ] Open New session. The Recent menu should list your recent folders, and Choose... should
  open the macOS folder panel at the folder in the field. Pick a folder with no git: the worktree
  check box should be grey, and resting on it should give the reason. Give the session a
  `bifrost-test-` name. In the prompt, Shift+Return should add a line, Option+Return and
  Control+Return should do nothing, and a plain Return should start the session. With a Japanese
  or Chinese input method, the Return that ends a composition should only end it. The plain
  Return should close the dialog straight away (the next line checks what follows). The Recent,
  Model and Permission mode pickers are standard macOS pop-up menus, not Bifrost menus, which is
  fine for now. ([actions X26](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Start a `bifrost-test-` session with New session. The dialog should close the moment you
  start, and the Overview should show a "Starting…" row with the name and the project after its
  other rows. When Claude Code has the session, a few seconds later, the real row should take its
  place, and a few seconds after that the row should be selected with its chat open. Then start
  one in a new empty folder that Claude Code has never been trusted in: the dialog should close as
  before, then the Starting… row should go, and the error line should say "<name> didn't start."
  with the trust reason. ([actions X75](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Turn on Full Keyboard Access in System Settings and open each dialog. Tab should reach every
  button and check box, and Space should press the one with the focus. Hold Backspace in the
  Rename name field: it should delete one character after another. In the Delete dialog of a
  `bifrost-test-` session, Return should do nothing. While a Rename of a `bifrost-test-` session
  with "Also rename it in Claude Code" saves, press Cmd+F or Esc: no Bifrost key should act
  behind the dialog, and Settings should not open.
  ([actions X24](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Start a `bifrost-test-` session in a worktree that has a commit that isn't merged. In a
  terminal, run an interactive `claude` in that worktree folder, so it shows as a second session
  in the same folder. Choose Delete session... on the `bifrost-test-` row: the dialog should say
  that Bifrost keeps the folder. While the dialog is open, quit the `claude` in the terminal and
  wait until its row goes, then confirm: a second dialog should name the unmerged work of the
  worktree.
  ([actions X28](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Give a `bifrost-test-` session a project folder that is a file, or a link to a file (for
  example by editing its folder in a test home). Open project should refuse it with "... isn't a
  folder, so Bifrost didn't open it." in the error line, and nothing should open or run.
  ([actions X27](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Make sure that the only parked sessions in the Overview are `bifrost-test-` sessions, then
  click Resume all. While it runs, open the row menu of a session it's resuming: Stop session and
  Delete session should be grey with "Another action is still running on this session." Keep the
  menu open: once Resume all has finished, they should turn on by themselves.
  ([actions X25](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Select a `bifrost-test-` row and look at the Selected Item panel. The name line should show
  the row icon, the name (resting on it gives the local and the Claude Code names), the state in
  its colour and the priority, and the facts should read Project, Branch, Model with its coloured
  context bar, and Cost. Press Tab around the window: none of the panel's buttons should take the
  focus, only the send box. Click the eye button: the colour menu should open just below it,
  lined up with its left edge, and a colour should add the row to the watchlist.
  ([actions X29](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Type a draft in the send box of one `bifrost-test-` row, select another row and come back:
  the draft should still be there, and also after you close the panel and open it again.
  Shift+Enter should add a line, and Enter should send the draft, as should Option+Enter.
  Cmd+Enter should open the row's chat instead (Open). Make the panel's frame low: the panel
  should scroll, with no bounce when its content fits. Choose Run slash command >
  Other... in the row menu: the box should take the focus with `/` in it, and the status icon
  should say "This runs as a slash command."
  ([actions X30](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Have two `bifrost-test-` rows, the second at row 2 of the Overview. Type in the send box of
  the first, then press Cmd+2 and at once type only `a`, `e` and `s` (these have no session key).
  The send box should lose the focus at once, the second row should be selected, and neither
  draft should get the letters. ([actions X30](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Quit Bifrost Dev with the Selected Item panel in the layout, then start it again. The panel
  should be empty for a moment and then show its content as soon as the Overview lists the
  sessions. It should never show "This panel comes in a later build of Bifrost Dev."
  ([actions X32](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] In a terminal, run `sleep 5; claude rm <short id>` for a parked `bifrost-test-` session.
  Straight away, right-click that session's row and don't touch the Mac until the row leaves the
  Overview, which can take up to about 60 seconds: the menu should close with it. Do the same
  again, but right-click a different `bifrost-test-` row this time: that menu should stay open
  when the other row goes.
- [ ] Open the chat of a `bifrost-test-` session and another one, then choose Stop session on the
  first: its chat window should close and the other chat should stay. Make a Stop fail if you can:
  the window should stay with the message. Kill a session's process by hand: its window should stay
  with the closing line. ([actions X34](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Stop a `bifrost-test-` session and at once open its row menu. Delete session... should be
  greyed out with "Another action is still running on this session." Keep the menu open: when the
  row turns grey (parked), a second or two later, Delete session... should turn on in the open
  menu by itself. Choose it, and the Delete should work with no error. Then do the same with a
  second `bifrost-test-` session, using the Stop and Delete buttons of the Selected Item panel
  instead of the row menu. ([actions X33](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Set Labels to Space in Settings > General. The side bar's New session and Resume all
  tooltips, the Selected Item buttons and the row menu should switch to the space titles straight
  away, with no restart, and back again when you set Plain. Change the terminal app in Settings:
  Open project in the row menu should list the new terminal app.
- [ ] Use Open in terminal on a `bifrost-test-` session with Warp or Terminal as the terminal app,
  and quit Bifrost Dev within 30 seconds. Start it again: `~/.bifrost-native-dev/run` should hold
  no `attach-*.command` file once the Overview lists the sessions.

## Overview

- [ ] Click New Overview in the side bar. A second Overview should open with the title "Overview 2
  (Default)", the bracketed part dim, and renaming its tab set in the Panel menu should change the
  title straight away, in a tab of a stack too. Click the rows of the first Overview, then click the
  title bar of the second one to bring it to the top: the arrow keys, Cmd+1 and Tab should still act
  on the first one, the one whose rows you clicked. Then click a tab in the second Overview's tab
  bar: the keys should now act on the second one. Click into a chat and press Cmd+0: the Overview
  should come to the top with its rows focused. ([keys K8](ports/keys/DELIBERATE-DIFFERENCES.md))
- [ ] Rename two sessions to 👍🏽b and 👍a and sort the Overview by Name. The native app should put 👍a
  first, where the Electron app put 👍🏽b first. Ordinary names, with mixed case, accents and numbers
  such as s2 and s10, should sort as they did before.
  ([overview OV1](ports/overview/DELIBERATE-DIFFERENCES.md))
- [ ] Rename an Overview tab to 24 emoji and the tab set to 40 emoji. Both should be accepted, where
  the Electron app stopped at 12 and 20. ([overview OV6](ports/overview/DELIBERATE-DIFFERENCES.md))
- [ ] Fill an Overview with more sessions than fit and make it narrower than its columns. The scroll
  bars should be the system ones and follow your "Show scroll bars" setting, and scrolling should
  feel like any other Mac list. ([overview OV8](ports/overview/DELIBERATE-DIFFERENCES.md))
- [ ] In the same Overview, drag a column header past another. The header should move with the
  pointer and the other columns should make room, and the column should stay there when you let
  go, also after a restart. The kind column shouldn't move, and nothing should go in front of it.
  Drag the edge between two headers: the resize cursor should show and only the left column
  should change width, between 24 and 600 units. A plain click on a header should still sort it.
  Then look over the table at Interface scales of 90, 100 and 150 %: the rows, the sort mark, the
  watch stripe and the brackets of a boxed row should look like the Electron app's.
  ([overview OV9](ports/overview/DELIBERATE-DIFFERENCES.md))
- [ ] In the same Overview, rest the pointer on a Project cell and then on a row icon. Each should
  show its tooltip (the full folder, then the kind of session or the terminal app) after a short
  moment, in the same look as the tooltips of the side bar.
  ([overview OV10](ports/overview/DELIBERATE-DIFFERENCES.md))
- [ ] Right-click a tab of the Overview. The tab menu should be a Bifrost menu at the pointer, with
  Rename..., Filter, Columns, Reset, Move left, Move right and Remove tab. Each filter or column
  you choose should change the table at once and leave the menu open with the new tick, so you
  can change several. The rows of the Filter submenu, such as "Only watched sessions", should show
  their whole label. On a tab with its default columns and filter, Reset should be grey, and
  resting on it should show why. Control-click a tab: the same menu should open. Rename... should
  show the name field after the menu closes, and typing should go into it. Add tabs until they
  scroll, scroll the tab list sideways, and right-click a tab that was out of view: its own menu
  should open. With VoiceOver, the "Show menu" action of a tab should open the same menu below it.
  ([overview OV11](ports/overview/DELIBERATE-DIFFERENCES.md))
- [ ] Click a tab once: it should become active at once. Double-click a tab that isn't active: it
  should become active and show a name field with the name selected. Type a new name and press
  Enter, then do it again and press Esc, which should keep the name. After each, the arrow keys
  should move the selection in the rows again. Then rename and, instead of Enter, click another
  tab, the + button, the rows, the canvas and another app in turn: each should save the name.
  Last, double-click the active tab, type a name and press Enter: the tab should take the new
  name. No automated test reaches the double-click, because it depends on the order in which
  SwiftUI delivers the clicks, so this is the only check of it.
  ([overview OV12](ports/overview/DELIBERATE-DIFFERENCES.md))
- [ ] Open Overview Settings from the Panel menu of the Overview and click the Tab picker. It
  should open a system menu with a tick at the tab you're editing, and picking a tab should switch
  the Overview to it. ([overview OV13](ports/overview/DELIBERATE-DIFFERENCES.md))
- [ ] In the same panel, click a colour swatch, then press Left and Right. The colour should move
  along the swatches and wrap at the ends, the tab should change colour at once, the system focus
  ring should sit round the chosen swatch, and each swatch should show its colour name in a
  Bifrost tooltip. Then drag a column row up or down: the dragged row should fade, a line should
  show where it will land, letting go shouldn't change its box, and letting go far from the list
  should change nothing. A plain click on a box or its label should change only that box. The
  Kind row shouldn't drag, and resting on it should show why.
  ([overview OV14](ports/overview/DELIBERATE-DIFFERENCES.md))
- [ ] Make the Overview Settings frame short. Reset to default should stay in view below the
  columns, which scroll. ([overview OV16](ports/overview/DELIBERATE-DIFFERENCES.md))
- [ ] Open the Panel menu of an Overview. "Overview settings…" should sit above Lock and a "Tab
  set name" field below it. Click into the field, type a name and press Enter: the menu should
  stay open with the new name in the field, and an empty name should snap back to the old one.
  A typed letter should go into the field, not jump to a menu item. Esc should close the menu and
  keep the old name, and so should a click out of the field.
  ([overview OV15](ports/overview/DELIBERATE-DIFFERENCES.md))
- [ ] Find the row of a session that runs in a Warp tab (start one with `claude` if there's none).
  Its icon should be the Warp icon, and resting on it should say Warp. Then start a
  `bifrost-test-` background session with New session and run `claude attach <its short ID>` in
  Warp. Within a poll or two its row should show the Warp icon, and closing that Warp tab should
  bring back the Bifrost icon. A background session with no chat and no Warp tab should show the
  Bifrost icon too.
  Open the session's chat in Bifrost: the icon should turn into the Bifrost icon (Bifrost Dev's
  own icon in the development build) with the tooltip Bifrost, also while Warp still shows the
  session, and closing the chat should bring back the Warp icon. A parked session should keep the
  grey mark. ([overview OV18](ports/overview/DELIBERATE-DIFFERENCES.md),
  [registry D28](ports/registry/DELIBERATE-DIFFERENCES.md))
- [ ] Turn on VoiceOver and move through the rows of an Overview, then of the Watchlist. VoiceOver
  should say "selected" on the selected `bifrost-test-` row and on no other row, and selecting
  another row with a click or the arrow keys should move it. Press VO+Shift+M on a row: its row
  menu should open, and the selection should stay where it was. No row should show a blue system
  highlight. ([overview OV17](ports/overview/DELIBERATE-DIFFERENCES.md))

## Alerts

- [ ] Run Bifrost Dev on your real home, click into another app, and let a session that Bifrost
  started finish its turn. A notification titled with the session's name should say "Claude
  finished its turn.", and the very first one should ask whether Bifrost Dev may send
  notifications. Allow it, then click the notification: the window should come to the front and
  the session's chat should open.
- [ ] Close the main window, then let a session that Bifrost started need you, for example at a
  permission prompt. Click the notification: the window should open and then the session's chat,
  once.
  ([alerts A4](ports/alerts/DELIBERATE-DIFFERENCES.md))
- [ ] Let a session need you, once with the Bifrost window focused and once with another app in
  front. Each time you should hear the Ping sound once, at a normal volume, and it should sound
  like the Electron app's alert. ([alerts A1](ports/alerts/DELIBERATE-DIFFERENCES.md))
- [ ] Let a session ask a prompt with three questions, with another app in front. You should hear
  the Ping sound once and see one notification, not one for each page. Answer the prompt and let
  the session need you again after it works: that gives a new sound and a new notification.
  ([alerts A7](ports/alerts/DELIBERATE-DIFFERENCES.md))
- [ ] In Settings > General, turn Notifications off and let a session finish its turn with another
  app in front: no notification should show. Turn Red box sound off and let a session need you:
  no sound should play.
- [ ] Minimise the main window, let a session that Bifrost started finish its turn with another
  app in front, and click the notification. The window should come back from the Dock, and the
  session's chat should open.
- [ ] Turn notifications off for Bifrost Dev in System Settings > Notifications, then let two
  sessions finish their turns with another app in front. The Event log should show one line
  asking you to allow notifications for Bifrost, not two.

## Usage

- [ ] Open the Usage HUD and Show Info with macOS set to a 12-hour clock and another region in
  System Settings > General > Language & Region. Their times should still use the 24-hour clock
  and English day names, as in "Fri 13:00". A date in September shows "Sep", where the Electron
  app showed "Sept".
  ([usage US1](ports/usage/DELIBERATE-DIFFERENCES.md))
- [ ] Open the Usage HUD and leave it open for a minute. Each bar should show its label and
  percent on one line, a teal bar that turns amber above 70 %
  and red from 90 %, and the reset text under it, with
  the source line at the bottom, and the age in the source line should keep counting up.
  With account usage on, minimise the HUD, wait over a minute and bring it back from the side bar:
  the source line should soon say "updated 0 s ago". Then close the window and reopen it a minute
  later: the source line should again soon say "updated 0 s ago".
- [ ] With VoiceOver on, move through the Usage HUD. Each bar should read as one item, with its
  label, percent and reset text together.
  ([usage US10](ports/usage/DELIBERATE-DIFFERENCES.md))
- [ ] When a session or the account reaches 90 % of its 5-hour or 7-day limit, a notification
  titled like "5-hour limit at 92%" should show once for that period, also while the Bifrost
  window has the focus. With extra usage on for your account, the title should be "Warning: extra
  usage is on". Click it: the window should come to the front with the Usage HUD.

## Event log

- [ ] With Live details off in Settings, open the Event log from the side bar or with Cmd+L. It
  should say "No events yet." with the hint "Events come from Live details. Turn it on in
  Settings to see them here." under it. Turn Live details on in Settings: the hint should go,
  and "No events yet." should stay until the first event.
- [ ] Open the Event log with Live details on and use a session. Events should appear newest
  first, with a time such as 14:03:07.045, the session's name and the event with its tool in
  brackets. Click the Session filter: it should open a system menu with a tick at "All
  sessions", and choosing a session should show only its events.
  When a line from Bifrost shows (for example after macOS refuses a notification), its text should
  run across the session and event columns in white, and resting on it should show the whole text in
  a Bifrost tooltip. ([panels EL3](ports/panels/DELIBERATE-DIFFERENCES.md),
  [panels EL4](ports/panels/DELIBERATE-DIFFERENCES.md))

## Show Info

- [ ] Open Show Info from the row menu of a session on a branch with an open pull request. It should
  list the seven sections, and the PR line should say "Loading..." for a moment, then show the PR as
  "#12 Title (open)", underlined. Click the PR: it should open in your browser. Hover the copy
  button after the session ID: it should show the Bifrost tooltip "Copy session ID", and a click
  should put the session ID on the clipboard.
- [ ] Open Show Info for a review session. The PR line should say "This is a review session, so
  Bifrost doesn't run gh in its folder." Is that text clear?
  ([panels P1](ports/panels/DELIBERATE-DIFFERENCES.md))
- [ ] In Show Info, try to select the text of a folder path. It can't be selected, where the
  Electron app allowed it. Is that fine for daily use?
  ([panels P3](ports/panels/DELIBERATE-DIFFERENCES.md))

## Watchlist

- [ ] Add three sessions to the watchlist in different colours from their row menu, then open the
  Watchlist from the side bar. Each row should show the row
  icon, the name and the state on a faint tint of its colour, with a stripe of the full colour at
  the left edge. Click a row to select it, double-click one to open its chat, and right-click one:
  the row menu should offer Change colour and Remove from watchlist.
- [ ] Drag a Watchlist row down past another row. The dragged row should fade, a picture of the
  row should follow the pointer, a thin line should mark where it will land, and letting go
  should leave the list in the new order, also after a restart. Start another drag and press Esc
  before letting go: the row and the line should go back, nothing should move, and Settings
  shouldn't open. Drag a row out of the panel and let go: nothing should move.
  ([panels P5](ports/panels/DELIBERATE-DIFFERENCES.md))
- [ ] With nothing on the watchlist, the panel should say "Nothing on your watchlist yet.
  Right-click a session and choose Add to watchlist." Is that text clear?

## Reviews

These lines need a GitHub repository of your own for testing, and a second account (or a teammate)
to open PRs, ask for your review and leave comments. Bifrost names its own PR sessions
`<repo>-<number>-review` and `<repo>-<number>-request`. They belong to Bifrost, so stopping one on
a test PR is fine, but a session you start by hand still gets a `bifrost-test-` name.

- [ ] On one of your own PRs in a repository that has a git submodule, let a request round make a
  fix. Bifrost shouldn't commit or push it, and the row should say "Bifrost won't commit in a
  repository that has a submodule." Is that clear enough to act on?
  ([reviews R7](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] On one of your own PRs with between 21 and 50 checks (a matrix workflow works), make two or
  more checks fail. The row's cross should count every failed check, and the row shouldn't say
  "Bifrost read only the newest items of this PR." for the checks alone.
  ([reviews R34](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] After the first start of Reviews in Bifrost Dev, `~/.bifrost/reviews/state.json.before-native`
  should be there and match the state file that the Electron app left. A request round that the
  Electron app hadn't finished should show "Bifrost stopped this round before it finished. Choose
  Try again." on its row, and nothing of it should have been posted or pushed. "Handle comments on
  my PRs automatically" should stay off until you turn it on and confirm. After the confirm, a
  reply that a reviewer left on that round's comments before the first start shouldn't start a
  round by itself; the row should keep Try again. Is the reason clear enough to act on?
  ([reviews R9](ports/reviews/DELIBERATE-DIFFERENCES.md),
  [reviews R14](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] With Reviews on in Bifrost Dev, turn Reviews on in a second copy of Bifrost on the same home.
  The second copy should say "Reviews is running in another copy of Bifrost." and do nothing on
  GitHub. Quit the first copy and turn Reviews off and on again in the second: it should start.
  ([reviews R10](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Have your second account ask for your review on a test PR. At the next poll its row should
  flash in To review, the tab count should turn red, the Reviews button in the side bar should get
  its dot, and one notification should arrive if the window isn't focused; clicking it should open
  the panel. Click Pause: the flash should stop and the row should say "Paused 60m". Turn Row flash
  off in Settings and ask again on another PR: no flash this time, but the count should still turn
  red.
- [ ] Push a commit that makes CI fail to a test PR, then have your second account ask for your
  review on it, with the window not focused. At the next poll its row should show "CI failing" with
  no flash, the To review count should stay plain, the Reviews button should get no dot, and no
  notification should arrive. Push a fix for CI: at the first poll after the push the row
  should flash, the count should turn red and one notification should arrive, even while the new
  checks still run. Make CI fail and pass again:
  no second notification. Do it once more, but submit a review on GitHub while CI still fails: no
  notification when CI passes. ([reviews R32](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Let Claude review a test PR until its row shows "Approval recommended" with Approve. Push a
  new commit to the PR and wait for the next poll. The row should say "New commits" in amber, with
  the tip "Claude reviewed an older commit. Review again to check the new changes.", a Review
  button and no Approve. Click Review: Claude should review the new commit, and the row should
  show its verdict with Approve again.
- [ ] Right-click a row of the Reviews panel, then Control-click one. The Bifrost menu should open
  at the pointer with only the items that fit the row: Open on GitHub everywhere, Open session and
  Stop session while the PR has a session, Review (Try again on a failed row), Cancel review on a
  queued review, Pause on a new request, End pause now on a paused row and Remove on a row
  that others approved. On a My PRs row it should show Open on GitHub, then Answer Claude while
  Claude has questions, Handle now and Handle Copilot comments while those comments wait, Try
  again after a failed round, Cancel on a queued round and Stop session while a round runs; a PR
  from a fork should show Open on GitHub only. Does it look and behave like the other Bifrost
  menus? Cmd+click and a click on the PR number should open the PR on GitHub, and a plain click
  should do nothing unless a PR session works or needs you.
  ([reviews R13](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Add `"sandbox": {"enabled": false}` to `~/.claude/settings.json`, then choose Handle now on
  one of your PRs with older comments. No session should start, and the row should say Error with
  "Your Claude Code settings turn the sandbox off, so Bifrost can't keep Claude's session safe..."
  in its tip. Remove the setting and choose Try again: the round should start. Is the text clear
  enough to act on? ([reviews R18](ports/reviews/DELIBERATE-DIFFERENCES.md),
  [reviews R20](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Before the first review, check that your Claude Code still takes the flags of a review
  session. In a scratch folder you've trusted, start a session by hand with the flags from "PR
  sessions" in `docs/behaviour/reviews.md`, named `bifrost-test-review-flags`, and a prompt such as
  "List the files here, then run ls in a shell." It should start and show in the Overview, read the
  files, and have no shell for `ls`. Stop and delete it, then do the next line on a test PR of your
  choice.
- [ ] Click Review on a To review row of a test PR. The row should say Queued, then Reviewing, and a
  session named `<repo>-<number>-review` should show in the Overview with no yellow box. When
  Claude is done, the row should show its recommendation, one notification should arrive if the
  window isn't focused, and the pending review should be on GitHub for you alone. Make a review
  fail (stop its session with Stop session): the row should say "Review failed" with the reason in
  its tip and a Try again button, in the menu too, and no notification should arrive. Are the
  texts clear? ([reviews R17](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Once Bifrost has reviewed two PRs of one test repository, check that a session can't reach
  the other PR's folders. Open a terminal in the worktree of one of them,
  `~/.bifrost/reviews/repos/<owner>/<repo>/.bifrost-worktrees/<n>`, and start a session by hand with
  the review flags, the name `bifrost-test-review-reach` and `--add-dir
  ~/.bifrost/reviews/repos/<owner>/<repo>/.bifrost-io/<n>`. In its chat, ask Claude to read
  `~/.bifrost/reviews/repos/<owner>/<repo>/.bifrost-io/<other n>/input.json` and to write a file in
  that folder: Claude Code should refuse both. Do the same with the request flags and the request
  sandbox (`--restricted`, Bash, and the `--settings` value of a request round, from the session's
  command line in Activity Monitor), named `bifrost-test-request-reach`: the Read tool, Grep and
  Bash `cat` of the other PR's input.json and worktree should all be refused, as should Bash `cat`
  of `~/.bifrost/reviews/state.json` and `~/.ssh`, while `git status` and a read of the session's
  own input.json still work. Both reads and writes of another PR's folders are refused. Stop and
  delete the sessions afterwards. ([reviews R29](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] On a test PR of yours, have your second account leave a comment that Claude can't decide
  alone, and let a round run. Answer Claude in the Answer panel. The Overview should show one
  `<repo>-<number>-request` session for both rounds, and its chat should hold the first round,
  then your answer typed in as a second `/bifrost-resolve-comments` message. Leave the session
  idle for 10 minutes so Bifrost stops it, then have them leave another comment: the next round
  should resume the same session, with no new session in the Overview, and Claude should still
  know the earlier rounds. ([reviews R33](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Open the chat of the request session of one of your PRs and ask Claude to change a file
  for you, and to add a new one. While it works, have your second account leave another comment:
  the next round should wait until the session is idle, and both of Claude's changes should stay
  in the worktree while it waits. Keep the session busy for over two minutes instead: the row
  should say "Claude's session for this pull request was busy, so Bifrost didn't start the round.
  Choose Try again when it's finished.", and the changes should still be there. Is that clear?
  ([reviews R33](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Between rounds, open the chat of the request session of a test PR of yours and ask Claude to
  rename a function. When its turn ends, Bifrost should commit and push the change within a few
  seconds: one new commit on the PR with Claude's message and only the files it changed, signed
  when Sign commits through GitHub is on, a line in the Event log, and no reply on GitHub. Then
  push a change to the same line from another checkout and ask Claude for another edit of it: the
  row should show "Needs you" with "Someone pushed to this branch, and your change doesn't merge
  cleanly ...", and the edit should still be in the worktree. Ask Claude for an edit and to skip
  the commit request (or edit a file of the worktree yourself), then have your second account
  leave a comment: the row should show "Unpushed changes" in amber, with the buttons Open session
  and Discard changes, Claude shouldn't start, and the edit should stay. Ask
  Claude to undo it and choose Handle now: the round should start. While a round runs, type a
  request into its session: once the round ends, your change should go as its own commit (or, if
  the round pushed a fix, the row should ask you to try again), and it should never vanish. Edit
  a file of the PR's copy by hand, delete the PR's request session from the Overview, and have
  your second account leave a comment: the row should show "Needs you", and its menu should have
  "Discard these changes". It should ask first and name the file; Cancel should keep the edit, and
  Discard should remove it and clear the row, so Handle now starts the round. Are the texts clear?
  ([reviews R35](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] On a test PR of yours with conflicts, edit a file of its copy by hand and click Resolve now:
  the row should show "Unpushed changes" in amber, with a tip and the buttons Open session and
  Discard changes. Then ask Claude in the session for an edit while a conflict round runs: the row
  should show "Ask again" with the button Discard edits. Discard changes and Discard edits should
  ask first and name the files. Are the short texts and the buttons clear?
- [ ] Have a reviewer ask, on a test PR of yours, for a change to a tool configuration file (for
  example `.eslintrc.json` or the scripts of `package.json`), then choose Handle now. The request
  session should stop to ask for approval, and the row should at once show the reason "Claude
  stopped to ask for approval ..." with nothing posted. Is the text clear? ([reviews
  R29](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Leave "Handle comments on my PRs automatically" off, as it is after the first start, and have
  your second account leave a review comment on a test PR of yours. No round should start, nothing
  should reach your branch, and the row should offer Handle now. Turn the setting on and confirm,
  then have them leave a second comment: one round should start by itself, push one fix commit to
  your branch and reply, while the first comment still waits for Handle now. Do it once with "Sign
  commits through GitHub" off and once with it on: the first time the commit should be unsigned,
  with your git identity, and the second time GitHub's own Verified commit.
  ([reviews R14](ports/reviews/DELIBERATE-DIFFERENCES.md),
  [reviews R21](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] On a test PR of your own, with a review comment from a teammate, choose Handle now and let
  Claude fix it. The fix should land on the PR's branch as one commit with Claude's message and
  your git identity, unsigned, holding only the files Claude listed, and the thread should get
  "Fixed by" with that commit's short ID and be resolved. A No fix comment should get Claude's
  reply and a resolve, and a top-level comment a new PR comment that quotes it. No reply should
  notify anyone it mentions. Push to the branch yourself while Claude works on a second round: the
  fix should come as a merge, never a force push. Quit Bifrost in the middle of the replies and
  start it again: the rest should go, with no reply twice. Are the texts on the row clear when a
  push or a write stops? ([reviews R22](ports/reviews/DELIBERATE-DIFFERENCES.md),
  [reviews R23](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Turn on "Sign commits through GitHub" and let a round fix a comment on a test PR. The commit
  on the branch should be GitHub's, marked Verified, and the "Fixed by" reply should name it. Push
  to the branch yourself while Claude works on another round: Bifrost shouldn't send the signed
  commit, the other replies should still go, and the row should ask you to choose Try again. Is
  that clear? ([reviews R21](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Protect the branch of a test PR of your own on GitHub so that pushes are refused, then let a
  round fix a comment. Nothing should be posted, the row should say that GitHub didn't accept
  Claude's fix with Try again, the Event log should have GitHub's reason, and the next round
  shouldn't stop on the same push. Then make a round's replies stop on the network (turn Wi-Fi off
  while they go): the row should keep the rest for Try again, and Don't send the rest in the row
  menu should drop them without posting anything. Are both clear?
  ([reviews R28](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] After the first start of Reviews, "Handle comments on my PRs automatically" should be off,
  and the My PRs tab should show the hint with Open Settings. Turn it on: Bifrost should ask first,
  and only after you confirm should the hint go. Turn it off and on again with Watch GitHub off,
  then turn Watch GitHub on: the switch should stay on. Is it clear what turning it on will do?
  ([reviews R14](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Leave the Reviews panel open for a few minutes with a paused row. "Paused 42m" and the ages
  on line 2 should count down and up between polls, and "Last checked" should show the time of the
  last poll, with the day once it's from another day. Does the extra line in the tab bar help or
  get in the way? ([reviews R15](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] With Watch GitHub on and a repository whose clone you haven't trusted yet, the Reviews panel
  should show the Trust needed strip with the repository and the count of its pull requests.
  Click Trust: the trust panel should open with Claude Code's own trust prompt in a terminal that
  looks and types like a chat. Leave it for a minute first: the prompt should still be waiting,
  because Bifrost never answers it for you. Then answer it yourself. The panel should close by
  itself a moment later, and the strip should drop the repository. Close the panel before you
  answer: its `claude` should stop. Does the terminal feel like the chat terminal?
  ([chat C50](ports/chat/DELIBERATE-DIFFERENCES.md))
- [ ] Turn on Watch GitHub in Settings > Reviews. Bifrost's own dialog should ask "Watch GitHub?"
  with the full text, and Cancel should leave the box off. Do the same for "Handle comments on my
  PRs automatically". Turning either off should ask nothing.
  ([settings S50](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] In Settings > Reviews, "Resolve merge conflicts automatically" and "Fix failing CI
  automatically" should sit straight under "Handle comments on my PRs automatically", both off.
  Turn each one on: Bifrost's own dialog should ask first with its full text, Cancel should leave
  the box off, and Turn on should tick it. Turning either off should ask nothing. Turn one on while
  Watch GitHub is off, then turn Watch GitHub on: the box should stay on. Do the dialogs make it
  clear what Bifrost will do to your branches?
  ([reviews R36](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] On a scratch PR of yours, push a change to its base branch that conflicts with the PR. After
  the next poll that sees GitHub's conflict, the row should show "Has conflicts" in amber, with a
  tip that names Resolve now, and it should keep its place in its status group (no red box).
  Resolve the conflict yourself and push: the row should go back to Waiting. Is the tip clear?
  ([reviews R37](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Turn on "Resolve merge conflicts automatically". On a scratch PR of yours, push a change to
  its base branch that conflicts with the PR. After the next poll the row should show "Resolving
  conflicts", the PR's `<repo>-<number>-request` session should resolve the files, and GitHub should
  then show a "Merge <base> into <branch>" commit on the PR's branch, never a force push. Make a
  second conflict that Claude can't settle (two different values for one setting): the row should
  show "Has conflicts" in red with Claude's reason, and a later poll should start nothing until you
  push. Is the reason clear? ([reviews R38](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Type "not a repo" in Repositories to ignore and press Enter. The reason "Use owner/repo or
  owner/*." should show in the error line of the row, with its close button, and the field should
  keep your text. ([settings S51](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] On a test PR where Claude suggests Approve, click Approve on the row. The PR should be
  approved on GitHub on the reviewed commit (with Claude's draft as the approval when it left one),
  and the row should move to You approved after the poll. Push a commit to the PR first and click
  Approve again: Bifrost should approve nothing and say why in the error line at the bottom of the
  panel. While CI runs, the button should be greyed out with its tip. Is the line a good place for
  the reason? ([reviews R24](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Once Claude suggests Approve on a real PR that you'd approve anyway, click Approve on its row.
  GitHub should show your approval on the commit Claude reviewed, and nothing else on the PR
  should change. ([reviews R24](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Click Approve on a test PR where Claude suggests Approve. The button should turn straight
  into a spinning loader with "Approving…", and "Approval recommended" should go at the same time.
  Then a green check with "Approved" should show, and the row
  should stay for about 3 seconds before it goes (or moves to You approved). With Reduce Motion on
  in System Settings, the loader should stay still. Does it feel clear that the approval worked?
  ([reviews R30](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Send a Request changes draft from the Review panel on a test PR. Send review should turn
  straight into a spinning loader with "Requesting changes…", and the row should show the same in
  place of its text and buttons. Then the row should show a red check with "Changes requested" for
  about 3 seconds, and, while GitHub still lists the request, "You requested changes" with no
  Request changes or Review button. A Comment draft should do the same in amber ("Commenting…",
  "Commented", "You commented"). Does it feel clear that the review went?
  ([reviews R31](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] On a test PR where Claude left a Comment or Request changes draft, click that button. The
  Review panel should open with "Owner/Repo #7" after its title, Claude's suggestion, the summary
  and each comment with the end of its diff. Edit the summary, change one comment, remove another
  and Send review: GitHub should get exactly those changes and the review with the event of the
  "Send as" switch, and the panel should close. Open another draft, change its summary on GitHub,
  then Send review: Bifrost should send nothing and say the draft changed. Add a comment of your own
  on GitHub and Discard draft: the panel should ask first. Try Approve instead too. Are the texts
  clear? ([reviews R24](ports/reviews/DELIBERATE-DIFFERENCES.md),
  [reviews R25](ports/reviews/DELIBERATE-DIFFERENCES.md),
  [reviews R26](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] Type in the Review panel's summary and comments, and in an answer of the Answer panel.
  Typing, the arrows, selection, Cmd+A, copy, paste and Cmd+Z should work as in any Mac text field,
  Space should type a space rather than start dictation, and none of Bifrost's single-key shortcuts
  should fire while you type. Does it feel like a normal text field?
- [ ] Open the Review panel on a test PR and type in the summary, then click the row's button
  again: the panel should come forward with your text still there. Open the Answer panel on another
  PR too, then turn Watch GitHub off: both panels should close.
  ([reviews R27](ports/reviews/DELIBERATE-DIFFERENCES.md))
- [ ] When Claude asks a question on one of your test PRs, click the row (or choose Answer Claude):
  the Answer panel should list the question with the reviewer's comment and View on GitHub. Answer
  one question and tick "I'll handle this one myself" on another, then Send to Claude: one request
  round should start with your answer, and the other comment should count as handled with no
  round. Does the panel read clearly? ([reviews R26](ports/reviews/DELIBERATE-DIFFERENCES.md))

## Settings and files

- [ ] Make a Settings row fail to save (for example a key that clashes with another one), and
  look at its error line next to the error line of an Overview. Both close buttons should be the
  same thin x with the "Close" tooltip and the hover colour, and the error line of the Selected
  Item panel should match them too.
  ([settings S11](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] Open each tab of Settings. Each section that a later build fills (Reviews and Daily update
  before phase 5, and Modules before phase 7) should show "This section comes in a later
  build of Bifrost Dev.", and a search for its title, such as "reviews", shouldn't find it.
  ([settings S1](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] Open Settings > Live details with Live details
  on. It should say "On. <n> sessions are sending live details." with Turn off and Remove, and
  "Claude Code <version>" below, in the look of the other sections. Turn off should give "Off."
  with Turn on and Remove, and Turn on should bring back "On." with the reload note. Remove should
  first ask in Bifrost's dialog, "Remove Live details", and Cancel should change nothing. A search
  for "turn off" should find the section.
  ([settings S10](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] Open Settings > Skills. It should list the seven
  skills as `/bifrost-...`, each with "Listed" or "Called by name" and its description, under the
  dim hint about the two groups. Install should show its two steps with Install and Cancel before
  it changes anything, and while a Live details action runs the Skills buttons should be greyed
  out. A search for "hand-over" should find the section.
  ([settings S10](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] Give Live details a problem, for example by
  starting Bifrost Dev while another app listens on `~/.bifrost/live.sock` (see the N12 line
  below). The gear at the bottom of the side bar should get a small white square at its top
  right, its tooltip should say "Settings - something needs your attention", VoiceOver should
  read that text as the hint of the gear, and the Live details tab should show the same square.
  Then quit the other app and press Turn off, then Turn on, in Settings > Live details: the
  section should say "On." again, and the dot should go.
  ([live U3](ports/live/DELIBERATE-DIFFERENCES.md))
- [ ] Start Bifrost Dev from a terminal with `BIFROST_TEST_HOME=$HOME/.claude/bifrost-test-home`
  (a folder that doesn't need to exist). It shouldn't start: the alert should say "Bifrost can't
  use the test home ... Use an absolute folder that isn't /, your home folder, a parent of it, or
  a data folder of Claude Code or Bifrost.", and `~/.claude` should gain no new folder.
  ([process P10](ports/process/DELIBERATE-DIFFERENCES.md))
- [ ] Use a test home whose `claude --version` fails
  (for example a fake claude that exits 1). Settings > Live details should show "Bifrost can't
  find Claude Code. Check that the claude command works in a terminal." under the state, and the
  gear should show its dot. ([live U2](ports/live/DELIBERATE-DIFFERENCES.md))
- [ ] Use a test home where `<test home>/.bifrost`
  can't be written, and press Install in Settings > Skills. The error line should show the native
  text of the failed copy, such as `Cannot create the folder <path>: Permission denied.`, with a
  close button. ([skills K4](ports/skills/DELIBERATE-DIFFERENCES.md))
- [ ] Start Bifrost Dev with a new test home (the fake
  plugins not installed) and `BIFROST_TEST_SETUP=1`. "Set up Bifrost" should open over the
  canvas, with the side bar not dimmed, listing the two Live details changes with Skip and Turn on
  Live details. Esc, Enter and a click on the dimmed canvas should do nothing. Turn on should move
  to the skills step, Install skills should end with "Live details: On. ...", "Skills: On." and
  the reload note, and Done should close it. Start again with the same test home: no dialog. With
  another new test home, Skip and Skip should close it, and the next start shouldn't show it
  either. ([live U4](ports/live/DELIBERATE-DIFFERENCES.md))
- [ ] Scroll to the end of Settings > General and press
  "Show introduction". With Live details installed, the dialog should show its state, such as
  "Live details: Off.", with "You can change this in Settings > Live details." and Done. A search
  for "introduction" should find the row. ([live U4](ports/live/DELIBERATE-DIFFERENCES.md))
- [ ] Open Settings with the gear at the bottom of the side bar, then with Cmd+, and with Esc, and
  close it with Esc. Compare the panel with the Electron app: the search field, the tabs, the rows
  with their check boxes, menus and fields, the error line under a refused value and the Save button
  should all feel at home next to the other panels.
  ([settings S3](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] Go through the rows of Settings > General. A new scale, transparency, snap distance,
  background or terminal font should show at once, Row flash should stop and start the flashing
  boxes of the Overview, and Space labels should rename the rows of Settings > Keys, so New session
  shows as Launch. Pick Menlo from the menu beside the font family, then type 30 as the size and
  leave the field: the row should say "Enter a whole number from 9 to 24." and show the old size
  again. The terminal menu should list only your installed terminals after Automatic, and "Default
  app for "Open project"" should never offer Finder. Switch Display mode to Borderless and back,
  then use View > Fullscreen: the row should follow the window.
  ([settings S8](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] Scroll to the end of Settings > General. The last line should say "Bifrost 0.0.1", the
  version of Bifrost Dev, in the dim text colour, and it should go away while a search is on.
- [ ] In Settings > Slash commands, type a new command and press Save. Settings should close with
  the command in the list. If the write is ever slow enough to see, the Save button, the tabs, the
  search field and the text fields should stay greyed out until Settings closes.
  ([settings S7](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] In Settings > Slash commands, add a command with Enter and another with Add, then move them
  with the arrows and remove one. The list should follow each change, and the Slash commands menu
  of a session should show the new order. Type /compact again and press Enter: its reason should
  show under the field with a close button, and stay there after you move another command. Press
  Enter with the field empty: nothing should happen. Type /review in the field, then search for
  "row flash" and clear the search: the field should come back empty.
  ([settings S9](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] In Settings > Keys, look down the list: each row should show its modifier symbols in the
  order the macOS menus use, with a space between the parts, such as ⇧ ⌘ T, and a small mark on
  the keys you've changed. Clear a key, then Reset it, and check that only that row changes. Start
  a recording on one row and click Change on another: the prompt should move to the second row.
  Click the prompt itself while it records: the recording should carry on, and the next key you
  press should still be recorded. After a recorded key or Esc, the focus should stay in Settings,
  so Enter and the arrow keys don't act on the Overview. Search for "close panel", record a key
  for it, and the focus should go back to the search field.
  ([settings S9](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] In Settings > Keys, Reset all keys should be on and ask with Bifrost's confirm dialog over
  the canvas. While the dialog is open, Save at the bottom of Settings should be greyed out. Cancel
  the dialog once and nothing should change, then confirm it, and every key should be back to its
  default.
  ([settings S9](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] Switch to a Russian or Greek keyboard layout, open Settings and press Cmd+F. The search field
  should take the focus, as it does on a Latin layout.
  ([settings S4](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] In Settings > Keys, start recording a new key for Event log and press Cmd+W, then Ctrl+Cmd+F
  and Cmd+Q. Each should show its reason on the row, such as "Close the focused panel already uses
  this key.", while no panel closes, the window keeps its mode and Bifrost doesn't quit. Then press
  Option+E, Space and, on a keyboard with a keypad, a keypad digit: they should show "That key types
  a character. Try another one.", "The space bar can't be a shortcut. Try another one." and "Bifrost
  can't use this key. Try another one." Cmd+Option+E should save as a normal shortcut, and its row
  should show it. Esc should stop the next recording, and Cmd+W should close a panel again.
  ([settings S5](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] In Settings > Keys, switch to a German (QWERTZ) keyboard layout and record a new key for
  Select row 1 by pressing Cmd, Shift and the key labelled Y. The row should show ⇧ ⌘ Y, and that
  key should then select row 1. Then switch to a French (AZERTY) layout and press Cmd and the key
  labelled A for the same row: it should be refused because a Bifrost menu already uses that
  shortcut. ([settings S6](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] Turn on Start at login in Bifrost Dev, then open System Settings > General > Login Items &
  Extensions. Bifrost Dev shouldn't be in the list, and it shouldn't open when you next log in, even
  though the switch stays on. ([settings S2](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] At the first real update, with the signed release app, turn Start at login on and then off.
  Bifrost should join and then leave Login Items & Extensions, and open at login while the switch
  is on. Then, with Bifrost closed, change its login item in System Settings and start Bifrost:
  the switch should match what you set there.
  ([settings S2](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] At the first real update, if macOS asks you to approve the login item, the Start at login row
  should say "To open Bifrost at login, allow it in System Settings > General > Login Items &
  Extensions." with an "Open System Settings" button, and the button should open Login Items &
  Extensions. Allow Bifrost there and switch back to it: the note should go without another click.
  ([settings S8](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] Start the first phase 4 build of Bifrost Dev on your real home. It should show the session
  names, priorities, watchlist, layouts and settings from the Electron app, and
  `~/Library/Application Support/Bifrost Native Dev` should have `import.json` plus a
  `.before-import` copy of each file it replaced, including the earlier Bifrost Dev layouts in
  `ui-state.json.before-import`. The Electron folder should be unchanged. Quit and start again:
  Bifrost Dev shouldn't import anything a second time.
  ([import I1](ports/import/DELIBERATE-DIFFERENCES.md))
- [ ] In Settings, add a slash command with 199 emoji after its slash, and set a terminal font
  family of 64 emoji. Both should be accepted, where the Electron app stopped at 99 and 32.
  ([stores S15](ports/stores/DELIBERATE-DIFFERENCES.md))
- [ ] Before the first start of this build of Bifrost Dev on your real home, list `~/.bifrost`
  (`ls -la ~/.bifrost`), because the start removes the old hook data there, as the Electron app
  did. After the start, only `active`, `events` and `sessions` should be gone, and `bin` too, but
  only when `~/.claude/settings.json` can be read and has no Bifrost hook or wrapper left. `mod`,
  `backups`, `statusline-original.json` and `live.lock` should still be there, and your status
  line should still work. If `~/.bifrost` is a link, nothing should go.
  ([live C4](ports/live/DELIBERATE-DIFFERENCES.md))
- [ ] Run Bifrost Dev on your real home with Live details on, and use a session for a while. The
  rows should show its live lines, which also shows that the start rule listens on
  `~/.bifrost/live.sock` and that the server accepts the requests of the Claude Code mod.
  ([live N10](ports/live/DELIBERATE-DIFFERENCES.md),
  [live H3](ports/live/DELIBERATE-DIFFERENCES.md))
- [ ] Start Bifrost Dev on your real home with Live details on (the usable result of phase 4d).
  Settings > Live details should say "On." with the number of live sessions, and the rows of a
  session you use should show its model, its context and its cost. Settings > Skills should list
  the skills. Turn off should end the live lines and Turn on should bring them back, in both
  sections. ([settings S10](ports/settings/DELIBERATE-DIFFERENCES.md))
- [ ] With a test home and Live details on, send a forged `session.end` line for a session that
  runs: a POST of `{"v":1,"sid":"<session id>","at":<now in ms>,"seq":99,"kind":"session.end"}`
  to `http://bifrost/v1/event` with `curl --unix-socket <test home>/.bifrost/live.sock`. The row
  should park, but until the next poll Resume should answer "This session isn't parked,
  so there's nothing to resume." and Delete should stop the session first.
  ([actions X31](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] With a test home and Live details on, check that a forged line in the first seconds of a
  session can't start a second copy of it. Claude Code gives a new session no pid for about
  2.5 s, so have the line ready first: in Terminal, run this. It defines `forge`, which sends a
  `session.end` line for the session ID on the clipboard, with the JSON on one line.

  ```sh
  forge() {
    line=$(printf '{"v":1,"sid":"%s","at":%s000,"seq":99,"kind":"session.end","reason":"other"}' \
      "$(pbpaste)" "$(date +%s)")
    curl --unix-socket <test home>/.bifrost/live.sock -X POST http://bifrost/v1/event -d "$line"
  }
  ```

  Start a new session called `bifrost-test-resume`. As soon as its row shows, use Copy session ID
  on the row, run `forge`, and press Resume, all within about 2 seconds. The row should park,
  and Resume should answer "This session isn't parked, so there's nothing to resume." No second
  copy of the session should start. (The smoke test checks the same case every time with an
  entry that keeps no pid.) Afterwards, delete `bifrost-test-resume`, and any copy of it that
  did start. ([actions X31](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] With a test home, quit Bifrost Dev while one session, `bifrost-test-all`, runs, then stop
  it in Terminal with `claude stop` and start Bifrost Dev again, so Resume all has one session to
  resume. Press Resume on its row and, while that runs, press Resume all. The error line should
  say "bifrost-test-all: Another action is still running on this session. Try again in a
  moment.", and the notice line should stay empty, with no "Resumed 0 sessions.". Afterwards,
  delete `bifrost-test-all`. ([actions X31](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] With a test home, set Settings > General > Poll interval to 10 seconds, and have a parked
  session, `bifrost-test-check` (start it, then stop it). Quit Bifrost Dev and start it again.
  As soon as the row of `bifrost-test-check` shows, select it and press Resume. The notice line
  should say "Checking sessions..." for a moment, and then the session should resume as usual,
  with one copy only. Afterwards, delete `bifrost-test-check` and set the Poll interval back.
  ([actions X31](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] With a test home, quit Bifrost Dev, replace `<test home>/.bifrost/live.lock` with a hard
  link to another file, and start it with Live details on. Settings > Live details should say
  "<test home>/.bifrost/live.lock is not a regular file of this user with one link. Bifrost did
  not change it.", and the other file should be unchanged.
  ([live N12](ports/live/DELIBERATE-DIFFERENCES.md))
- [ ] Make `~/.bifrost` a link to another folder, then start Bifrost Dev with Live details on.
  Settings > Live details should say that Bifrost doesn't listen in the folder because it's a
  link, and the log says so too. With a normal folder, the server should listen as before.
  ([live N11](ports/live/DELIBERATE-DIFFERENCES.md))
- [ ] Start Bifrost Dev and the Release app at the same time, both with Live details on. Only the
  first should listen on `~/.bifrost/live.sock`; the other should report
  `Another program listens on ~/.bifrost/live.sock.` in Settings > Live details and in the log.
  Quit the first, then the second listens after its next start.
  ([live N12](ports/live/DELIBERATE-DIFFERENCES.md))
- [ ] With Live details listening, log in as a second local user on the same Mac and try to send
  a line, for example
  `curl --unix-socket /Users/<you>/.bifrost/live.sock -X POST http://bifrost/v1/event -d '{}'`.
  The connect should fail with "Permission denied", because `~/.bifrost` has mode 0700 and the
  socket has mode 0600. ([live N11](ports/live/DELIBERATE-DIFFERENCES.md))
- [ ] Run Bifrost Dev with a test home, and put a copy of
  your `~/.claude/settings.json` with an old Bifrost hook entry added (a hook with the command
  `~/.bifrost/bin/bifrost-hook`) in `<test home>/.claude/settings.json`. Turn Live details on.
  Only the Bifrost entry should go: every other key should stay where it was, every number and
  string should keep its text, and `<test home>/.bifrost/backups` should hold a copy of the old
  file. ([live E1](ports/live/DELIBERATE-DIFFERENCES.md))

## Phase 4 daily use

This is the hands-on test at the end of phase 4: run Bifrost Dev (the Debug build, with no test
home) on your real home for a working day, as your main Bifrost. Run it only once every part of
phase 4 is on main, because the session actions of 4b give the row menus and Show Info their way in.
Start with `bifrost-test-` sessions on haiku before you act on a real session. The checks below are
the usable result of each part of phase 4. Most of them point back to the detailed lines above,
which hold the exact texts and steps.

- [ ] The first start imports the Electron data: the local names, the watchlist and its colours,
  the layouts and the settings. Every visible row of the `import` and `overview` differences
  tables should hold up (see Overview and Settings and files above).
- [ ] The Overview: the tabs, the filters, the columns, the sort, a header drag, a resize, the row
  flash, a second Overview from New Overview, the Overview Settings panel, the tab menu and the
  tab set name field.
- [ ] The session actions, first on `bifrost-test-` sessions: New session (in a folder and in a
  worktree), Send message, Run slash command (a favourite and Other...), Compact, Interrupt (the
  key and the button), Rename (local and in Claude Code), Set priority, the watchlist items, Show
  Info, Copy session ID, Open project, Open in terminal (owned and external), Stop, Resume, Resume
  all, Take control of an external session, and Delete (clean, with unmerged work, and in a shared
  folder). Then the row menu, the Panel menu (its look, its keys and VoiceOver), the dialogs, and
  every visible row of the `actions` differences table (see Sessions above).
- [ ] Settings: the search (a label, "cmd shift t" and "⌘⇧T"), each General row (the scale, the
  transparency, the font, the terminal app, the project app, the poll and the row flash), the
  slash list, the key recorder (record Cmd+W for a slot, a conflict, Reset all keys), Cmd+F and
  Esc, Save with a draft, and every visible row of the `settings` differences table.
- [ ] Live details and the skills: Settings > Live details shows On and the number of live
  sessions, the rows show the model, the context and the cost, Settings > Skills lists the skills,
  Turn off and Turn on work, and every visible row of the `live` and `skills` differences tables
  holds up.
- [ ] A red box gives a notification and the Ping sound while the Bifrost window isn't focused,
  and clicking the notification opens the session, also after a close of the window (see Alerts
  above).
- [ ] The usage notification at 90 % of a limit shows once, also while the window is focused, and
  its click opens the Usage HUD.
- [ ] The Usage HUD shows the values of your sessions, and the values of your Anthropic account
  while Account usage from Anthropic is on in Settings (see Usage above).
- [ ] The Event log fills with the events of your sessions once Live details reaches Bifrost Dev,
  and shows the line about refused notifications (see Event log above).
- [ ] The Watchlist shows the watched sessions in their colours, and a drag puts a row in a new
  place (see Watchlist above).
- [ ] Show Info shows the seven sections of a session and the PR of its branch, and a click on the
  PR opens it in your browser (see Show Info above).

## Hand over

Use a `bifrost-test-` session on haiku that has done a few turns of work, so the note has
something to say. Give it a priority and put it on the watchlist first.

- [ ] Open the session's chat window and click Hand over. The notice line should say "Writing the
  hand-over note..." and the request should show up in the chat. When Claude has written the note,
  a new session called `<old name> (2)` should start in the same folder, the chat window should now
  show the new session, the new row should be selected, the old row should park, and the notice
  line should say "Handed over to <old name> (2)." The new session should have the old one's
  priority and its place and colour in the watchlist.
  ([actions X2](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Open `~/.bifrost/handovers`. The note should be there as `<name>-<date>-<time>.md`, with the
  local time, and `ls -l` should show `-rw-------` for the file and `drwx------` for the folder. The
  new session's first prompt should name that file and then give the note.
- [ ] Compare the new session's model and permission mode with the old one's. The model should be
  of the same family (Opus, Sonnet or Haiku), and a 1M-context Opus session comes back as plain
  Opus. ([actions X71](ports/actions/DELIBERATE-DIFFERENCES.md))
- [ ] Start another hand-over and, before Claude finishes the note, type a message in the old
  session's chat. The hand-over should stop with "Bifrost couldn't read the hand-over note, so it
  didn't start a new session. (a new message came in during the hand-over)", and no new session
  should start.
- [ ] Start another hand-over and, while Claude writes the note, stop that `bifrost-test-` session
  with `claude stop <short id>` in a terminal (Stop is off in Bifrost while a hand-over runs). The
  hand-over should stop with "The session stopped before it finished the hand-over note.", and no
  new session should start.
- [ ] Start another hand-over, and as soon as Claude has written the note, before the new session
  shows, type a message in the old session's chat. The new session should still start, but the
  old one should keep running, and the error line should say "The new session started, but the
  old one has a new message, so Bifrost left it running." (or that it's busy again).
  ([actions X74](ports/actions/DELIBERATE-DIFFERENCES.md))

## Service status

Open the Service status panel from the side bar (the button right after the Usage HUD). You need a
network connection for the first part.

- [ ] The panel should list Claude, GitHub and Sentry, each with a coloured square, the level in
  words, its name and an "Open status page" button. At the bottom it should say "Checked at" and
  the clock time. Before the first check ends, it says "Not checked yet." and each row says "No
  data".
- [ ] Click "Open status page" on each row. The page of that service should open in your browser.
- [ ] Make the panel narrower, little by little. First the button should lose its text and keep its
  icon (hover it: the tooltip says "Open status page of ..."). Then the level text should go, and
  the square should stay (hover it: the tooltip gives the level). Make the panel wider again: the
  text should come back in the same order. Check that no colour in the panel is yellow, red or
  grey.
  ([health SV1](ports/health/DELIBERATE-DIFFERENCES.md))
- [ ] Turn off your network connection and wait up to a minute and a half. Each row should say "No
  data" with the line "The status page didn't answer." under it, and the check time should move on.
  Turn the network back on: within a minute the rows should show their levels again.

## Release notes and updates

Open Settings and choose the Updates tab. You need a network connection for the first part.

- [ ] The tab should list "Check for updates automatically", "Version", "Last checked", "Check for
  updates" and "Release notes". Search Settings for "release" and then "updates": the search
  should find the rows by their labels, and the title "Updates" should show all five.
- [ ] In Bifrost Dev, "Check now" should be off, with the line "This build doesn't update itself."
  under its label. "Version" should show the version of the app.
- [ ] Click "Open" in the "Release notes" row. The dialog "Release notes" should show "Loading the
  release notes…" and then the last releases, newest first, each with its version, its date and a
  "View on GitHub" button. Check that only New, Fixed, Changed, Faster and Reverted sections show,
  and that bold and code in an item look like bold and code.
- [ ] Click "View on GitHub" on one release. The page of that release should open in your browser.
  Close the dialog with Esc, then open it again and close it with a click outside the box and with
  "Close".
- [ ] Turn off your network connection, quit and start Bifrost Dev again (the notes stay in memory
  only), and open the dialog. It should say "Couldn't load the release notes." with a button "Open
  the Releases page on GitHub", and the button should open the Releases page.
- [ ] In the release app, with a newer release available, "Check now" should be on. Click it:
  Sparkle's own window should show the result and the download progress. Check that the side bar
  has no Update button and that Settings has no line about the state of the update.
  ([updates RN1](ports/updates/DELIBERATE-DIFFERENCES.md))
- [ ] After an update of the release app, the "What's new" dialog should open by itself once, with
  the releases since the version you had before. Quit and start the app again: it should not open a
  second time. Bifrost Dev should never open it by itself.
- [ ] When Sparkle's window shows an update, it should show that release's notes too: the summary,
  then the sections with their headings, with bold and code shown as bold and code.
  ([updates RN3](ports/updates/DELIBERATE-DIFFERENCES.md))
- [ ] At the first native release, update your own Mac before any other (step 3 of the bridge check
  in [`docs/release.md`](release.md#the-bridge-check)). In Electron Bifrost, check for updates: it
  should download the new version and, after the restart, open the native app in its place, with
  your sessions, layout and settings imported. If it fails, Electron Bifrost keeps running, and that
  page says how to stop the other Macs.

## Daily update

These checks need a real Claude Code setup with MCP servers, so do them in Bifrost Dev on your real
home, not a test home.

- [ ] Set the draft time and the deadline 20 minutes apart, a few minutes from now, with an area on
  and a source chosen. The first reminder should write a draft and notify you with a sound. Ten
  minutes before the deadline the second reminder should notify you, and the Dock icon should
  bounce one time. A click on a notification should open the Daily update panel at the first tab
  that isn't sent. Mark each area as sent, and no more reminders should come.
  ([daily-update DU7](ports/daily-update/DELIBERATE-DIFFERENCES.md))
- [ ] Put the Mac to sleep over the draft time, then wake it before the deadline. One draft should
  run at once and one reminder should show. Start Bifrost after the deadline on a due day with work
  left: one reminder should show, with no sound.
- [ ] One real morning on your board: before the draft time, open Settings > Daily update, click
  Find servers, choose your board as the ticket source and check the ticked read tools before you
  click Use these tools. Every server should be in the list, a Slack server too, and a server that
  isn't connected should show its status and stay off. Turn on your work areas. At the draft time
  the first reminder should come with the drafts, and ten minutes before the deadline the second
  one. In the panel each tab should list what moved, with links that open in the browser, and the
  draft should show bold in bold. Copy a draft, paste it into Slack, post it yourself, and click
  Mark as sent: the tab should say "Sent at" with the time, its marker should go, and the side bar
  dot should go once every area is sent.
  ([daily-update DU10](ports/daily-update/DELIBERATE-DIFFERENCES.md))
- [ ] Change a draft in the panel, then Copy it and paste it into Slack: bold should come out bold
  and nothing else should change. Click Refresh: your draft should stay, with "There's a new
  draft." and Use new draft and Keep mine. Click Redo draft: the confirm dialog should ask first,
  and Cancel should keep your draft. "Send to" with the channel should stay off, and its tooltip
  should say that sending comes with the Slack app. Right-click in the editor: if the menu offers
  Font items, text styled with them shows styled but saves as plain text, so only bold should
  survive a Copy.
  ([daily-update DU8](ports/daily-update/DELIBERATE-DIFFERENCES.md),
  [DU9](ports/daily-update/DELIBERATE-DIFFERENCES.md))
- [ ] In Settings > Daily update, add two work areas: they should be called "Work area 1" and
  "Work area 2" (or the next free numbers), ready to rename. Tick "Takes all other work" on both:
  the second should be refused with "Only one work area can take all other work." Remove one: the
  confirm dialog should ask first. Type `9.30` as the draft time: the row should say "Enter each
  time as HH:MM, for example 09:30." Click Open in the Daily update panel row: the panel should
  open. ([daily-update DU11](ports/daily-update/DELIBERATE-DIFFERENCES.md),
  [DU12](ports/daily-update/DELIBERATE-DIFFERENCES.md))
- [ ] Watch the status line of the panel during a Refresh: it should say "Bifrost is writing your
  drafts.", then "Your drafts are ready." with "Refreshed" and the time. Skip today should turn
  into Undo, and the tab markers should go until you click Undo.
  ([daily-update DU12](ports/daily-update/DELIBERATE-DIFFERENCES.md))
- [ ] After a Refresh, look in `~/.claude/projects`: no new project folder should name a Daily
  update run folder (`...-daily-update-runs-<time>`), and Find servers in Settings should add none
  for the Daily update folder either.
  ([daily-update DU13](ports/daily-update/DELIBERATE-DIFFERENCES.md))
- [ ] With Bifrost Dev running, start a second copy of the same app (`open -n` on it). Its Daily
  update panel and Settings > Daily update should both say "Daily update is running in another
  copy of Bifrost.", and it should send no reminder. Quit the second copy as soon as you've
  checked, because both copies share the other stores.
  ([daily-update DU2](ports/daily-update/DELIBERATE-DIFFERENCES.md))

## Performance

Open the Performance panel from the last of the panel buttons on the side bar, the heart with a
pulse line. Use Bifrost Dev on your real home, with a few sessions running.

- [ ] Within a few seconds the headline should turn from "Checking Bifrost…" to a green "OK" and
  "Bifrost is using … RAM and …% CPU." Open Activity Monitor and compare: the CPU is a percentage
  of one core, like the % CPU column there, and it includes the chat terminals (the `claude`
  processes that Bifrost Dev started for its chat windows), so it can be above 100% on a busy Mac.
  ([health PF5](ports/health/DELIBERATE-DIFFERENCES.md))
- [ ] Click Details. Five sections should show, in this order: Bifrost, Claude sessions, Your Mac,
  Network, Limits and disk. The Bifrost section should have two rows, App and "Chat terminals
  (N)", then Frame rate and Main process delay, and every size from 1 GB should have one decimal.
  Quit and start Bifrost Dev again: Details should still be open. Close it and restart: it should
  stay closed. ([health PF6](ports/health/DELIBERATE-DIFFERENCES.md),
  [PF8](ports/health/DELIBERATE-DIFFERENCES.md))
- [ ] Watch the trend line for a few minutes: its key should read "Last 1 min", "Last 2 min" and so
  on, the memory line amber and the CPU line blue, and after ten minutes "Last 10 minutes". With
  the window focused, Frame rate should show a value within about 10 seconds; click another app
  and it should go back to "-".
- [ ] In Claude sessions, a session that Bifrost Dev started should have a Stop button, and a
  session running in another terminal app should not. Click Stop on an idle throwaway session: it
  should stop at once, with no question. Click Stop on a throwaway session while Claude is working
  in it: the usual confirmation should ask first, and the session should stop after you confirm.
  Start a Hand over on another throwaway session and click its Stop while the hand-over runs:
  nothing should happen.
  ([health PF7](ports/health/DELIBERATE-DIFFERENCES.md))
- [ ] Your Mac, Network and Limits and disk should fill in within a minute: memory pressure with
  its bar, swap, CPU load, thermal state and battery; Online with the kind of link, the rates and
  two response times; the GitHub points with a reset time (or "Not available" with the reason when
  `gh` isn't signed in) and the free disk, which should match Finder's figure. Turn Wi-Fi off: the
  title should say "Offline" in red, and the response times "Can't reach" or "No answer".
- [ ] Make a save fail: quit Bifrost Dev, run
  `chmod u-w ~/"Library/Application Support/Bifrost Native Dev"`, start it, and change any setting.
  The headline should turn amber, one of its reasons should be "Bifrost couldn't save your settings
  at" and the time, a Clear button should show, and the side bar button should get an amber dot
  with the tooltip "Performance - Warning". Click Clear: the reasons and the dot should go. Quit,
  run
  `chmod u+w ~/"Library/Application Support/Bifrost Native Dev"`, and start it again.
- [ ] Open a chat in a frame, then right-click a `bifrost-test-` session and choose Delete session.
  Move the pointer over the dialog, its Cancel and Delete buttons and the backdrop: the arrow
  cursor should show, never the I-beam. In the New session dialog, the name field should still
  show the I-beam. Do the same with a chat under the dialog.
