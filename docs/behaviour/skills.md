# The bundled plugins and the folder sync: behaviour

Bifrost ships two small Claude Code plugins inside the app. The Live details mod is a TypeScript
module that Claude Code loads into each session, and it sends every session event to the Live
details server (see `live.md`). The Bifrost skills plugin is a folder of Markdown skills, such as
`bifrost-review` and `bifrost-grill`. Claude Code doesn't read either plugin from the app bundle.
It reads an installed copy of each in your home folder, `~/.bifrost/mod` and `~/.bifrost/skills`,
and Bifrost keeps those copies the same as the files it ships.

This page covers the files that the app bundles, the folder sync that keeps the installed copies
current, the rules for a skill file, the list of skills that the Settings window shows, the
skills control that installs and removes the skills plugin, and the Skills section of Settings.
The code is in `BifrostLive/Services` (`FolderSync.swift`, `FolderTree.swift`, `SkillsList.swift`,
`SkillsControl.swift`), `BifrostLive/Model` (`SkillCheck.swift`, `SkillsNotice.swift`) and
`BifrostSettings/UI/SkillsSection.swift`. Where the native app deliberately differs from the
Electron app, `docs/ports/skills/DELIBERATE-DIFFERENCES.md` explains how and why.

## The bundled files

The repo owns both plugins. The mod is in `App/Bifrost/Resources/live-mod`, which holds only the
four files that the mod needs, and the skills plugin is the whole
`App/Bifrost/Resources/bifrost-skills` folder, with its `.claude-plugin` manifest and one folder
for each skill. The app's project lists both as folder references, so a build copies each folder
whole into `Contents/Resources`, dot folders included.

Two checks guard the bundled copies:

- The `bundled` step of `scripts/check.sh` (`scripts/check-bundled.sh`) fails when the repo copy
  lacks a mod file or has an empty skills folder, and when the built Debug app lacks a mod file
  or a skills file, has other bytes for one, or has an extra file in its skills folder. A link
  doesn't count as a file, and any link in the four folders is a fault of its own. The step
  `bundled-selftest` proves that a changed byte, a missing file, an extra file and a link each
  fail it.
- Three tests read the repo copy. `eachModFileIsARegularFileOfTheRepo` checks the four mod
  files. `eachSkillFileOfTheRepoParsesWithItsGroup` parses every `SKILL.md`, checks that its name
  is its folder, and pins its group, so adding a skill or moving one to the other group changes
  that test. `theSkillsPluginOfTheRepoKeepsItsLimits` keeps the plugin within Claude Code's
  limits: only the known frontmatter fields, a description that isn't empty, at most 250
  characters of description and `when_to_use` for each skill and 1,500 for all the listed skills
  together, at most 500 lines in a `SKILL.md`, a manifest named `bifrost`, and no hooks.

`hooks/register.ts` runs inside Claude Code, so a change to it needs its own test in this repo.

## The folder sync

The folder sync makes an installed folder a copy of a bundled one. It builds a complete new
folder next to the installed one and then swaps the two. On APFS the swap is a single step, so
the installed folder is never missing and never half written. On a first install, and on a file
system that can't swap two folders, the sync uses renames instead. With an old folder in place,
that leaves the path empty for a moment, but Claude Code still never sees a half-written folder.

- The mod copy holds exactly four files: `.claude-plugin/plugin.json`,
  `.claude-plugin/marketplace.json`, `hooks/hooks.json` and `hooks/register.ts`. Any other file
  in the bundled mod folder stays behind.
- The skills copy holds every regular file of the bundled skills folder, including the files in
  dot folders.
- A mod copy is current when each of the four files has the bundled bytes. A skills copy is
  current when it has the same files as the bundle, with the same bytes and nothing extra, and the
  bundle has at least one file. A missing folder, or a file that can't be read, makes a copy not
  current.
- A sync of a current copy does nothing. Otherwise it reads every bundled file first, so a missing
  file stops the sync before anything changes, and a bundled skills folder with no files stops it
  with `The skills folder in the app has no files.`
- The sync then writes the files into `<folder>.<uuid>.tmp`, with mode 0700 for each folder and
  0600 for each file, and flushes each file to the disk. A missing parent folder, such as
  `~/.bifrost` on a first install, is made with mode 0700, and so is each missing folder above
  it. A parent that already exists keeps its mode.
- When the installed folder exists, the sync swaps it with the new folder in one step
  (`renamex_np` with `RENAME_SWAP`), so the old folder ends up at the temporary name, and then
  removes it. If the swap fails, the sync removes the new folder and reports the error, and the
  installed folder stays as it was.
