# Bifrost modules: the author guide

A module adds your own panels to Bifrost. A module is a folder of static web files with a manifest. Each panel of the module runs in a sandboxed frame. The frame has no network, no Node, no file access and no clipboard read. The panel talks only to Heimdall, the secure core of Bifrost. Heimdall checks each call in the main process.

Known limit: if a browser bug takes over the process of a module, that process can send UDP to a fixed IP address. HTTP, TCP and DNS stay blocked. Bifrost tracks a browser-side block for UDP.

A module never gets a secret. Heimdall holds the secrets, uses them for the module, and filters each value that it gives to the module.

## The folder

```
<module>/
  bifrost-module.json   the manifest
  panels/<panel>.html   one HTML entry for each panel, with its JS and CSS
  ...                   other static files (images, fonts, data)
```

Rules:

- Use only static files. If you use a web framework, ship the built files.
- Do not put a symbolic link in the folder. Bifrost refuses the install.
- Bifrost does not copy a file or a folder whose name starts with a dot.
- A file can have 5,000,000 bytes or less. The module can have 50,000,000 bytes and 2,000 files or less.
- The protocol serves only these file types: `.css`, `.gif`, `.html`, `.jpeg`, `.jpg`, `.js`, `.json`, `.mjs`, `.otf`, `.png`, `.svg`, `.ttf`, `.txt`, `.webp`, `.woff`, `.woff2`.
- Do not use the folder `_bifrost`. Bifrost serves its own files there.

## The manifest

The file `bifrost-module.json` is a JSON object with these keys. Bifrost refuses an unknown key.

| Key | Value |
|---|---|
| `id` | 2 to 40 characters: lower-case letters, digits and `-`. It starts with a letter. It must be unique. |
| `name` | 1 to 40 characters. Bifrost shows it on the panels and on the notifications. |
| `version` | Three numbers, for example `1.2.3`. |
| `description` | 1 to 200 characters. |
| `minBifrost` | The lowest version of Bifrost that the module needs, for example `0.5.0`. |
| `panels` | A list of 1 to 8 panels. |
| `permissions` | A list of permissions, each with a reason. You can leave it out. |
| `suggests` | A default model and a default daily cap for the module jobs. You can leave it out. |

The `name`, the `description`, each panel `title` and each permission `reason` must not have control characters (also new lines and tabs), hidden format characters (for example zero-width, direction or tag characters), line and paragraph separators, the combining grapheme joiner (U+034F) or the Hangul fillers (U+115F, U+1160, U+3164 and U+FFA0). Bifrost refuses such a manifest with "A text in the manifest has hidden or control characters."

Each panel has these keys:

| Key | Value |
|---|---|
| `id` | 1 to 30 characters: lower-case letters, digits and `-`. It starts with a letter. |
| `title` | 1 to 40 characters. The side bar button and the title bar of the panel show it, with the name of the module. |
| `icon` | The icon of the side bar button. One of: `activity`, `bell`, `book-open`, `bot`, `calendar`, `chart-bar`, `clock`, `file-text`, `gauge`, `inbox`, `layout-dashboard`, `list-checks`, `message-square`, `notebook`, `sparkles`, `star`, `terminal`, `timer`, `wrench`, `zap`. |
| `entry` | The path of the HTML file of the panel. It starts with `panels/` and ends with `.html`. |

The side bar has one button for each panel of each module that is on. When a module is off or removed, its open panels show a notice in place of the module page.

The `suggests` object has two keys. `model` is `""` (the default model of Claude Code), `"opus"`, `"sonnet"`, `"haiku"` or `null`. `dailyCap` is a number from 1 to 500, or `null`. Without a suggestion, Bifrost uses the default model of Claude Code and a cap of 50. The user can change both in Settings > Modules > Permissions.

Example:

```json
{
  "id": "hello",
  "name": "Hello",
  "version": "1.0.0",
  "description": "Shows the sessions and says hello.",
  "minBifrost": "0.5.0",
  "panels": [
    { "id": "main", "title": "Hello", "icon": "sparkles", "entry": "panels/main.html" }
  ],
  "permissions": [
    { "id": "read-sessions", "reason": "To show the names of your sessions." },
    { "id": "notify", "reason": "To tell you when the list changes." }
  ]
}
```

