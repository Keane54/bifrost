# Deliberate differences

This table lists the places where the native session panels work differently from the Electron
app on purpose. For the Event log, that app's code (`event-log.ts` in `src/main/events/`,
`mask.ts` in `src/main/log/`, and `log-view.ts` and `EventLogPanel.tsx` in
`src/renderer/src/events/`) is the reference for what the panel does, not for how it does it, and
for Show Info it's `show-info.ts` and `ShowInfoPanel.tsx` in `src/renderer/src/info/` and
`pr-info.ts` in `src/main/info/`. For the Watchlist it's `watch-order.ts`, `watch-colours.ts` and
`WatchlistPanel.tsx` in `src/renderer/src/watch/`, and `watch.ts` in `src/shared/`. The last
column says whether you'd notice the difference in normal use, and a row marked "for the hands-on
test" is one to check by hand in the real app.

EL3, EL4, P1 and P3 are the rows you can see in normal use. EL1, P2 and P4 show only in unusual
cases, and the others change nothing on screen.

Some parts look different and behave the same. The Electron app kept the log in its main process
and sent new entries across to the page, which merged them into a copy of its own (`mergeLog`) and
drew only the rows in view (`visibleRange`). The native panel reads the app's one log directly,
and `NSTableView` already makes only the visible rows, so neither function has a native form.
`createBatcher` is the `EventBatcher` class, which waits on the app's clock rather than on a
JavaScript timer. The log view rules take the names of the session rows (`LogView.names`, a
dictionary from row ID to name) where `log-view.ts` took the rows, because a row changes at every
event of its session and the panel should only do work when a name changes. `logRow` and
`sessionOptions` return the small `LogRow` and `SessionOption` values rather than objects, and
`maskToken`'s third argument, the replacement text, has no native caller yet, so `TokenMask.mask`
always uses `***`.

In Show Info too, some parts look different and behave the same. The Electron page asked the main
process for the PR over IPC by session ID, and `prFailure` turned a refusal of that call into a
friendly PR line. The native panel holds the row already and calls `PRLookup` directly, so there's
no such call to refuse and `prFailure` has no native form. `showInfoPanelId` and `showInfoSessionId`
are the `PanelID.showInfo` case, the `usePr` hook is the follow of the panel's model, and
`prUrlToOpen` is `PRLookup.urlToOpen`, which stays asynchronous so that a click after 5 minutes can
run `gh` again. `formatTokens` counts in whole numbers and rounds an exact half up, so it can't
overflow and doesn't share `toFixed`'s binary rounding. That only changes sizes such as 1,150,000
tokens, which no model has.

The Watchlist has no rows of its own, since it looks and behaves as the Electron panel did, but a
few of its parts have a different form. `placeAt` read the boxes of the rows from the page, where
`WatchOrder.place` works out the row and the half under the pointer from the fixed row height.
`isDragCancel` is the panel's check for the Esc key, which takes the key with a local event
monitor where the page called `preventDefault`, so the Esc never reaches the window's Esc rule.
Bifrost's key layer doesn't see that Esc either, where the page's key handler still saw the key
press.
`DEFAULT_WATCH_COLOUR` is `RunPlan.defaultWatchColour`, `WATCH_COLOURS` and `OLD_WATCH_COLOURS` are
`WatchColour` and its old names in the registry model, and the class lookups of `watch-colours.ts`
are `WatchColour.token` with `ThemeTokens.watchRowOpacity`. The error line of a failed move is
`PanelErrorLine`, the one the Overview uses, with its close button.