- On a first install, or when the file system can't swap, the sync renames the old folder (if
  there is one) to `<folder>.<uuid>.old`, renames the new folder into place and removes the old
  one. If the second rename fails, it puts the old folder back and reports the first error. If
  the old folder can't go back, the error says where it is:
  `<error> The old folder is at <folder>.<uuid>.old. Move it back to <folder>.`
- A failed removal of the old folder after a good swap isn't an error, because the copy is
  current by then.
- Removing an installed folder removes it with everything in it, and a missing folder is fine.

The sync never follows a symbolic link at an installed folder or anywhere inside the two folders,
so it can't read, write or delete anything outside them:

- A link isn't a regular file, and a file list never goes into a linked folder. A copy that
  contains a link, or anything else that isn't a regular file or a folder (a FIFO, for example),
  is not current, and the next sync replaces it.
- An installed folder that is itself a link is not current. The swap moves the link itself to
  the temporary name and removes it there, so the folder it pointed to stays as it was.
- A removal deletes a link, never the thing it points to, and it empties each folder through that
  folder's own handle, so a folder swapped for a link halfway through can't redirect it.

A failed call reports the native error text, `<action> <path>: <reason>.` A read that fails names
the bundled file, for example
`Cannot read <app>/Contents/Resources/live-mod/hooks/register.ts: No such file or directory.`,
because a failed read of an installed file only makes the copy not current.

## The skill files

Each skill is a folder with a `SKILL.md` whose frontmatter Claude Code reads. Bifrost only accepts
a small, strict subset of YAML there, so that every value it accepts means the same thing to
Claude Code's YAML reader:

- The file has no CR characters. Line 1 is `---`, and a later `---` line closes the frontmatter.
- Every frontmatter line is `key: value`. A key uses the letters a to z, `_` and `-`, and appears
  once. No line is blank, and a key with nothing after the colon has an empty value.
- `disable-model-invocation`, `user-invocable` and `background` must be `true` or `false`.
- A double-quoted value can only escape `"` and `\`. A single-quoted value writes a quote as two
  quotes. Nothing may follow the closing quote.
- A plain value can't start with a character that YAML reserves (`- `, `[`, `]`, `{`, `}`, `>`,
  `|`, `*`, `&`, `!`, `%`, `@`, `#`, `'`, `"` or a backtick), and it can't contain `: ` or ` #`,
  or end with `:`.
- White space around a value is trimmed, and the parse reads Unicode scalars, so a combining
  mark can't hide a quote or a colon.

`disable-model-invocation` also sets the skill's group. With `true`, the skill is called by name:
it only runs when you type it. With `false`, it's listed, which means Claude Code adds its
description to every session and Claude can start it by itself. A skill without the field has no
group.

## The skills list

The skills list reads the skills that the app ships from the bundled skills folder, so the
Settings window can show them.

- Each folder in `skills/` with a `SKILL.md` is a skill. A link isn't a folder, and a `SKILL.md`
  that is a link isn't read.
- A `SKILL.md` that doesn't parse, or that has no group, is left out.
- The name is the `name` field, or the folder's name when the field is missing or empty. The
  description is the `description` field, or empty when it's missing.
- The list is sorted by name. A bundle with no `skills` folder is an error.

## The skills control

