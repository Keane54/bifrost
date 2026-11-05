# M2 findings: the window manager in the running app

Date: 2026-11-05, 08:14 to 08:30 (GMT). Branch `m2` at `047531d`. Electron 44.7.2.

The controller ran this task while the user was asleep. The run did not change code and did not run `claude`.

## Test setup

- Start: `pnpm exec electron-vite dev --remoteDebuggingPort 9333`. The run started Bifrost 4 times. Each quit used `osascript -e 'tell application id "com.github.Electron" to quit'`. After each quit, `~/.bifrost/active` was not there.
- Pointer: `agent-browser mouse move`, `mouse down left` and `mouse up left`. These CDP events gave real pointer events with a button down, so all drags worked.
- Rects: `getBoundingClientRect()` on `[data-frame-id]`, minus the origin of `[data-panel-area]`. All coordinates in this file are panel area coordinates, unless the text says "client".
- Menu items: `osascript` with System Events, `click menu item ... of process "Electron"`.
- Keys for the native menu: a Swift script that sends a `CGEvent` to the process ID of Bifrost only (`CGEvent.postToPid`). The run did not use the System Events `keystroke` command. That command sends the key to the front app, and Bifrost could not come to the front (see below).
- Window size: `window.resizeTo()` in the page. Electron moves the real window for this call. `window-state.json` recorded each new size, so the main process got the real resize events.
- Window size at the start: 1440 x 889 (page 1440 x 857). Panel area: 1400 x 857. Screen: 1512 x 982. Screenshot: `m2-findings/00-start.png`.

The Mac screen was locked during the full run (`CGSSessionScreenIsLocked` = 1). This had 3 effects:

1. macOS did not start native full screen. So the Fullscreen checks need the user (check 6).
2. System Events did not show the Bifrost window (0 windows). The menu bar was available.
3. `activate` did not bring Bifrost to the front. Warp stayed in front.

## Summary

| Check | Result | Impact |
|---|---|---|
| 1. Move, resize, snap, guide line | Pass. 8 resize handles, 4 window edges, a panel edge at 8 px, no snap at 9 px, guide lines. | None. |
| 2. Stack, tabs, tear-out, close a tab | Pass. Drop target outline, tabs, tab click, tear-out follows the pointer, a closed tab opens again at the stack position. | The torn-out panel gets the size of the stack (O2). |
| 3. Minimise, lock, opacity | Pass. Lock stops move, resize and tear-out. Opacity goes from 30% to 100%. | None. |
| 4. Position memory | Pass. Same position after a close, centre for a new panel, same layout after a restart. A saved position outside a smaller window moves inside. | Panels do not go back when the window becomes large again (O3). |
| 5. Named layouts | Pass. Save two, load each, delete one. Both limit messages show. | None. |
| 6. Display modes | Part pass. Borderless and Window pass from the View menu. Borderless stays after a restart. `window-state.json` keeps the normal bounds. Fullscreen did not start, because the screen was locked. | The user must check Fullscreen. The View menu can show the wrong mode (D1). |
| 7. Cmd+W | Pass. Cmd+W closes the active panel. The window stays open. `agent-browser press Meta+w` has no effect. | None. |
| 8. Content scroll | Pass. A wheel event scrolls the Overview table to the right. | None. |

## Defects

- **D1 (minor). The View menu shows the wrong mode after a click that changes nothing.** The View > Fullscreen click did not start full screen (locked screen). After this, the check mark was on Fullscreen, but the mode was Window. macOS moves the radio check mark at each click. Bifrost builds the menu again only when the mode changes. The Task 7 review has the same item. Possible fix: build the menu again after each click.

## Other findings

- **O1 (low). A drag on the empty panel area selects text in the panels.** A drag from an empty point (client 1200, 100) to a point on a panel (client 600, 500) selected 291 characters of the Overview table. A drag on a title bar does not select text. Screenshot: `m2-findings/09-drag-on-empty-area-selects-text.png`.
- **O2. A torn-out panel gets the size of the stack.** The stack was 800 x 420. The Selected Item panel came out at 800 x 420, not at its last size of 420 x 356. The Task 6 design gives this result. Spec 8.1 does not give a rule.
- **O3. A smaller area moves the panels, and the save keeps the new positions.** After a change from 1440 x 889 to 1000 x 700, the locked stack went from y 450 to y 348. After the change back, it stayed at y 348. Borderless to Window gives the same result: a panel at (1052, 626) went to (980, 501). Spec 8.1 says only "Bifrost moves the panel into the window".
- **O4. Cmd+Ctrl+F in Borderless gave Window when native full screen did not start.** The controller leaves Borderless first. Then the full screen wait ended after 3 s, and the mode stayed Window. This occurs only when macOS refuses full screen.
- **O5. The View menu has two full screen items.** macOS adds "Enter Full Screen" (key Fn+F) to a menu with the name View. It is below the Bifrost items Window, Borderless and Fullscreen.
- **O6. `agent-browser mouse wheel` does not scroll.** This is a limit of the tool. A CDP `Input.dispatchMouseEvent` wheel event and `agent-browser scroll -s` both scrolled.