## Permissions

Ask only for the permissions that the module needs. Each permission needs a `reason` of 1 to 200 characters. Write the reason for the user: tell what the module does with the permission. Heimdall's approval window shows each reason. The module runs only after the user clicks "Allow". "Allow" gives the module all the permissions that its manifest asks for.

The user can remove a permission at any time in Settings > Modules > Permissions. Then Heimdall refuses the calls of that permission with `refused: not allowed for this module`. Make sure that the module can work without it. The user can also give the permission back there. When the user removes `claude-jobs`, each module job of the module that did not start ends with `refused: job cancelled`. When the user removes `claude-jobs-auto`, each job that did not start waits for Refresh.

| Permission | What it gives |
|---|---|
| `notify` | A Bifrost notification. The title starts with the name of the module. |
| `read-sessions` | The session list: the name, the state, the folder, the branch and the PR link of each session. |
| `read-usage` | The plan usage: the 5-hour and the 7-day limits. |
| `read-service-status` | The status of the public status pages that Bifrost checks. |
| `claude-jobs` | A short module job with no tools, on text that the module gives. |
| `claude-jobs-auto` | A module job runs when the module asks. Without it, each job waits until the user clicks Refresh in the title bar of a panel of the module. |
| `discuss` | The module can ask Heimdall to open "Discuss with Claude". The user writes the prompt and picks the folder. |

The storage of the module and its own panels need no permission.

A newer version of Bifrost knows more permissions. This version refuses them at the install, with "This module needs a newer version of Bifrost."

## Install and update

The user installs a module in Settings > Modules:

- **Install from a folder.** Bifrost copies the folder. It checks the rules of "The folder" and the manifest first.
- **Install from a git repo.** Bifrost clones the repository with the `gh` login of the user, so a private repository works. Bifrost accepts only `https://github.com/<owner>/<repo>`, with or without `.git`. For each other repository, clone it yourself and use "Install from a folder".
- **Load from folder (developer).** This shows only in a development build of Bifrost (`pnpm dev`). Bifrost uses the folder in place, so a change to a file shows when the panel opens again. A packaged Bifrost turns such a module off.

Then Heimdall's window shows the tier, each permission with its reason, and what a module can never do. The module runs only after "Allow". If `minBifrost` is higher than the version of Bifrost, Bifrost refuses the install with "This module needs a newer version of Bifrost."

"Check for updates" copies each folder module again, and clones each git module again. A new version with the same permissions or fewer permissions runs at once. A new version that asks for a new permission does not run. The old version runs, and the row of the module tells the user. The user clicks "Check update" to see the new permissions in Heimdall's window. "Allow and update" runs the new version. A permission that the user removed stays removed after an update. The `id` of a module must not change.

Remove deletes the copy of the module and its storage.

## The client library

Load the client library in each panel, before your own scripts:

```html
<script src="/_bifrost/api.js"></script>
<script type="module" src="./main.js"></script>
```

The library adds one object, `bifrost`:

- `bifrost.call(name, args)` sends a call to Heimdall. It gives a promise. The promise resolves with the value of the call. If Heimdall refuses the call, the promise rejects with an `Error`. The message of the error is the refusal code, for example `refused: not allowed for this module`.
- `bifrost.on(event, fn)` calls `fn(data)` for each event with that name. It gives a function that removes the listener.

The source of the library is TypeScript, in `src/module-api/api.ts` of the Bifrost repository. Bifrost serves the compiled file, a classic script with no `import` or `export`.

Example:

```js
const list = document.querySelector('#sessions')

async function show() {
  try {
    const sessions = await bifrost.call('sessions.list')
    list.textContent = sessions.map(s => `${s.name} (${s.state})`).join('\n')
  } catch (error) {
    list.textContent = `No sessions: ${error.message}`
  }
}

// Heimdall sends the refresh event when the user clicks Refresh.
bifrost.on('refresh', show)
show()
```

## Calls

Each value of a call must be JSON. Heimdall refuses a value that JSON cannot hold.

