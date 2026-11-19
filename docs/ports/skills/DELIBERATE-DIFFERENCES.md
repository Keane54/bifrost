# Deliberate differences

This page lists the places where the native app deliberately behaves differently from the
Electron app for the bundled plugins: the files of the Live details mod and of the skills plugin,
the folder sync that installs them (`mod-folder.ts`, `skills-folder.ts`), the parse of a skill
file (`skill-check.ts`), the skills list and the skills control (`skills-control.ts`). The
TypeScript code is the reference for what Bifrost decides, not for how it gets there, and the last
column says whether you'd notice the difference in normal use.

Only K4 is visible: Settings > Live details and Settings > Skills show the text of a failed sync
in their error line. The look of the Skills section is row S10 of
`docs/ports/settings/DELIBERATE-DIFFERENCES.md`.

| ID | Where | TypeScript | Swift | Reason | Visible? |
| --- | --- | --- | --- | --- | --- |
| K1 | Where the plugin files live | The Electron repo keeps them in `resources/live-mod` and `resources/bifrost-skills`, and the packaged app unpacks them next to `app.asar`. | The native repo owns its own copy in `App/Bifrost/Resources`, taken once from the Electron repo, and the app bundles both folders in `Contents/Resources`. Nothing compares the two repos after that. The two example PR keys of the review skills say `example-org/api` in place of the placeholder company name. | Bifrost Dev owns Live details and the skills plugin (user decision, 2026-11-16), and the repo has no names of people or companies. | No. Claude Code gets the same mod and the same skills. |
| K2 | Links at and inside the folders | A read follows a link: a mod file that's a link, an installed folder that's a link, or a source folder that's a link reads through to the target, so a linked copy with the right bytes counts as current. | No step follows a link at an installed folder or inside either folder. A copy with a link in it, or a copy that is a link, isn't current, and the sync replaces it. A link at the path of a folder to list is an error, where Node lists the target. A removal deletes a link, never its target. The skills list doesn't read a `SKILL.md` that is a link, where the Electron list reads through it, and a `skills` folder that is a link is an error, where the Electron list follows it. Both lists skip a skill folder that is a link. | The sync must never read, write or delete anything outside its own folders. | No. Bifrost makes these folders itself. |
| K3 | Writing the new folder | Each file is written with no flush, so a power cut right after the swap could leave an empty file. | Each file is flushed to the disk (a full sync) before the swap. | Claude Code loads `register.ts` at the start of each session, so a damaged file would break Live details until the next sync. | No. |
| K4 | Error texts | Node's texts, for example `ENOENT: no such file or directory, open '<path>'`, and `The skills folder of the app has no files.` | The native form `<action> <path>: <reason>.`, for example `Cannot read <path>: No such file or directory.`, and `The skills folder in the app has no files.` The text for an old folder that can't go back is the same in both. | Error texts are native Swift texts (user decision, 2026-11-15). | Rarely: the error line of Settings > Live details or Settings > Skills shows the text of a failed sync. For the hands-on test. |
| K5 | Replacing the installed folder | Two renames: the old folder goes aside, then the new folder goes into place, so for a moment no folder is at the path. | When the installed folder exists, one swap (`renamex_np` with `RENAME_SWAP`) changes the two names in a single step, and the old folder then goes. The two renames stay for a first install and for a file system that can't swap. | A Claude Code session that starts during a sync always finds the plugin folder. | No. |

## The skills control

`SkillsControl` follows the rules and texts of `skills-control.ts`, in the same way as the Live
details control follows `live-control.ts` (rows C1 to C5 of
`docs/ports/live/DELIBERATE-DIFFERENCES.md`). A user can't see these rows, and
`SkillsControlTests` pins each of them with the fake claude.

| ID | Where | TypeScript | Swift | Reason | Visible? |
| --- | --- | --- | --- | --- | --- |
| K6 | The start | `ipc.ts` calls `skills.start()` inside the one start of the serial runner, after the clean-up of the old hook data and the Live details start, unless the app is quitting. | `SkillsControl.start()` runs a start of its own in the lock (`SerialLock.first`). The app calls it straight after the Live details start, so it runs after that start, and an action or a status read waits for both. The quit cancels it. | The control owns its start, as `LiveControl` does (C4 and C5). | No. Test: `theSkillsStartRunsAfterTheLiveStartInTheLock`. |
| K7 | A cancel or the quit during an action | Nothing cancels an action. | As C2: an action checks for the quit between two steps, and stops with `Bifrost stopped the Claude Code command.` A cancel of the caller does the same, but only before the first `claude plugin` write, and it also stops a list read at once. From the first write on, the action runs to its end, and only the quit ends it. No action runs after the quit. | A change that nothing waits for any more shouldn't start, but one that has changed the plugin state must bring it to a clear end. | No. Tests: `aCancelledActionChangesNothing`, `aCancelAfterTheMarketplaceAddStillInstallsAndTurnsOn`, `aStopAfterTheMarketplaceAddEndsTheActionAtItsNextStep`, `aStopBetweenTwoStepsChangesNothing`, `aStopCancelsTheStart`. |
| K8 | The refusals of the actions | Errors with texts. | `PluginFailure` cases with the same texts: `claudeNotFound`, `notInstalled`, `foreignMarketplace` and `folder`. | One typed error for the plugin changes (C3). | No: the texts are the Electron texts, and a failed sync has the native text of K4. |
| K9 | The log of a failed start | `console.warn` with `Bifrost skills: the start failed.` and the error. | One line in the unified log, `Bifrost skills: the start failed. <reason>`, with the reason private. | The app logs through `os.Logger`. | Only in Console. Test: `aFailedListStopsTheStartWithOneLogLine`. |

## Not ported

- The Electron repo's check script for its skill files (`scripts/check-skills.ts`, with the
  plugin rules of `checkPlugin`) isn't ported as a script. The tests
  `eachSkillFileOfTheRepoParsesWithItsGroup` and `theSkillsPluginOfTheRepoKeepsItsLimits` and the
  `bundled` step of `scripts/check.sh` check the same rules on the repo copy, and the parse
  itself is ported as `SkillCheck`.
- The Electron app's content tests of the skill files aren't ported, because the native repo owns
  its copy now, and a change to a skill brings its own test.
- The source checks of the daily update and review skills belong to the phase 5 skills of the
  Electron repo, so they aren't ported here.
- The mod's own TypeScript test (`resources/live-mod/tests/register.test.ts`) stays in the
  Electron repo, and only the four mod files are copied. A change to `hooks/register.ts` needs a
  new test in this repo.
- The paths of the plugin folders inside `app.asar.unpacked` aren't needed. The native app reads
  both folders from `Contents/Resources` of its bundle.
- The Electron test that reads the source of `ipc.ts` to check the wiring of the skills control
  (`wiring-source.test.ts`) isn't ported: it reads TypeScript source, not behaviour.
  `SkillsControlTests` checks that the skills start runs after the Live details start in the
  lock, and `oneStepGivesBothControlsAndTheLivePluginListRunsFirst` (`AppServicesTests`) checks
  that an observer of the app sees the two controls come in one step, and that the plugin list of
  the Live details start runs before the marketplace list of the skills start.