## Items for the user

1. Check Fullscreen with the screen unlocked:
   1. Select View > Fullscreen. Make sure that Bifrost goes to a separate desktop.
   2. Push Cmd+Ctrl+F. Make sure that Bifrost goes back to the mode from before.
   3. Select View > Borderless. Push Cmd+Ctrl+F. Make sure that Bifrost goes to Fullscreen.
   4. Push Cmd+Ctrl+F again. Make sure that Bifrost goes back to Borderless.
   5. Enter Fullscreen with the green button. Leave it with Esc. Make sure that the View menu shows the correct mode.
   6. Quit Bifrost in Fullscreen. Read the `mode` in `~/Library/Application Support/Bifrost/window-state.json`. The Task 7 review asks if this value is `fullscreen` or `window`.
   7. Put a panel near the right edge in Window mode. Quit. Start in Fullscreen, then go back to Window. Make sure that the panel is at its old position (final review Important 1, fixed in 7116bbc).
2. The M2 fix wave fixed D1, O1, O2 and O5 (commits 109b8a8 to 222b9f0). O3 changed: a panel that moves into a smaller window goes back to its saved position when the window gets larger. O4 stays: Cmd+Ctrl+F in Borderless gives Window when native full screen fails.
3. The run made `window-state.json` (it did not exist before). It now has the bounds 36, 33, 1440, 889 and the mode `window`.
4. The run wrote 20 test layouts to `ui-state.json`. After the last quit, the run put back the copy of `ui-state.json` from before the run. So your layout is the same as before.
5. The permission system refused nothing. The locked screen stopped 3 actions: native full screen, the window list of System Events and `activate`.

## 1. Move, resize, snap and guide line

Method: drag the title bar or a `[data-edge]` handle with real pointer events. Read the rects and `[data-guide]` before the pointer up and after it.

Result: pass.

- Move: a drag of +100, +50 moved the Overview from (32, 241) to (132, 291). The dragged panel came to the top.
- Snap to the left window edge: x 8 snapped to x 0, with a vertical guide at 0. Screenshot: `m2-findings/01a-snap-left-edge-8px-guide.png`.
- No snap at 9 px: x 9 stayed at 9, with no guide. Screenshot: `m2-findings/01b-no-snap-left-edge-9px.png`.
- Snap to the bottom edge: the bottom edge snapped to 857, with a horizontal guide. Screenshot: `m2-findings/01c-snap-bottom-edge-8px-guide.png`.
- Snap to the right edge: the right edge snapped to 1400. Two guides showed (right and bottom). Screenshot: `m2-findings/01d-snap-right-edge-8px-guide.png`.
- Snap to the top edge: y 8 snapped to y 0, with a guide. Screenshot: `m2-findings/01e-snap-top-edge-8px-guide.png`.
- Snap to a panel: the right edge of the Overview at 784 snapped to the left edge of the Selected Item at 792. A guide showed at x 792. Screenshot: `m2-findings/01f-snap-to-panel-8px-guide.png`.
- No snap to a panel at 9 px: the right edge stayed at 783, with no x guide. Screenshot: `m2-findings/01g-no-snap-to-panel-9px.png`.
- The guides went away at each pointer up.
- Resize, each edge type:

| Handle | Drag | Result |
|---|---|---|
| e | +50 | w 760 to 810 |
| w | -40 | x 200 to 160, w 810 to 850 |
| n | -30 | y 420 to 390, h 360 to 390 |
| s | +30 | h 390 to 420 |
| nw | -20, -20 | x 140, w 870. y snapped to 372 (the bottom edge of the Selected Item), h 438. |
| ne | +20, -20 | w 860, y 352, h 458 |
| se | -30, -30 | w 830, h 428 |
| sw | +30, +30 | x 200, w 800, h 458 |

