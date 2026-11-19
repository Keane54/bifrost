# Deliberate differences

This page lists the places where the import of phase 4a deliberately works differently from the
Electron app's TypeScript code. The TypeScript code is the reference for what Bifrost decides, not
for how it gets there, and the last column of the table says whether you'd notice a difference in
normal use. Task 1 adds the shared paths of the home, and Task 3 adds the one-time import of the
Electron stores.

The shared paths need no row. They're the Electron app's paths under the resolved home, and a
test home has its own shared paths under the test home, just as in the Electron app, so a user
sees no difference.

| ID | Where | TypeScript | Swift | Reason | Visible? |
| --- | --- | --- | --- | --- | --- |
| I1 | The first start of Bifrost Dev in phase 4 (`ElectronImport`) | Nothing. The Electron app keeps its stores in `~/Library/Application Support/Bifrost` and never reads another app's folder. | Before any store opens, Bifrost Dev copies `settings.json`, `registry.json`, `ui-state.json`, `window-state.json` and `usage-alerts.json` from the Electron folder into its own support folder, once. It renames each Bifrost Dev file it replaces to `<name>.before-import` (or `-2`, `-3` and so on), and the marker `import.json` stops any later run. A missing, unreadable or damaged Electron file, or a settings or UI state file that isn't version 1, leaves the Bifrost Dev file as it is. | User decision, 2026-11-16: the data import stays, so daily use moves to Bifrost Dev with your names, layouts, watchlist and settings, and no file is lost. | Yes, for the hands-on test: after the first start, Bifrost Dev shows the Electron app's names, layouts, watchlist and settings, and the earlier Bifrost Dev layouts are in `ui-state.json.before-import`. |