| Call | Permission | Arguments | Value |
|---|---|---|---|
| `storage.get` | none | `{ key }` | The saved value of the key, or `null`. |
| `storage.set` | none | `{ key, value }` | `null`. A `value` of `null` removes the key. |
| `notify` | `notify` | `{ title, body }` | `null`. |
| `sessions.list` | `read-sessions` | none | A list of `{ name, state, folder, branch, prUrl }`. |
| `usage.get` | `read-usage` | none | `{ source, updatedAt, fiveHour, sevenDay }`, or `null`. |
| `serviceStatus.get` | `read-service-status` | none | A list of `{ id, name, level, since, checkedAt, incidents }`. |
| `claude.job` | `claude-jobs` | `{ prompt, input, json }` | `{ text }`, or `{ json }` when `json` is `true`. |
| `discuss.request` | `discuss` | `{ title, cards }` | `null`. |

Details:

- **Storage.** Each module has one JSON object. A key has 1 to 64 characters: lower-case letters, digits, `.`, `_` and `-`. All the keys and values of a module can have 1 MB of JSON or less. A value can have 32 levels of objects and arrays or less. Bifrost writes the storage file at most one time in a second. An update keeps the storage. Bifrost removes the storage when the user removes the module.
- **notify.** The `title` has 1 to 80 characters. The `body` has 300 characters or less. You can leave out the `body`. Bifrost shows the notification only when the user has Notifications on in Settings.
- **sessions.list.** `state` is `working`, `needs-you`, `error`, `idle` or `parked`. `branch` and `prUrl` can be `null`. `prUrl` always starts with `https://`. The list never shows a session that "Discuss with Claude" started.
- **usage.get.** `source` is `account` or `session`. `updatedAt` is a time in milliseconds. `fiveHour` and `sevenDay` are `{ usedPercent, resetsAt }` or `null`. A plan can have no 5-hour limit.
- **serviceStatus.get.** `level` is `none`, `minor`, `major`, `critical`, `maintenance` or `unknown`. Each incident is `{ name, impact, status, startedAt }`. A time is in milliseconds, or `null`.
- **claude.job.** Heimdall runs a short module job on the text of the module. The job has no tools: no files, no shell, no web and no MCP servers. It also has no slash commands, no skills and no memory, and it saves no session. `prompt` has 1 to 20,000 characters. `input` has 200,000 characters or less. You can leave out `input` and `json`. Claude gets a fixed line from Bifrost first, then the prompt, then the input in an `<input>` block. So a prompt that starts with `/`, `!` or `#` is only text. With `json: true`, Heimdall asks Claude for one JSON value and gives `{ json }`. Else it gives `{ text }`. The arguments must also fit in one message of 256 KB.
- **A large result.** The value of the call must also fit in one message of 256 KB. A larger result gives `refused: module message too large`, and the job still counts against the cap. Ask Claude for a short answer.
- **The result of a job is data.** Claude can write text that looks like a command or a tool call. Show the result as text. Do not run it as code.
- **The model and the cap of the jobs.** The user chooses the model of the jobs and the daily cap of the module. A job counts against the cap when it starts. The cap also counts the jobs that wait, so a module cannot queue more jobs than its cap. The day is the local day of the Mac.
- **The run mode.** Without `claude-jobs-auto`, a job waits until the user clicks Refresh. A job that does not start within 10 minutes ends with `refused: job cancelled`. Call `claude.job` and listen for the `refresh` event. Do not make a Run button of your own.
- **Jobs at the same time.** One job of a module runs at a time. Bifrost runs two jobs at a time for all modules. The other jobs wait for their turn. When the user closes a panel, its job continues, and the result goes to no panel.
- **discuss.request.** Heimdall opens its own panel, "Discuss with Claude". The module cannot draw or change this panel. The prompt box always starts empty. The user writes the prompt, picks the folder and clicks "Start session". Only the text of the user goes to Claude. The session starts with the normal Claude setup of the user. Its name is `<module name>: <the first words of the prompt>`, with 64 characters or less. The `title` is not in the session name. Only Heimdall's panel shows it. A "-" or a space at the start of the module name is not in the session name. The module gets `null` at once, and no event and no value about the session. `sessions.list` does not show the session. If Heimdall shows an install approval at that time, it cancels the request. `title` has 1 to 80 characters on one line, with no control, format or separator character. `cards` is a list of up to 8 cards of `{ label, text }`. You can leave out `cards`. A `label` has 1 to 40 characters with the same rules. A `text` has 1 to 4,000 characters, and it can have more lines. Heimdall shows each card as plain text with a Copy button. Claude does not see a card. Heimdall copies the card itself, and removes the invisible characters and the control characters. The invisible characters are the zero-width, direction and tag characters, the variation selectors, and each other character that Unicode calls "default ignorable". A session never starts in the folders of the modules, in their storage folder or in the folders of the module jobs. Heimdall compares the folders by their identity on the disk, so a link or another form of the path does not change the result.
- **Calls with no arguments.** Give no arguments, `null` or `{}`. Heimdall refuses other arguments.