- Resize snap: a bottom edge 8 px from the area edge snapped to 857, with a guide.
- Minimum size: a large drag of the se handle stopped at 200 x 120.
- Screenshot: `m2-findings/01h-resize-sw-corner.png`.

## 2. Stack, tabs and tear-out

Method: drag the title bar of the Selected Item to the title bar of the Overview. Click a tab with a pointer down and up. Push a tab and move the pointer away from the title bar.

Result: pass.

- During the drag, an accent outline showed on the Overview title bar (`[data-drop-target="f1"]`). Screenshot: `m2-findings/02a-stack-drop-target.png`.
- After the drop, one frame had 2 tabs: Overview and Selected Item. The dropped panel was the active tab. Screenshot: `m2-findings/02b-stack-tabs.png`.
- A click on the Overview tab made it active. Screenshot: `m2-findings/02c-stack-tab-click.png`.
- Tear-out: the title bar was at client y 352 to 380. At pointer y 375, nothing changed. At pointer y 400, a new frame showed at (261, 386). This is the pointer minus 60 and 14. At client (700, 150), the frame was at (600, 136). At client (900, 120), x stayed at 600, because the frame is 800 wide. Screenshot: `m2-findings/02d-tear-out-follows-pointer.png`.
- Close one tab: the Close button closed the active tab (Selected Item). The frame kept the Overview. Screenshot: `m2-findings/02e-stack-close-one-tab.png`.
- Open again: the side bar button S opened the Selected Item at (200, 352, 800, 420). This is the position and size of the stack. Screenshot: `m2-findings/02f-reopen-at-stack-position.png`.

## 3. Minimise, lock and opacity

Method: the Minimise button, the side bar Restore button, and the Panel menu (keys on the slider, a click on the Lock box).

Result: pass.

- Minimise: the frame went away. The side bar showed a vertical "Selected Item" button (`Restore Selected Item`). Screenshot: `m2-findings/03a-minimised-in-side-bar.png`.
- Restore: the frame came back at the same rect, on top. Screenshot: `m2-findings/03b-restored.png`.
- Opacity: the slider had the focus when the menu opened. Home gave 0.3. ArrowLeft at 0.3 stayed 0.3. ArrowRight two times gave 0.4. End gave 1.0, and the label showed 100%. Screenshot at 30%: `m2-findings/03c-opacity-30.png`.
- Lock: the lock glyph showed and the frame had 0 resize handles. Screenshot: `m2-findings/03d-locked-menu.png`.
  - A title bar drag of +100, +84 did not move the frame.
  - A drag at the se corner went to the content. The size did not change.
  - A tab drag of 133 px down did not tear the tab out.
  - A click on a tab still made it active. Screenshot: `m2-findings/03e-locked-no-move.png`.
- Esc closed the Panel menu.

## 4. Position memory

Method: close a panel and open it again. Quit and start Bifrost. Make the window smaller with `window.resizeTo(1000, 700)`.

Result: pass.

- Close and open: the Selected Item at (900, 40, 420, 356) opened again at the same rect. Screenshot: `m2-findings/04a-reopen-same-position.png`.
- No saved position: the Integration panel opened at (440, 269, 520, 320). This is the centre of the area.
- Restart: before the quit, the layout had these frames:
  - Overview at (16, 16, 760, 360).
  - A stack of Integration and Overview 2 at (200, 450, 520, 320). Overview 2 was active. Opacity 0.6. Locked.
  - The Selected Item, minimised.
- After the start, all values were the same. Screenshots: `m2-findings/04b-layout-before-restart.png` and `m2-findings/04c-layout-after-restart.png`.
- Smaller window: the area became 960 x 668.
  - The locked stack moved from y 450 to y 348, inside the area.
  - The saved position of the Selected Item was (900, 40, 420, 356). Its right edge (1320) was outside the area. It opened at (540, 40), inside the area. Screenshot: `m2-findings/04d-small-window-saved-position-moved-inside.png`.
- The run then set the window back to 1440 x 889.

## 5. Named layouts

Method: the Layouts popover (button L). Type a name, push Enter, then use Load and Delete.

Result: pass.