| ID | Where | TypeScript | Swift | Reason | Visible? |
| --- | --- | --- | --- | --- | --- |
| EL1 | The texts of the log | Only a notice or a line went through `maskToken`. The tool of an event went into the log as it came. | Every text of the log, the tool of an event included, has its line breaks and tabs turned into spaces and its hidden and default-ignorable characters removed, then goes through the mask, then is cut to 500 characters with an ellipsis. The mask comes after the clean, so an invisible character inside a token, such as a zero-width space, a soft hyphen or a word joiner, no longer hides the token from the mask. A visible mark such as a combining accent stays, as in the Electron app. The names of the session rows in the panel's labels go through the same steps, so a label never shows a token. | The tool comes from Claude Code, so the native app treats it as untrusted: a bidi control could change how the rest of a row reads, and a secret could reach the screen. `theTextsOfTheLogHaveNoHiddenCharacters`, `aHiddenCharacterInsideATokenDoesNotStopTheMask`, `aVisibleMarkInsideATokenStays`, `aLongTextIsCutWithAnEllipsis` and `theNamesAreSafeToShow` pin it. | Only for a tool, line or session name with invisible characters, a line break, a secret or more than 500 characters. |
| EL2 | The token mask | `maskToken` hid five shapes of token. Only Heimdall's secret filter hid the value of a Bearer header. | `TokenMask` also hides the value of a Bearer header and keeps the word, as Heimdall's filter does. It doesn't need a word boundary before "Bearer", so the value after a word that ends in "bearer" goes too. The patterns run in `NSRegularExpression`, which reads code units as JavaScript does, and they're skipped for a text with no run of 10 token characters, since no secret fits in less. | A Bearer header is a common way for an error text to carry a token. Hiding a little too much is safer than hiding too little. `theValueOfABearerHeaderIsHiddenAndTheWordStays` pins it. | Only for a text with a Bearer header. |
| EL3 | The rows of the panel | A list of rows drawn by the page, with the browser's `title` tooltip on a notice. | An `NSTableView` with one column, whose cell lays out the time, the session and the event. The tooltip of a notice is Bifrost's own. | `NSTableView` reuses its cells for a live list, and Bifrost draws all its own tooltips (user decision). `aNoticeRowHasTheWholeTextAsItsTooltip` pins it. | Yes: the tooltip of a notice looks like the other Bifrost tooltips. The user evaluates it by hand, for the hands-on test. |
| EL4 | The Session filter | An HTML select with its list drawn by the page. Once the chosen session's last entry left the log, the select had no option for it, so it showed another option while the table stayed filtered. Two sessions with the same name were two options. | A native pop-up menu in a box of the panel edge colour, with a tick at the choice. The chosen session stays in the menu, with its label, until you choose another, and two sessions with the same name are still two items. | A native menu gives the keyboard and VoiceOver forms of a menu, and the menu should always say what the table shows. `theSessionFilterShowsOneSession`, `twoSessionsWithOneNameAreTwoChoices` and `theFilterStaysInTheMenuAfterItsLastEntryLeavesTheLog` pin it. | Yes. The user evaluates it by hand, for the hands-on test. |
| P1 | The PR line of a review session | `gh` ran in the folder of every session, review sessions included. | No `gh` runs in a folder at or below a review folder (`StartPlan.branchSkipRoots`, by the paths or their real paths). The PR line says "This is a review session, so Bifrost doesn't run gh in its folder." | A review session can write the git config of its folder, and `gh` reads it (controller call, for the user to check). This is the same rule that keeps `git` out of those folders. `noGhRunsUnderASkipRoot` pins it. | Yes, for a review session, which is rare. The user evaluates it by hand, for the hands-on test. |
| P2 | The reasons of the PR line | Only a start error with `ENOENT` in its text counted as a missing `gh`; another start error showed Node's text, such as "spawn gh EACCES". The reason line was cut at 200 UTF-16 units, the title, the state and the reason kept every character, and the folder check had no time limit. | Any `gh` that doesn't start gives "GitHub CLI (gh) isn't installed." (or the folder text when the folder went). The reason line, the title and the state lose their hidden characters, and the line is cut at 200 characters. The folder reads have 2 seconds, after which the folder counts as gone, and a folder with no search permission counts as gone too. An output over the limit of the runner gives "GitHub CLI (gh) couldn't check for a PR." A branch that starts with "-" counts as no branch. | The native runner reports a failed start as its own outcome rather than as text to search, and the texts from `gh` and GitHub are untrusted, so a bidi control can't change how the panel reads. A hung network volume can't leave the PR line on "Loading..." for good. `theReasonLineHasNoHiddenCharacters` and `aFolderReadThatHangsGivesTheFolderTextAfterTwoSeconds` pin it. | Only when `gh` can't start for a reason other than a missing program, a text has hidden characters, or a folder read hangs. |
| P3 | Selecting the values | You could select the values (`select-text`) and copy part of a path. | The values can't be selected. The copy button after the session ID still copies the session ID. | A SwiftUI control that moves with a frame never takes the focus (the section "The UI" of the architecture design), and a selection needs the focus for Cmd+C. | Yes. The user evaluates it by hand, for the hands-on test. |
| P4 | The error line | The line showed the error of any session action, from the shared action state of the page, and a failed open of the PR only went to the console. | The line shows the failures of the panel's own buttons, Copy session ID and the PR. A failed open of the PR shows its reason there. | The native panel runs its own buttons, and a click that fails in silence looks like a bug. `aCopyThatFailsShowsItsReasonUntilTheClose` and `aFailedOpenOfThePRShowsItsReason` pin it. | Only when a click fails. It isn't on the hands-on list, because a failed copy or a failed open of the browser is hard to cause by hand, and the tests pin the text and the close. |
| P5 | Reordering the Watchlist | A drag of the list item in the page: the row faded, a line marked the drop place, Esc during the press cancelled the drag, and a release ended it. | A drag session of macOS (user rule: native features). The row fades and the line marks the drop place as before, and a picture of the row now follows the pointer. Esc, letting go outside the list or switching apps ends the drag through the system, with nothing moved. An Esc during a press that hasn't become a drag yet is now an ordinary Esc, as anywhere else in the window. | The system drag handles the pointer, Esc and the end of the drag, so the panel needs no key monitor and no window watches of its own. | Yes. The user evaluates it by hand, for the hands-on test. |