`SkillsControl` is what the Skills section of Settings talks to. It installs, turns on, turns off
and removes the skills plugin, keeps the installed skills folder current when the app starts, and
reads the status that the section shows. It works like the Live details control (see "The Live
details control" in `live.md`), but it has no server and no old hooks to clean up. The two
controls share one plugin lock ("One change at a time" in `live.md`), so every sync and every
removal of `~/.bifrost/skills` happens inside that lock, whether it comes from the start or from
an action.

The plugin is `bifrost@bifrost-skills`, and its marketplace, `bifrost-skills`, is the installed
skills folder. Bifrost only ever changes its own marketplace: a marketplace called
`bifrost-skills` with another path, or with no path at all, belongs to another program, and
Bifrost leaves it and its plugin alone. A path with a `/` at its end, or with `.` and `..` parts,
still counts as the skills folder.

### The start rule

When the app starts, the skills control runs one start in the lock. The app starts it straight
after the Live details start, and the lock runs starts in the order they came, so the two never
overlap:

1. When another program owns the `bifrost-skills` marketplace, the start writes nothing and logs
   nothing.
2. When the plugin is installed, whether it's on or off, the start syncs the skills folder from
   the app, so a plugin that you turn on later finds the skills of this version of the app.
3. With no plugin, it writes nothing.

A missing claude, a list that can't be read or a failed sync writes one line to the log
(`Bifrost skills: the start failed.` and the reason), and the app goes on. A stop at the quit
cancels the start.

### The actions

Every action first refuses another program's marketplace, before it changes anything. Like the
Live details actions, each one checks for the quit between two of its steps, and stops with
`Bifrost stopped the Claude Code command.` when it came. A cancel of the caller ends an action
the same way, but only before its first plugin write: once a `claude plugin` write has run, the
plugin state has changed, so the action runs to its end and only the quit stops it. A cancel
while Install adds the marketplace, for example, still installs the plugin and turns it on.

- **Install** syncs the skills folder, adds the marketplace (unless it's already Bifrost's) and
  installs the plugin. If the plugin is off afterwards, because the install left it off or because
  it was installed and off already, Install turns it on. A plugin that's already on needs no
  command, but its folder still gets synced. The sync comes before the marketplace, because Claude
  Code reads the marketplace's manifest from the folder.
- **Turn on** refuses a plugin that isn't installed, then syncs the folder and turns the plugin on.
- **Turn off** turns an installed plugin off, and runs no command when there's no plugin.
- **Remove** uninstalls the plugin, removes Bifrost's marketplace and then removes the skills
  folder. With no plugin and no marketplace it runs no command, but it still removes the folder.

Sessions that run already pick up a change after `/reload-plugins` or a restart, as with Live
details.

| When | The message |
| --- | --- |
| No claude | `claude was not found.` |
| Turn on with no plugin | `Bifrost skills are not installed.` |
| Another program's marketplace | `A marketplace with the name bifrost-skills already exists at <path or source>. Bifrost did not change it.` |
| A sync or removal of the skills folder failed | the text of that failure (see "The folder sync") |
| Another change runs | `Another change is still running. Try again in a moment.` |

The path in the marketplace message comes from another program, so Bifrost drops any hidden
characters from it first, and the same cleaned text shows in the status.

### The status

The status read waits for the start but takes no lock, so it can run next to an action. It reads
the plugin list, the skills folder, the bundled skills and the marketplace list at the same time:

- `plugin`: `not-installed`, `enabled`, `disabled`, or `unknown` when the list can't be read.
- `folderCurrent`: the skills folder has the app's files, and the plugin reads that folder (or
  the list names no folder).
- `skills`: the app's skills (see "The skills list"), or none when they can't be read.
- `error`: the texts of the problems, joined with a space. The first is the text of a plugin list
  that can't be read (`claude was not found.` with no claude). Then comes
  `Bifrost couldn't read its skills. <reason>` when the skills list fails, and the text of another
  program's marketplace, which only shows while the plugin is installed. A marketplace list that
  can't be read adds nothing.

`SkillsControlTests` checks the start rule, the four actions, their refusals and the status with
the fake claude in a test home.

## Settings > Skills

The Skills section of Settings works like the Live details section (see "Settings > Live details"
in `live.md`): one state line, the buttons for that state, the steps before Install, a confirm
before Remove, the reload note after a change and an error line for a failed action. Its rules and
texts are in `SkillsNotice`. At the first start, the Setup dialog offers the same install as one of
its steps ("The Setup dialog" in `live.md`).

| State | The line |
| --- | --- |
| No status read yet | `Checking the skills...` |
| Not installed | `Not installed.`, with the dim line "You can install the skills later in Settings > Skills. The Hand over button works without them." |
| Off | `Off.` |
| On, with the app's files | `On.` |
| The list can't be read | the status error, else `Bifrost couldn't check the skills.` |
| On, with other files | the status error (such as another program's marketplace), else `The skills use files that don't match this Bifrost. Turn them off, then on again.` |

The buttons follow the same table as Live details. Install first lists its two steps, the copy of
the files to `~/.bifrost/skills` and the marketplace and plugin install, with Install and Cancel
under them. Remove asks with the confirm dialog: "Remove skills", "Bifrost turns off its skills,
removes the plugin "bifrost" and the marketplace "bifrost-skills", and deletes the folder
~/.bifrost/skills.", and Remove. Only one plugin change runs at a time across the two plugins, so
the Skills buttons are also greyed out while a Live details action runs.

Below the top part, the section lists the app's skills, even before you install them. Above the
list, a dim hint explains the two groups: "Listed skills are in Claude's skill list, so Claude can
start them by itself. Skills called by name cost no context until you type their name." Each skill
shows its name as you'd type it, such as `/bifrost-review`, then its group label, "Listed" in the
normal text colour or "Called by name" in the dim one, and its description underneath.

With no claude there's no skills control, so the section says `claude was not found.` with Try
again, but it still lists the skills of the app's bundled folder under that line. If that folder
can't be read, its reason follows: `claude was not found. Bifrost couldn't read its skills.
<reason>`.

The section reads its status once each time you open Settings, in the same way as Live details,
and the search finds it by its title, the word "plugin", the state line, the button labels and the
name of each skill, so "hand-over" finds it.