## Events

Heimdall sends events to all the open panels of a module. Use `bifrost.on` to get them.

| Event | Data | When |
|---|---|---|
| `refresh` | `null` | The user clicks Refresh in the title bar of a panel of the module. |

## Secrets in values

Heimdall filters each value that it gives to a module. Each text that looks like a token or a private key becomes `***`, also a text that the module saved itself. The filter finds these formats:

- GitHub, Slack and npm tokens.
- Anthropic, AWS, Stripe live and Google API keys.
- JSON web tokens and Bearer values.
- Private key blocks.

The prompt and the input of a module job also go through the filter before the job runs. The result of the job goes through it after the job.

## Limits and refusal codes

| Limit | Value |
|---|---|
| Calls of one module | 100 in one second |
| Storage sets of one module | 10 in one second |
| Calls of one module that wait for an answer | 32 |
| One message, in each direction | 256 KB of JSON |
| Storage of one module | 1 MB of JSON |
| Notifications of one module | 10 in one minute |
| Module jobs of one module in one day | The daily cap of the module |
| Module jobs of one module that run at the same time | 1 |
| Module jobs that run at the same time, for all modules | 2 |
| The run of one module job | 2 minutes |
| The wait of one module job before it starts | 10 minutes |
| Open Discuss requests, for all modules | 1 |
| The wait of a module after the user cancels its Discuss request | 5 seconds |

| Code | Cause |
|---|---|
| `refused: module off` | The module is off or not installed. |
| `refused: not allowed for this module` | The module does not have the permission of the call. |
| `refused: unknown module call` | Heimdall does not know the call. |
| `refused: bad module input` | The arguments do not have the right form. |
| `refused: too many module calls` | The module is over a limit of calls, storage sets or notifications. Wait, then try again. |
| `refused: module message too large` | The arguments or the value are larger than 256 KB. |
| `refused: module storage is full` | The storage would become larger than 1 MB. |
| `refused: module call failed` | Heimdall could not finish the call. Try again later. |
| `refused: daily job cap reached` | The module used all of its module jobs for today. |
| `refused: job cancelled` | The job did not start within 10 minutes, Bifrost stopped, or the user turned the module off, removed it, or removed `claude-jobs`. |
| `refused: the job took too long` | The job ran for more than 2 minutes. |
| `refused: the job failed` | Claude Code did not give a result. Try again later. |
| `refused: the job result is not JSON` | The call asked for JSON, and the result was not one JSON value. |
| `refused: a discuss request is open` | Heimdall shows a Discuss request now, of this module or of another module. Wait until the user closes it. |
| `refused: discuss asked too soon` | The user cancelled the last Discuss request of the module less than 5 seconds ago. |

## What a module can never do

A module can never:

- Get a secret: tokens, logins, keys, `.env` files, session transcripts, terminal output or the clipboard.
- Use the network, open a window or move its frame to another page.
- Read a file outside its own folder. It can read a file only when the user picks the file or drops it on the panel.
- Start, read, type into or change a Claude session. "Discuss with Claude" only asks the user. The user writes the prompt.
- Change the settings, skills, hooks or repository trust of Bifrost or Claude Code.
- Give itself more permissions. Only the user's "Allow" in Heimdall's window does that.

The network item has one known limit. If a browser bug takes over the process of a module, that process can send UDP to a fixed IP address. HTTP, TCP and DNS stay blocked. Bifrost tracks a browser-side block for UDP.
