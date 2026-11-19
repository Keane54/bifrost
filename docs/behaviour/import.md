# The import: behaviour

The import is the phase 4a work that lets the native app take over from the Electron app. Task 1
gives the app one place for the paths it shares with Claude Code, and Task 3 copies the Electron
app's stores into Bifrost Dev once, so daily use starts with your names, layouts, watchlist and
settings. Where the native app deliberately differs from the Electron app,
`docs/ports/import/DELIBERATE-DIFFERENCES.md` explains how and why.

## The shared paths of the home (Task 1)

Some of Bifrost's state lives outside its own data folders, where Claude Code can see it: the Live
details socket, the mod, the skills and Claude Code's settings file. `SharedClaudeState` (in
`BifrostFoundation/Model/SharedClaudeState.swift`, so every feature module can take it) holds
those paths for one home, so every part of the app finds them in the same place, and a test home
can never lead to a real one.

`SharedClaudeState(home:)` gives ten paths:

| Path | What it's for |
| --- | --- |
| `<home>/.bifrost/live.sock` | The socket that the Live details mod sends its lines to |
| `<home>/.bifrost/mod` | The folder of the mod |
| `<home>/.bifrost/skills` | The folder that the skills plugin reads |
| `<home>/.claude/settings.json` | Claude Code's settings file |
| `<home>/.bifrost/backups` | The copies of Claude Code's settings file from before an edit |
| `<home>/.bifrost/statusline-original.json` | The user's status line from before Bifrost changed it |
| `<home>/.bifrost` | Bifrost's dot folder, with the old hook data |
| `<home>/.bifrost/reviews` | The state, the clones and the worktrees of Reviews |
| `<home>/.bifrost/daily-update` | The settings and the drafts of the Daily update |
| `<home>/.bifrost/handovers` | The hand-over notes of the sessions |

The three last folders keep their Electron names, and the native app takes them over in place
(user decision, 2026-11-18). Claude Code's workspace trust in
`~/.claude.json` is keyed by the path of each review clone, and the `bifrost-daily-update` skill
reads `~/.bifrost/daily-update/settings.json`, so a copy to another folder would break both. The
Reviews code makes one safety copy of its state file before the first write and takes a lock.

The rules:

- The home is the resolved home, `StartPlan.sharedHome`. With a test home, that's the test home,
  so every shared path sits under the test home and no test reaches a real path.
- `AppServices.sharedState` holds the value for that home. No code of phase 4a uses it yet.
- Bifrost Dev owns these paths (user decision, 2026-11-16), so there's no owner type, no access
  object and no check for another app.
- Only the start files in `Packages/Bifrost/Sources/BifrostApp/Services` (`AppServices`,
  `StartPlan` and `SystemPathCheck`) and the test folders can call the init of
  `SharedClaudeState`, which the forbidden rule `shared-state` enforces. Every other file gets
  the paths from `AppServices.sharedState`.
- The value only holds paths. It reads no file and makes no folder.
- It takes only a home folder, never the app's identity, and none of its paths is in
  `Library/Application Support`, so the app's own data folders never point at this state by
  accident.

`SharedClaudeStateTests` and `StartPlanTests` cover these rules, and
`scripts/test-check-forbidden.sh` covers the forbidden rule. The Electron app's paths come from
`defaultPaths` and `filesOf` in `src/main/integration/integration.ts`, and from the mod and skills
folders in `src/main/ipc.ts`.

Nothing was left out of the port. The Electron app builds each of these paths where it needs one,
while the native app builds them all once, from the resolved home, so no path can follow a
different home by mistake.

## The one-time import of the Electron data (Task 3)

Bifrost Dev keeps its stores in its own support folder, `~/Library/Application Support/Bifrost
Native Dev`, while the Electron app kept the same files in `~/Library/Application Support/Bifrost`.
The two apps use the same file names and the same fields, so the native app can take the Electron
files as they are. On its first start, Bifrost Dev copies them across once, before any of its
stores opens, and from then on it works only with its own copies. `ElectronImport` (in
`BifrostApp/Services/Import/ElectronImport.swift`) does the copy, and `ElectronStores` next to it
is the read-only view of the Electron folder.

The import covers five stores:

| File | What it holds |
| --- | --- |
| `settings.json` | The settings, including the custom keys and the Daily update setup |
| `registry.json` | Local names, priorities, the watchlist and the other saved session data |
| `ui-state.json` | The current layout, the named layouts, the Overviews and the dialog history |
| `window-state.json` | The display mode and the window bounds |
| `usage-alerts.json` | The usage periods that already got a notification |

Nothing in phase 4a reads the usage alerts file yet. It comes across now so that the usage alerts
of phase 4e find it in place.

The rules:

- Only a development identity imports. `StartPlan.electronSupport` gives the Electron folder for
  Bifrost Dev and nil for the release app, because the release app uses that folder as its own
  support folder. As a second guard, the import does nothing, apart from one log line, when the
  two folders turn out to be the same folder on disk (the same device and inode).
- The Electron folder comes from the resolved home, so a test home has its own Electron folder and
  no test ever reads the real one.
- `AppServices.openUIStores()` runs the import first, and `start()` waits for the same import
  before it opens the settings and the registry, so no store opens before the import finishes,
  whichever is called first.
- The import never opens an Electron file for writing and never creates anything in the Electron
  folder.
- The import skips a store and leaves its Bifrost Dev file alone when the Electron file is
  missing, isn't a regular file, can't be read, isn't JSON, isn't a JSON object, or is a
  `settings.json` or `ui-state.json` whose `version` isn't 1. It reads the version straight from
  the JSON, because the stores' lenient decoders fall back to the defaults for a file of another
  version. The read never waits on a FIFO, so a FIFO at a store's path is just skipped.
- Otherwise the import first renames an existing Bifrost Dev file to `<name>.before-import`. If
  that name is taken, the file becomes `<name>.before-import-2`, then `-3` and so on, and the
  rename never replaces an existing file. Then the safe write (`JSONFile.write`: temp file, full
  sync, rename, mode 0600) writes the Electron bytes unchanged, so every field survives, including
  fields this app doesn't know yet.
- The marker file `import.json` in the Bifrost Dev support folder holds the report (version 1,
  the time, the imported files, the kept names and the reason for each skipped store). The import
  writes it last, and while it exists the import does nothing. If the import can't even check
  for the marker, for a reason other than it not being there, it logs one line and doesn't run.
- If a rename or a write fails, the import carries on with the other stores but writes no marker,
  so it runs again at the next start. When the write fails after the rename, the import gives the
  Bifrost Dev file its name back, so that store doesn't open empty. A run that stops partway, for
  example because the app quits during it, starts over at the next start, so an older
  `.before-import` file from the stopped run can be on disk without a mention in the marker.
- The log gets one line per store, under the `import` category.

The reasons in the report are short: `missing`, `not a file`, `not JSON`, `not an object`,
`version 2` (or `not version 1` when the version is missing or isn't a whole number), or the error
text of a failed read, rename or write, such as `Cannot read <path>: Permission denied.`

`ElectronImportTests` covers these rules with hand-written fixtures in
`Tests/BifrostAppTests/Services/Import/Fixtures/electron-support`: one file of each store with
every field filled in and one unknown field, and no private data. The tests check that the
Electron folder keeps its bytes, modes, modification times and names, that each imported file
loads in its store with every value, and that an unknown field survives both the import and the
store's next save.

There's no Electron twin to compare against, because the Electron app never imported anything.
`docs/behaviour/stores.md` describes the settings, UI state and window state files, and
`docs/behaviour/registry.md` describes the registry file.