- Save "Wide": Selected Item at (980, 501), the locked stack, Overview at (16, 16). Screenshot: `m2-findings/05a-layout-wide-saved.png`.
- Save "Compact": Selected Item at (16, 400), Overview minimised. Screenshot: `m2-findings/05b-layout-compact-saved.png`.
- Load "Wide" gave the same rects, stack, active tab, opacity and lock. Screenshot: `m2-findings/05c-layout-wide-loaded.png`.
- Load "Compact" gave the same rects and the minimised Overview. Screenshot: `m2-findings/05d-layout-compact-loaded.png`.
- Delete "Wide": the list had only "Compact". The panels did not change. Screenshot: `m2-findings/05e-layout-wide-deleted.png`.
- Name limit: an empty name, a name of 3 spaces and a name of 41 characters each showed "Use 1 to 40 characters." A change in the field removed the message. A name of 40 characters saved. Screenshot: `m2-findings/05f-layout-name-message.png`.
- Store limit: with 20 layouts, a new name showed "Delete a layout first. The limit is 20." The list stayed at 20. A save with an existing name ("Compact") replaced it with no message. Screenshot: `m2-findings/05g-layout-limit-20-message.png`.
- The list of 20 scrolls. Its maximum height is 256 px.
- The 20 layouts were still there after a restart.
- Load in a smaller window (1000 x 700): the Selected Item moved from y 400 to y 312, inside the area. Screenshot: `m2-findings/05h-layout-loaded-in-small-window.png`.

## 6. Display modes

Method: System Events `click menu item` for View > Window, Borderless and Fullscreen. A `CGEvent` Cmd+Ctrl+F sent to the Bifrost process. Read the page size and `window-state.json` (read only).

Result: part pass.

- The View menu items have the correct keys: Fullscreen has Ctrl+Cmd+F. Window > Close Panel has Cmd+W.
- Borderless: the page became 1512 x 982 (the screen size). The menu check moved to Borderless. Screenshot: `m2-findings/06a-borderless.png`.
- Task 7 review question 1: in Borderless, `window-state.json` kept the normal bounds: `{"x":36,"y":33,"width":1440,"height":889}`, with `"mode":"borderless"`. This was true after the 500 ms timer and after a quit in Borderless.
- Restart in Borderless: Bifrost started in Borderless. The View menu showed Borderless. The layout was the same, and a panel at the bottom right corner (1052, 626) stayed there. Screenshots: `m2-findings/06c-borderless-after-restart.png` and `m2-findings/06d-borderless-restart-same-layout.png`.
- View > Window: the page became 1440 x 857 again, at screen position (36, 33). Screenshot: `m2-findings/06e-window-mode-from-menu.png`.
- Fullscreen: no attempt started native full screen. Screenshot: `m2-findings/06b-fullscreen-not-entered.png`.
  - Cmd+Ctrl+F in Borderless: Bifrost left Borderless and stayed in Window (O4).
  - Cmd+Ctrl+F in Window: no change.
  - View > Fullscreen: no change. The check mark moved to Fullscreen (D1).
  - The macOS item View > Enter Full Screen: no change.
- The macOS item also failed, so the cause is the locked screen, not Bifrost.
- Task 7 review question 2 (the mode after a quit in Fullscreen): not checked. This is item 1 for the user.

## 7. Cmd+W

Method: three ways to give Cmd+W. Read the frames, the page targets on port 9333 and `document.visibilityState`.

Result: pass.

- `agent-browser press Meta+w`: no change. CDP key events go to the page, not to the native menu. M1 finding F10 has the same result for Cmd+Q.
- System Events click on Window > Close Panel: the stack lost its active tab (Overview). The window stayed open. Screenshot: `m2-findings/07a-close-panel-menu-item.png`.
- Cmd+W as a `CGEvent` sent to the Bifrost process: the last panel (Selected Item) closed. The page target stayed, and the page was visible. Screenshot: `m2-findings/07b-cmd-w-key-closed-last-panel.png`.
- A second Cmd+W with no panel open did nothing. The window stayed open.
- The run did not use the System Events `keystroke` command. A check in the script found Warp in front, so the script did not send the key.

## 8. Content scroll

Method: read `scrollWidth` and `clientWidth` of `[data-frame-content]` of the Overview (frame width 800). Send a wheel event over the content.

Result: pass.

- `scrollWidth` 1398, `clientWidth` 798, `overflow` auto. The table is 1390 px wide.
- A CDP `Input.dispatchMouseEvent` wheel event (`deltaX` 250 at client 600, 600) gave `scrollLeft` 250.
- `agent-browser scroll right 400 -s '[data-frame-id="f1"] [data-frame-content]'` gave `scrollLeft` 400. Screenshot: `m2-findings/08a-content-scrolled-right.png`.
- macOS hides the scroll bars until a scroll. Screenshot: `m2-findings/08b-content-wheel-scroll.png`.
