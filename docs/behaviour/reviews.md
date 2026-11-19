# Reviews: behaviour

Reviews watches GitHub for the pull requests (PRs) that need you and shows them in the Reviews
panel, which has two tabs: To review, for the PRs where someone has asked for your review, and My
PRs, for the PRs you opened. On your own PRs, Claude can handle the review comments for you,
fixing the code, replying and resolving threads, and only asks you when a comment needs your
decision. On other people's PRs, Claude writes a careful, adversarial review, but only after you
click Review, and what it leaves is a pending review that nobody but you can see until you submit
it.

The point is to stop doing three things by hand: finding what needs you across many repositories,
starting Claude on it, and copying the results back to GitHub. Plain Swift code does the watching,
the queueing and every write to GitHub, and Claude only does the work that needs judgement. A
review never starts without your click, so the token cost stays predictable. `docs/ports/reviews/
DELIBERATE-DIFFERENCES.md` lists where Reviews deliberately differs from the Electron app.

## How it fits together

Bifrost polls GitHub through the GitHub CLI (`gh`) every two minutes by default, keeps what it
knows in `~/.bifrost/reviews`, and queues the work, running at most three Claude sessions at a time
unless you change that in Settings. Each of
those PR sessions is an ordinary Claude Code background session that runs in a worktree of
Bifrost's own clone of the repository. It reads an input file and writes a result file, and that's
all it can do to the outside world: it never commits, never pushes and never calls GitHub. Bifrost
reads the result, checks it, and makes each commit, push and GitHub write itself.

Keeping every write in Bifrost's own code matters for two reasons. Each write is plain code with
tests, and a PR can contain text that tries to give Claude instructions. Because Claude has no way
to write to GitHub, such text can't make it post or push anything; at worst it can shape a result
file, which Bifrost checks before acting on it.

| Term | Meaning |
| --- | --- |
| Request session | The Claude session that handles the comments on one of your PRs |
| Review session | The Claude session that reviews someone else's PR |
| PR session | Either of the two |
| Thread | A review comment on a line of code, with its replies. GitHub can resolve a thread |
| Top-level comment | A review summary or a PR comment, which GitHub can't resolve |
| Trusted author | Someone whose `authorAssociation` on the repository is `OWNER`, `MEMBER` or `COLLABORATOR`, or Copilot. You're never a trusted author of comments on your own PR |
| Pending review | A GitHub review that hasn't been submitted, which only its author can see |
| Round | One run of a PR session on a set of threads and comments |

Reviews has failed, even if the code works, if any of these ever happens:

- Bifrost posts text on someone else's PR before you've seen it.
- Claude and Copilot start a loop of automatic rounds on one PR.
- Bifrost changes one of your own checkouts, for example in `~/Developer`.
- Bifrost spends tokens without a clear cause, such as a review you didn't click, or a round for a
  comment it has already handled.
- Claude acts on a comment from someone outside the repository.
- Bifrost accepts a workspace trust prompt for you.

## Safety

Everything Reviews does to GitHub or to a git repository goes through a small set of closed types,
so the safety rules are part of the types and no feature has to remember them on its own. A
GitHub call is either a read or one case of a fixed list of writes, a git run is one case of a fixed
list of commands, and a commit only ever holds files that pass the file rules. On top of that, the
forbidden-construct check (`scripts/check_forbidden.py`) stops any other code from naming a GitHub
write, building its own push or making its own `gh` or `git` process. The types are in
`BifrostReviews/Model/GitHub/`, `Model/Git/`, `Services/GitHub/GHRunner.swift` and
`Services/Git/`.

### Reaching GitHub

There are exactly two ways to reach GitHub, both behind the `GitHubAccess` protocol: `GHRunner`,
which runs `gh`, and `FakeGitHub`, which the tests use instead.

- A read is a `GitHubQuery`, a GraphQL query with its variables. If any word in the query text is
  `mutation`, in any case, the runner refuses it before `gh` starts, so a read can never change
  anything. The fake refuses it the same way.
- A write is one case of `GitHubWrite`, and nothing else can write. The table below lists them
  all. No case merges, dismisses, unresolves, closes or reopens a PR, edits a PR or a branch, or
  edits, hides or deletes anyone's comment or review, except Claude's own pending draft in the
  Review panel.
- Every value goes in a variable of the JSON body that `gh` reads on stdin, never in the text of a
  mutation and never in the command line. The event of an approval or a submit is fixed in the
  text of its mutation, so no value can turn a comment into an approval.
- An approval, and every change to Claude's draft, needs a `UserClick`. Only the buttons of the
  Reviews panels and Approve in the row menu make one, so nothing in the background can approve or
  submit.

| Write | What it does | On GitHub | Needs a click |
| --- | --- | --- | --- |
| `createPendingReview` | Creates a pending review with its comments on the reviewed commit | `POST repos/<owner>/<repo>/pulls/<n>/reviews` with no `event`, so it stays pending | No |
| `addPendingThread` | Adds a comment to your existing pending review | `addPullRequestReviewThread` | No |
| `setPendingBody` | Sets the summary of your pending review | `updatePullRequestReview` | No |
| `replyToThread` | Replies to a thread on your PR | `addPullRequestReviewThreadReply` | No |
| `resolveThread` | Resolves a thread on your PR | `resolveReviewThread` | No |
| `addPRComment` | Answers a top-level comment on your PR | `addComment` | No |
| `requestReviews` | Asks a reviewer for a new review, keeping the other requests | `requestReviews` with `union: true` | No |
| `createSignedCommit` | Commits a fix that GitHub signs, only if the branch head is still the one the round started from | `createCommitOnBranch` with `expectedHeadOid` | No |
| `approveCommit` | Approves the reviewed commit with no text | `addPullRequestReview`, event `APPROVE` | Yes |
| `approveDraft` | Submits Claude's draft as an approval | `submitPullRequestReview`, event `APPROVE` | Yes |
| `editDraftBody` | Changes the summary of Claude's draft | `updatePullRequestReview` | Yes |
| `editDraftComment` | Changes one comment of Claude's draft | `updatePullRequestReviewComment` | Yes |
| `removeDraftComment` | Removes one comment from Claude's draft | `deletePullRequestReviewComment` | Yes |
| `discardDraft` | Deletes Claude's draft | `deletePullRequestReview` | Yes |
| `submitDraft` | Submits Claude's draft as a comment or as a request for changes | `submitPullRequestReview`, event `COMMENT` or `REQUEST_CHANGES` | Yes |

`gh` always runs in the Reviews folder, `~/.bifrost/reviews`, and never in a clone or a worktree,
because a PR's branch can hold a git config and `gh` reads the config of the folder it runs in. It
gets the same environment as the Claude runs (your login shell's `PATH`) plus
`GH_PROMPT_DISABLED=1` and `GH_NO_UPDATE_NOTIFIER=1`. Bifrost never reads a token itself; `gh` uses
its own login.

| Limit | Value |
| --- | --- |
| Time for one `gh` call | 30 seconds, or 120 seconds for a signed commit, which can carry 4 MiB of files |
| Output of one call | 16 MiB |
| Error line | The first line of `gh`'s error, without hidden characters, at most 200 characters |

When a call fails, the error says why in plain words, and for a write it also says whether GitHub
might have made the change anyway. Bifrost never sends such a write again by itself; it checks
GitHub first.

| Error | When | Could a write have happened? |
| --- | --- | --- |
| Not installed | `gh` didn't start | No |
| Not logged in | Exit code 4, or an error that tells you to run `gh auth login` | No |
| Not sent | Bifrost held back a read that contained a mutation | No |
| Refused | GitHub answered and the answer proves nothing changed: an HTTP 4xx status, or GraphQL errors with no result and no sign that GitHub stopped part way | No |
| Timed out | `gh` didn't finish within its time limit | Yes |
| Bad answer | The answer was over the output limit | Yes |
| Unknown outcome | Anything else, such as a network error, an HTTP 5xx status, a signal, a stop, GraphQL errors next to a result, or an error saying GitHub timed out or something went wrong | Yes |

GitHub can answer a query with data and errors together, and `gh` then exits with an error code. A
read keeps such an answer, so a poll can keep the PRs it did get. A write never does, even when
`gh` exits cleanly: its errors make it a refusal or an unknown outcome by the rules above. Errors
next to a result mean the write ran and something after it failed, and GitHub's own timeout error
can come after a write completed, so neither counts as proof that nothing changed.

### Running git

`RepoGit` runs only the cases of `GitCommand`: clone, fetch, adding and pruning worktrees, reset and
clean, status, add and commit, a merge through `merge-tree` and `commit-tree`, a handful of reads
(`rev-parse`, `cat-file`, `config --get-all`, `remote get-url`, `ls-files --stage`, `ls-tree`,
`check-attr`, `hash-object`, `diff`, `merge-base --is-ancestor`, `rev-list`) and the push.

Each command also runs at a place, a `GitPlace`, and the place pins the repository that git uses.
Bifrost works out every path from the Reviews folders and never reads it from a `.git` file,
because a request session can write the `.git` file of its worktree. If git followed that file, a
session could hand Bifrost's git its own repository, with a `core.worktree` that points at one of
your checkouts or a filter that runs a program, and a missing file would send git looking in the
folders above for any repository it could find.

| Place | What git gets | What runs there |
| --- | --- | --- |
| A new clone | Nothing extra: `git clone` makes its repository in the empty folder it runs in | Only the clone |
| The clone | `--git-dir=<clone>/.git`, in the clone folder | Everything except the commands that need a work tree, because the clone folder also holds the worktrees and the input folders |
| A PR's worktree | `--git-dir=<clone>/.git/worktrees/<number>` and `--work-tree=<worktree>`, in the worktree | Everything except the clone |

Before any command in a worktree, Bifrost checks that the worktree really belongs to the clone: the
worktree's admin folder in the clone (its `gitdir` file) has to name that same worktree. If it
doesn't, git doesn't run. The admin folder sits inside the clone's own `.git` folder, which a
session can't write.

Submodules get the same care, because a session can write the folder of a submodule too, and git
runs a submodule's own status inside that folder, with whatever config and filters the session put
there. So `status` and `diff` pass `--ignore-submodules=all`, `reset` passes
`--no-recurse-submodules`, and Bifrost never adds or commits in a worktree whose index or head holds
a submodule: a commit with nothing staged would look inside it. A review round still works on such
a repository; only a fix commit is refused.

Every command gets these config items:

| Item | Why |
| --- | --- |
| `core.hooksPath=/dev/null` | A repository can't run a hook |
| `core.fsmonitor=false` | A repository can't run a file monitor |
| `core.quotePath=false` | Paths come out exactly as they are |
| `credential.helper=` then `credential.helper=!gh auth git-credential` | `gh` gives the credentials, and no other helper runs |
| `advice.detachedHead=false` | No advice text in the output |
| `core.symlinks=false` | A link in a PR becomes a plain file holding the link text, so a session can't follow it out of the worktree |
| `submodule.recurse=false` | git never goes into a submodule |

Every command also gets `core.askPass=`, `protocol.ssh.allow=never`, `protocol.allow=never` and
`protocol.https.allow=always`, so git can't show a password prompt, use an SSH key, or talk to a
remote over anything but https (an address of another kind can run a program). That includes the
commands that don't look like network ones, because Bifrost's clones are partial: a checkout, a
reset, a diff or a merge can download a file from GitHub when it needs one.

Nothing can come after these items except the pin of the place and the fixed command. The app
adds nothing else. A test home, which has no git config of your own, can add only two closed
values, and they go before the safe items, so they can never undo one: a commit identity (a name
and an email with no control or hidden characters) and `protocol.file.allow=always`, so its
source repositories can be local folders. The second one exists only in a Debug build, so a
Release build can never reach a local remote.

git runs with no `GIT_` variable except `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_NOSYSTEM`, because
the others can point it at another repository, index, object folder, config or set of programs,
and with `GIT_TERMINAL_PROMPT=0`, `GIT_LFS_SKIP_SMUDGE=1` and `GCM_INTERACTIVE=never`. A command
gets 120 seconds, or 900 seconds for a clone or a worktree checkout, which download files, and at
most 16 MiB of output. When a command runs out of time, or Bifrost stops it, git gets a terminate
signal first, so it can remove its lock files, and a kill a second later if it's still running.
After a stop, Bifrost waits until git has really ended.

The push has exactly one form, `push --porcelain --no-follow-tags --recurse-submodules=no origin
<commit>:refs/heads/<branch>`, after `-c push.gpgSign=false`. A branch name is checked before it
gets there: it must be a name that `git check-ref-format --branch` accepts, and it can't start with
`-`, `+` or `:` or be `HEAD` or `@`. So a push can only ever move one branch forward to one commit;
it can't force, delete or touch another ref.

- Nothing signs. `commit` and `commit-tree` pass `--no-gpg-sign` and the push turns off
  `push.gpgSign`, because a key can need a passphrase and a round never waits for a person. A
  signed fix goes through `createSignedCommit` instead, which GitHub signs.
- No command uses force. A worktree goes by deleting its folder and then running
  `worktree prune`.
- Each list of paths comes after `--`, with literal pathspecs, so a path is never read as an option
  or as a pattern. Any other text that isn't an ID comes after `--end-of-options`.
- `git add` never runs with no paths, because that adds every change in the worktree, and never
  with a path that the file rules below refuse. `commit-tree` only takes a full object ID as its
  tree.

### What a fix commit can hold

A path in a fix commit has to pass `CommitFileRule` first. Each comparison ignores case, because
the default APFS volume does, and ignores characters that show nothing (such as a zero-width
space), because git and the file system can drop them.

| Refused | Because |
| --- | --- |
| An empty or absolute path, or one with a part that's `..`, `.`, empty or starts with `-` | It could point outside the worktree or read as an option |
| A path with a `.git` part | It would write into a repository's own files |
| A path in `.github/workflows/` or `.github/actions/` at the root | GitHub runs these files |
| A path with a `.claude` part at any depth | Claude Code reads its settings from these folders |
| `.gitmodules` at the root | It holds the addresses of the submodules, which is code that runs elsewhere |

`CommitFileCheck` then looks at the index and the files themselves. It refuses any commit in a
worktree whose index or head holds a submodule, for the reason above. It refuses a path that names
a folder, because `git add -A` of a folder adds or deletes every file below it, workflows and
`.claude` files included. It also refuses a submodule, a path that the commit's head holds as a
link, a symbolic link, a path reached through a folder that's a link, anything that isn't a regular
file, a file with more than one hard link, a file over 1 MiB, and a file with a `filter` attribute,
because `git add` would run the filter's program. A file that isn't there is a delete, so it has to
be exactly one entry of the index, and only the path rule and the index apply to it. If git or the
file system can't answer, the check refuses. A path inside a submodule never reaches the index, and
`git add` refuses it on its own. The files of a signed commit can add up to 4 MiB at most.

### IDs

The values that a write or a git command takes are checked types, made only from text that can't
change the target:

- A PR key comes only from an address of the exact form
  `https://github.com/<owner>/<repo>/pull/<n>` (no other host, scheme, port, path, query or
  fragment) or from a key of `state.json`, `Owner/Repo#n`. The number has 1 to 10 digits and no
  leading zero. The key keeps GitHub's spelling, but two spellings that differ only in case are the
  same PR, because GitHub names have no case. It's stored as its text.
- A commit ID is a full ID of 40 or 64 lower-case hex characters. The short form in "Fixed by"
  replies is its first seven.
- A node ID has the form of a GitHub node ID: up to 100 letters, digits, `_` or `-`, with at
  most two `=` at the end.
- A repository name is stored as `owner/name` in GitHub's spelling.

### The forbidden rules

The forbidden-construct check runs on every check of the code. Three of the Reviews rules read only
the text inside string literals, because that's where GitHub and git words live, and three read the
code.

| Rule | Where | Fails on |
| --- | --- | --- |
| `github-write` | String text in the package sources, the test support included | A mutation that Bifrost may send, or the word `mutation`, outside `GitHubWrite.swift` and `GitHubQuery.swift`; and in `BifrostReviews` and `BifrostWindows/UI/Reviews/`, a whole literal that's a flag of a write through `gh api` (`-X`, `--method`, `-f`, `-F`, `--field`, `--raw-field`, `--input`, or `-f` and `-F` with their value, as in `-fbody=x`) outside the same two files |
| `github-never` | String text in the package sources, the test support included | A mutation that merges, dismisses, unresolves, closes, reopens or edits (for example `mergePullRequest`, `unresolveReviewThread`, `deleteRef`), anywhere |
| `git-push` | Whole string literals in `BifrostReviews` and `BifrostWindows/UI/Reviews/` | The literal `"push"` outside `GitCommand.swift`, and anywhere a literal that starts with `--force`, `--mirror` or `alias.`, or is `send-pack` or `http-push` |
| `user-click` | Code outside `BifrostWindows/UI/Reviews/` and the tests, also over several lines | Making a `UserClick` (a call, `.init`, `.self.init`, a declaration, an array or a return that makes one with `.init()`, or `click: .init()`), and a parameter of type `UserClick` whose label isn't `click`, so every call shows the label the rule reads |
| `reviews-process` | Code in `BifrostReviews` | Making a `Command` outside `GHRunner.swift` and `RepoGit.swift` |
| `trust-run` | Code outside `BifrostReviews` and the tests, also over several lines | A call of `TrustRuns.check(`, so only Reviews can start `claude` in a review clone |

Whole words and whole literals keep the rules exact: a friendly text such as "Bifrost won't push
to this branch" isn't the literal `"push"`, `alias.isEmpty` is code rather than a string, and a
test name such as `createRefusesAFileAtTheFolderPath` is code too. The string rules read the text a
literal actually makes, so an escape such as `\u{6D}` counts as the letter it stands for, and a
backslash at the end of a line of a multi-line string joins the two lines. The test folders are
out of scope, so a test can name the writes it checks.

## The GitHub data

Each poll asks GitHub for everything in one call, a single GraphQL query (`PollQuery`) that `gh`
sends through the same read path as every other read. The query has two searches, written as
variables so nothing changes the query text: the open pull requests that ask for your review
(`is:pr is:open review-requested:@me archived:false`) and the open ones you wrote (`is:pr is:open
author:@me archived:false`). The answer comes back as a `PollAnswer`, which `GitHubClient.poll`
reads off the main thread, so a busy account never stalls the app.

A search gives at most 50 PRs, and each list inside a PR has a limit too. When GitHub has more, the
list is marked cut, so the rows know that a missing PR may only be on the next page. A list that
the answer lacks, or that has the wrong form, counts as cut too, and a field of the wrong form in
one PR reads as missing without dropping the PR.

| What | How many | Marked cut as |
| --- | --- | --- |
| PRs of a search | The first 50 | `toReviewCut`, `mineCut` |
| Reviews of a PR | The first 30 | `truncatedReviews` |
| Latest opinion of each reviewer | 20 | `truncatedReviews` |
| Review threads | The newest 20, with their first 10 comments | `truncatedThreads` |
| Top-level comments | The newest 30 | `truncatedComments` |
| Checks of the newest commit | 20 | `truncatedChecks` |
| Review requests and request events | 10 and the newest 10 | Not marked |

A To review PR reads no reviews, threads or comments. It reads the latest opinion of each reviewer,
which gives your own last review (for the Approve button) and the count of other approvals. A My
PRs PR reads the whole conversation, and its latest opinions give the decisions.

Some details that the rows rely on:

- A request is direct when you are one of the requested users, and a team request otherwise. The
  request time is the newest request event for you (direct) or for any team (team), or the time the
  PR was created when GitHub gave no event.
- The checks of the newest commit give one state: failing, running or passed. A result for another
  commit than the head counts as running, and a PR with no checks has no state. A failed state with
  no failed check among the first 20 still counts as one failed check.
- An author is trusted when they are an owner, a member or a collaborator of the repository, or
  Copilot (a bot with the login `copilot-pull-request-reviewer`). You are never a trusted author of
  your own PR, and no other bot is trusted (`Authors`).
- GitHub can answer with data and errors together. The poll then keeps the data, remembers the
  errors for the panel and logs them as private. Only an answer with no viewer, or with errors and
  no result for one of the two searches, fails. A PR with no valid key, such as an odd repository
  name, is dropped and counted; the rest stay.

## The state

Reviews keeps everything it knows in `~/.bifrost/reviews/state.json`, the same file, in the same
form and with the same field names, that the Electron app wrote, so Bifrost takes it over in place
rather than copying it somewhere new. The file holds the time Reviews was first turned on and the
items that were open then, the start of new work (`fixFrom`), whether you've agreed to automatic
request rounds (`autoFixConsent`), the queue, the review requests Bifrost has seen, the pauses and
the To review rows you removed, the comments Bifrost posted, the draft comments of its reviews, and
a record for each PR: its sessions, the round that's running, the items it has handled (each with
the time of its last reply, so a newer trusted comment makes it work again), the items held back
by a failed round, Claude's open questions, the writes of the last request round (the outbox), the
reviewers it asked for a new review, and a Handle now or Handle Copilot comments click that's
waiting for its round. The types are in `BifrostReviews/Model/State/`, and the store in
`Services/ReviewsStore.swift`. Its lock is the shared `FileLock` of BifrostFoundation, which the
Daily update store uses too.

Every field is optional, so a file from any release of the Electron app opens unchanged, and the
read is lenient one field at a time:

- A field of the wrong form gets its empty value and the other fields stay. The log names the
  fields it dropped, never a PR key or any other text from the file.
- An outbox is all or nothing. One damaged write drops the whole outbox, because Bifrost must never
  send part of a damaged list of writes.
- A top-level field that Bifrost doesn't know survives a save untouched.
- PR keys keep GitHub's spelling, `Owner/Repo#12`, but a lookup ignores case, so the poll's
  `owner/repo` #12 finds the PR the Electron app stored as `Owner/Repo#12`. If two keys differ only
  in case, the first in sorted order wins, the other goes, and the log names the field. A save
  writes the key in the spelling it kept.
- Times are milliseconds since 1970 in the file and dates inside the app. A number beyond the range
  of a JavaScript date isn't a time.
- A file that doesn't parse gives an empty state, and the first save copies it to
  `state.json.unreadable` first and logs where the copy is, as every store does
  (`docs/behaviour/stores.md`, Loading a file). A file whose top level isn't an object, such as
  `[]` or `null`, counts as one that doesn't parse, so it's kept aside too.
- A file of another version, from a newer Bifrost for example, stops Reviews from starting, and
  nothing writes to the folder: there's no safety copy, no save and no unreadable copy. The line
  says the data comes from a newer Bifrost, or, for a file with no version or one that Bifrost
  doesn't know, that it leaves the data as it is. A newer app that shares the folder loses
  nothing.
- A file that can't be read at all, because of its permissions for example, stops Reviews from
  starting too, with a line that says why, so Bifrost never writes over a state it didn't read.

| List | Kept |
| --- | --- |
| The queue | The oldest 200, one entry for each PR and kind (the oldest wins) |
| Posted comments and draft comments | The newest 2,000 of each |
| Voice pairs | The newest 1,000 |
| Held items of a PR | The newest 200, each once |
| A question, its place and its answer | At most 500, 300 and 2,000 UTF-16 units, or the question goes |
| The quote of a question: author, text and link | At most 60, 600 and 500 UTF-16 units, and the link must be https on github.com, or that part goes |

A change updates the state at once and then saves it. The saves run one at a time off the main
thread (the shared `SaveQueue`), and a change that arrives while a save runs goes out with the
next one, so the file always ends with the newest state. A change hands back a ticket that says
whether the file holds it, so a request round can save its plan of writes before it sends anything
to GitHub, and stop if that save fails; a click that only needs the new state (Pause, Remove, the
consent) doesn't wait. Every change gets a number, and a ticket gets the result of the first write
that carried its change. A failed write, a write that the store had to skip (because it couldn't
keep a copy of an unreadable file first) and an update after the store closed all count as not
saved. A failed save is logged, and the next update tries again, even one that changes nothing.

### One copy at a time

Only one copy of Bifrost runs Reviews at a time, because two would post the same replies twice and
fight over the state. The store takes an exclusive lock (`flock`, with no wait) on
`~/.bifrost/reviews/.lock` when it opens and holds it until it closes, with the lock file kept open
the whole time, so even a crash frees it. The folder gets the mode 0700 and the lock file 0600. A
second copy is refused with "Reviews is running in another copy of Bifrost." and does nothing on
GitHub. Closing the store lets its last saves finish before it gives the lock up, and a store
that's dropped without being closed keeps the lock until its last save ends, so a new open never
reads the file while an old write is still on its way.

### The take-over

The first time Bifrost opens the Reviews state, it copies `state.json` byte for byte to
`state.json.before-native`, with the mode 0600, before it writes anything, so you can always go
back. If there's no state file yet, the copy is empty. Bifrost never writes over the copy. Then it
changes the state and saves straight away:

- It turns automatic request rounds off until you agree again. The consent becomes false and new
  work starts now, so no request round starts on its own, and nothing gets pushed, until you turn
  on "Handle comments on my PRs automatically" in this app and confirm, whatever the Electron app's
  setting said.
- Each outbox goes. An item whose writes all went to GitHub counts as handled, and every other item
  is held. Each request round stops and its items are held too. The PR keeps the reason "Bifrost
  stopped this round before it finished. Choose Try again." for its row, so a round the Electron
  app started never posts or pushes by itself.
- The request entries of the queue go, and so does every Handle now and Handle Copilot comments
  click, including one the Electron app kept after a round failed without a queue entry.
- Each question you'd already answered is held, since the round for your answer was queued or
  running, so it waits for Handle now or Try again like the other held items.
- Everything else stays as it was: review rounds, review entries in the queue, handled items,
  open questions, the clones and the hidden rows.

If Bifrost quits after the copy but before that first save, `state.json` still matches the copy
byte for byte, so the next start runs the take-over again and leaves the copy alone. The store
also tells the app when an open took the state over (`tookOver`).

`ReviewsStateTests`, `ReviewsStoreTests` and `ReviewsLockTests` cover these rules, with a fixture of
each form of the Electron file in `Tests/BifrostReviewsTests/Fixtures/`.

## The watcher

`ReviewsWatcher` polls GitHub while Watch GitHub is on in Settings, and it is the one owner of the
poll. It keeps the last good answer and gives the two tabs their rows.

- A poll runs, then a timer waits one poll interval from the end of the poll. Refresh ends the wait
  and polls at once. A Refresh during a poll starts one more poll when that poll ends, because the
  poll that runs can carry an answer from before your change. Several clicks give one more poll,
  and two polls never overlap. A new interval counts from the start of the wait that runs: a
  shorter interval than the time that has passed polls at once.
- A good poll first writes its marks into the state in one update (see "What each poll records"),
  and only then builds the rows. That order is why the first poll after the first turn-on shows no
  flash and sends no notification. The update runs only when the marks changed the state.
- A poll that fails keeps the last good answer and its rows, and the panel shows the reason (gh
  missing or logged out, a timeout, or an answer that Bifrost can't read). The log gets one line
  for each new reason, not one for each poll.
- Each poll tells the health log: ok, no data (gh missing or logged out) or failed. Turning Watch
  GitHub off, or quitting, ends the timers and the poll, clears the rows, keeps the state, and tells
  the health log that Reviews stopped.
- A pause wakes its row with one timer set for the earliest pause end. No tick runs.
- A poll shows at most three new-request notifications. More new requests give one summary.
- A new direct request shows one notification, only while Notifications is on and the main window
  has no focus. Draft ready, Needs you and a repository that needs trust use the same rules. A
  click opens the Reviews panel.
- When the store can't open (another copy of Bifrost runs Reviews, or `state.json` has another
  version), the watcher doesn't poll, and the panel shows the message of the store.
- The attention dot is on while a row flashes, a draft waits for you, or Claude has a question on
  one of your PRs.

## The rows

The Reviews panel has a row for each PR, in one of its two tabs. The rows come from four things
only: the last poll answer, the Reviews state, the settings and the current time, so the same
inputs always give the same rows and the rules can be tested as plain values. `ReviewRows` in
`BifrostReviews/Model/Rows/` builds both tabs; `ToReviewRules` and `MyPRRules` hold the rules,
`RowText` holds the texts, and `ReviewsConfig` carries the Reviews settings in the types the rules
use.

Each row has two lines. The first has the repository, the PR number and the title, with a `team`
tag after the title for a team request, or a red cross for a PR whose checks failed, whose tip says
how many ("2 checks failed"). The second line has notes on the left and a status on the right, and
every text on a row has a colour and, where it helps, a tip.

Three things keep a PR off the panel altogether:

- **The ignore list.** An entry is `owner/repo` or `owner/*`, and both match in any case. The
  settings keep each entry trimmed and in lower case (`IgnoreEntry`), and `IgnoreRule.refusal`
  gives the reason when the editor can't take one.
- **Show team requests.** With it off, a request that only names one of your teams has no row,
  unless its review session is queued or running.
- **Remove.** On a row that others approved, Remove hides the PR in Bifrost and changes nothing on
  GitHub. It comes back when someone asks for your review again.

| Ignore entry refused | Reason |
| --- | --- |
| Not `owner/repo` or `owner/*`: the owner is 1 to 39 letters, digits or `-` and starts with a letter or digit, and the repository is 1 to 100 letters, digits, `.`, `_` or `-` | "Use owner/repo or owner/*." |
| Already in the list, in any case | "That repository is already in the list." |
| The list has 50 entries | "You can keep up to 50 entries." |

### To review

A To review row is in one of these states, and the tab shows them in this order. Inside a group,
the oldest request comes first, except for paused rows, where the pause that ends first comes
first.

| Order | State | Right side | When |
| --- | --- | --- | --- |
| 1 | New request | The Review and Pause buttons, with no text | A direct request that arrived after the first turn-on and that you haven't acted on |
| 2 | Draft ready | "Draft ready" | You have a pending review on the PR, Claude's or your own |
| 3 | Looks good | "Looks good" | Claude suggested Approve for the head commit and posted nothing |
| 4 | Review failed | "Review failed", with the reason as its tip | The last review round failed |
| 5 | Waiting for you | "Waiting for you" | A direct request that was open at the first turn-on, or that you acted on (a Review click or a round) since Bifrost first saw it |
| 6 | Trust needed | "Trust needed" | The review waits in the queue for you to trust the clone of its repository |
| 7 | Reviewing | "Reviewing" | A review round runs |
| 8 | Queued | "Queued" | The review waits for a free session |
| 9 | Paused | "Paused 42m", the minutes left and at least 1 | You paused the request |
| 10 | You approved | "You approved" | Your latest opinion approves the head commit |
| 11 | Approved by others | "Approved by others" | GitHub's review decision is approved, so your approval changes nothing |
| 12 | Team request | "Team request" | The request only names a team of yours |

The state comes from the first rule that holds: a running or queued round (a queued round whose
repository needs trust is Trust needed; see "Clones and trust"), the team filter, a
pending review, your approval, a failed round, Claude's Approve with nothing posted, a pause,
others' approval, a team request, and last a new request or one that waits for you. So an approved
PR never flashes, and a pause hides the flash of a new request until it ends. Your approval of the
head counts only once the request isn't new: someone who asks again on the same commit gets a new,
flashing row. Only a new request flashes; the panel also stops the flash when the Row flash setting
is off.

When Claude has a result for the row, the result replaces the text of the state, the line of the
author, size and age gives way to what Claude did, and a dot of the same colour sits before the
repository. The row only shows a mark of Claude that belongs to your pending review, or, for a mark
with no draft, while you have no pending review, so an old mark never shows next to a newer draft.

| Result | Right side | Colour | Second line |
| --- | --- | --- | --- |
| Claude suggests Approve | "Approval recommended" | Soft green | What Claude drafted, such as "Claude drafted a summary and 2 comments." or "Claude found nothing to change." |
| Claude drafted a comment | "Draft ready" | Amber | What Claude drafted |
| Claude drafted a request for changes | "Changes required" | Red | What Claude drafted |
| You deleted Claude's draft to approve | "Draft deleted" | Grey | "You deleted Claude's draft. Approve when you're ready." |
| Others approved | "Approved by others" | Grey | "2 people approved it, so you don't need to review it." ("Others approved it" when the count is 0) |

What Claude drafted comes from the draft comments Bifrost saved for the review: a comment with no
path is the summary. When Bifrost kept none, the line is "Claude drafted a review."

Failing or running CI replaces the right side of a row that waits for you (a new request, Waiting
for you, a team request, a failed review, Looks good, Draft ready and Paused), while the second line
keeps Claude's result. The other states keep their own text.

| CI | Right side | Colour | Tip |
| --- | --- | --- | --- |
| Failing | "CI failing" | Red | "CI is failing on this pull request, so Bifrost won't review or approve it. It can be reviewed again when CI passes." |
| Running | "CI running" | Grey | "CI is still running. Claude can review now, but you can approve only when it has passed." |

A failed review keeps its reason as the tip, also under CI. The other tips:

| Row | Tip |
| --- | --- |
| Draft ready with Claude's mark | "Claude suggests: Comment. *Why.* Click Comment to check the draft and send it.", with Request changes in the same form, and "Click Approve to submit Claude's draft as an approval." for Approve |
| Looks good | "Claude suggests: Approve. *Why.* Nothing was posted." |
| Draft deleted | "You deleted Claude's draft. Click Approve to approve this pull request." |
| Trust needed | "Bifrost needs you to trust this repository first. Click Trust at the top of the panel." |
| Queued | "Waiting for a free review slot." |
| Reviewing | "Claude is reviewing this pull request." |
| You approved | "You approved this pull request on GitHub." |

The second line of a row with no result has the author, the size (`+12 −3`, with a real minus
sign) and the age of the request: "just now" under a minute, then "5m ago", "3h ago" and "2d ago".

#### What each poll records

After each good poll, `ReviewsState.recordPoll` updates the marks that the flash depends on, and
gives back the requests that arrived with that poll (`ReviewRows.isNewRequest` says the same for one
PR):

- The first poll after the first turn-on records the turn-on: its time, every open request as one
  that doesn't flash, the open items of your PRs, which then wait for Handle now, and the start of
  new request work (`fixFrom`) when the state has none. No request
  arrives with that poll.
- A request that arrived after the turn-on is new. One from before the turn-on that only shows up
  later, because GitHub gives the first 50, isn't.
- A direct request made again after Bifrost first saw it is new again: it flashes, loses its pause,
  and Claude's mark and the last round's error go. A team request made again keeps its pause.
- A request that's no longer in the answer loses its entry, its pause and its Remove, so it's new
  when it comes back. When the answer was cut or had errors, a missing request may still be open,
  so it keeps all three.
- A removed PR shows again once its request time is after the time of the Remove. The Remove keeps
  the later of now and the request time, so a clock that runs behind GitHub's can't bring the same
  request back.
- A pause that has ended goes.

The time Bifrost first saw a request is never before the request time itself, for the same reason:
a slow clock can't make a request new at every poll.

### My PRs

A My PRs row shows the review status with a coloured dot, the reviewers, the later Copilot comments
and the older comments on the left, and what Claude is doing on the right.

The rules start from the open items of the PR (`OpenItems`). Only a trusted author who isn't a bot
gives an item: an unresolved thread, the body of a review that requests changes or comments, or a
top-level comment. Copilot only counts through its threads: the threads of its first review are
treated like a person's, and those of a later review wait for Handle Copilot comments. Each item
sits in one list:

| List | Holds |
| --- | --- |
| Work | New items, for the next request round |
| Older | Items open at the first turn-on or from before the start of new work (`fixFrom`), and the items held by a failed round; Handle now makes them work |
| Later Copilot | Threads of a later Copilot review |
| Questions | Items with an open question of Claude |
| Posting | Items that a write of the unsent outbox names |

A handled item stays out of every list until a trusted person comments after Bifrost's last reply.
An open question waits until you answer it or a trusted person comments after it, and a held item
becomes work after Handle now or a trusted comment after the read of the failed round.

The review status comes from the first rule that holds:

| Status | Colour | When |
| --- | --- | --- |
| Changes requested | Red | The latest decision of a human reviewer requests changes |
| Comments | Blue | A thread is open in the work, the older items, the questions or the outbox |
| Approved | Soft green | A human reviewer approved, and no thread is open |
| Pending | Grey | Anything else, also with no reviewer |

Only threads give Comments. A review body or a top-level comment is still work for a round, but it
doesn't change the status, so a "Thanks" never hides an approval. Copilot is never a reviewer here:
its threads can make a PR show Comments, but it can never make one Approved. When GitHub cut a list
of the PR, the status has the tip "Bifrost read only the newest items of this PR."

The reviewers are the requested users, then the authors of the reviews, each once and never you,
with Copilot named "Copilot". Each name has the colour of the reviewer's latest opinion, and a later
comment doesn't change it:

| Reviewer | Colour |
| --- | --- |
| Approved | Soft green |
| Only commented | Amber |
| Requested changes | Red |
| Requested with no review, dismissed, or Copilot | Grey |

| Claude state | Right side | Colour | Tip |
| --- | --- | --- | --- |
| Needs you | "Needs you" | Red | "Claude needs your answer on 2 comments. Click to answer." |
| Fixing | "Fixing 3", the items of the round | Plain | "Claude is working on 3 comments." |
| Queued | "Queued" | Grey | "Waiting for a free session slot." |
| Trust needed | "Trust needed" | Grey | "Bifrost needs you to trust this repository first. Click Trust at the top of the panel." |
| Cloning | "Cloning" | Grey | "Bifrost is copying this repository." |
| Waiting | "Waiting" | Grey | None |
| Error | "Error" | Red | The reason the last round failed |
| Fork | "Fork" | Grey | "This pull request comes from a fork. Bifrost can't push there, so Claude leaves its comments to you." |

From the state, the Claude state is the first that holds of: a round runs (Fixing), a request round
waits in the queue (Queued), Claude has open questions (Needs you), the last round failed (Error),
and the PR comes from a fork (Fork); otherwise it's Waiting. A request round in the queue shows
Cloning while the clone of its repository runs, and Trust needed while that clone waits for your
trust (see "Clones and trust").

The notes are "Copilot: 3 more" for the threads of later Copilot reviews and "2 older comments" for
the items that wait for Handle now. While "Handle comments on my PRs automatically" is off, or you
haven't yet turned it on and confirmed it in this app, the new work waits too, so it counts as
older.

A row where Claude needs you comes first. The others follow by status, in the order Changes
requested, Comments, Pending and Approved, and inside a group the most recently updated PR comes
first.

`ToReviewRulesTests`, `MyPRRulesTests`, `RowTextTests`, `IgnoreRuleTests` and `ReviewRowTests`
cover these rules, each with a fixed time.

## Clones and trust

Bifrost keeps its own clone of every repository it works on, and never touches one of your
checkouts. Everything lives under `~/.bifrost/reviews/repos`, with owner and repository names in
lower case:

| Folder | What it is |
| --- | --- |
| `repos/<owner>/<repo>` | The clone: a partial clone with no checkout and no file contents (`--no-checkout --filter=blob:none`), so it's quick to make and holds none of the repository's settings, hooks or `CLAUDE.md` |
| `<clone>/.bifrost-worktrees/<number>` | The worktree of one PR, detached at the head that the round looks at, with mode 0700. It's the folder the PR session works in |
| `<clone>/.bifrost-io/<number>` | The input folder of one PR, emptied for each round, with mode 0700 |

A clone first goes to a temporary folder of its own, `<clone>~cloning-<random>`, and only moves
into place once git has finished, so a stop half way never leaves something that looks like a
clone, and two gits never write into one folder. A clone also removes any temporary folder of its
repository that an earlier run left. Only one clone runs at a time. Turning Watch GitHub off, or
quitting, stops a clone that's running: git gets a terminate signal (and a kill one second later
if it's still there), and its temporary folder goes. That fits inside the two seconds a quit waits,
and the Reviews state is saved and its lock freed at the same time, so no git outlives Bifrost. A
stopped clone doesn't count as a failure. A clone that fails writes one line to the log and the
repository is left alone for an hour; the next poll after that tries again, and a click on Review
tries straight away. After a round, Bifrost counts
the changes the session made in its worktree, logs the count, resets the worktree to its head,
removes everything git doesn't track (ignored files included) and writes the worktree's `.git`
file back, since a session can change it. When a review request goes, its worktree and input
folder go too. The clones themselves stay until you use Remove all clones in Settings. Every
removal first checks that the path really is below the repos folder, also after resolving the
links above it, and a link inside it is removed as a link, never followed.

Claude Code won't start a background session in a folder you haven't trusted, and it keeps that
trust per folder in `~/.claude.json`. Bifrost never accepts the trust prompt for you and never
writes that file; it only reads it, with the same 20 MB cap as the usage notification. So the
first time a repository shows up, you trust its clone once:

1. **The set-up at the first turn-on.** Bifrost clones each repository of your open PRs and
   review requests that isn't ignored, one at a time, then lists the ones that need trust, so you
   can do all the trust steps in one go. The set-up sends no notification. A user who turned
   Watch GitHub on before the review rounds gets the same set-up once, at the first good poll.
2. **The Trust needed strip.** The top of the Reviews panel lists each repository that needs
   trust, with the number of its pull requests that wait ("2 pull requests waiting") and a Trust
   button.
3. **The trust panel.** Trust opens a Bifrost panel with a chat terminal that runs `claude` in the
   clone, so the real trust prompt appears there and you answer it yourself. Bifrost never types
   into that terminal. Closing the panel stops its `claude`.
4. **The end.** Bifrost reads the trust again when the terminal's output has settled (half a
   second after the last output), when its `claude` ends, and whenever `~/.claude.json` changes
   while the panel is open, never on a timer. As soon as the clone is trusted, the terminal and
   the panel close, `claude` stops, and the work that waited can start. Closing the panel yourself
   stops its `claude` and reads the trust one last time, and turning Watch GitHub off closes the
   panel and its `claude` too.

The watch of `~/.claude.json` follows the file itself: Claude Code saves it by renaming a new file
over the old one, so after a rename the watch moves to the new file, and right after each start of
its watch Bifrost checks once that it's watching the file that's really there. While there's no
file yet, only the arrival of that file counts, not other changes in your home folder.

After the set-up, a repository that shows up later gets its clone at the first poll that lists it,
and one notification if it needs trust. The state remembers that notification, so it never comes
twice. A repository that needs trust, or whose clone failed, never holds up the others: their
clones and trust reads carry on. Each poll reads `~/.claude.json` once for all the repositories,
and a repository that it now finds trusted (say you trusted the clone some other way) leaves the
list and starts its waiting work, just as the trust panel would.

The parts are `RepoStore` (the folders and the git commands), `TrustCheck` (the read of
`~/.claude.json` and its change events), `RepoSetup` (the set-up, the list that needs trust and
the notifications) in `BifrostReviews/Services`, and the trust run of the PTY manager
(`TrustRuns.check` and `PTYManager.openTrust`, see `docs/behaviour/pty.md`). The terminal is
`TrustTerminal` in `BifrostChat/UI/Trust`, which knows nothing about Reviews, and the strip and
the panel are `TrustStrip` and `TrustPanels` in `BifrostWindows/UI/Reviews`. `RepoStoreTests`,
`TrustCheckTests`, `RepoSetupTests`, `TrustRunsTests`, `PTYManagerTrustTests` and
`TrustTerminalTests` cover them, with real git on local repositories and the fake `claude`.

## PR sessions

A PR session is the Claude Code background session that does the work of one round. It's an
ordinary Bifrost session, so it shows in the Overview and you can open its chat, but Bifrost
starts it with flags that limit what Claude can do, and Claude Code itself enforces them. A review
session can only read, search and write its result file: no shell, no web tools, no MCP servers,
and none of the PR's own settings, hooks or `CLAUDE.md`. That way it can't run the PR's code, call
`gh` or `git`, or send anything out, whatever the PR asks it to do. The exact flags are:

```
claude --bg --restricted --strict-mcp-config --tools Read Glob Grep Write Skill
       --permission-mode auto --add-dir <input folder> --plugin-dir <skills>
       --settings <no statusline, no hooks> [--model <model>] --name <name>
       "/bifrost-review bifrost-input=<input.json>"
```

The session runs in the PR's worktree, and the model comes from "Model for review sessions" in
Settings. Its name is `<repo>-<number>-review`, or `<owner>-<repo>-<number>-review` when that
name is already taken, say by a PR of another repository with the same name; in a test home every
name starts with `bifrost-test-`. Bifrost tells the registry to expect the name before the start
and marks the row once it shows, so a PR session never gets the yellow box or Resume all.

At most "Maximum PR sessions" rounds (three by default) run at once, and the oldest queued round
starts first. A round whose repository is waiting for your trust step keeps its place without
holding up the others. A slot belongs to a round, not to a session: once a round ends, its slot is
free even though the session stays around.

Each round starts a fresh session, and the previous session of that PR is deleted first, since the
input file carries everything the new one needs to know. A session stays after its round so you
can read its chat, and Bifrost stops it after 10 minutes idle with nothing open on it. It goes
for good when the review request goes.

### When a turn ends

Claude Code doesn't announce the end of a turn, so Bifrost works it out from what it can actually
see: the session's row and the result file. A result only counts once it's there and passes the
same strict check that Bifrost applies afterwards, so a half-written or broken file is no signal.
Bifrost checks again every time the session row changes, every time the result file changes (a
file system event, not a poll of the folder), and at the next moment the rule could give a
different answer, using a single timer rather than a tick. A file that hasn't changed since the
last check isn't read again. The first rule that holds decides:

| What Bifrost sees | Outcome |
| --- | --- |
| The row shows a prompt (a red box) | The round ends straight away as blocked, because a round's session must never ask |
| More than 30 minutes since the session started | A good result wins at an idle row (or once a missing row has been gone for 60 seconds); otherwise the round times out |
| No row for 60 seconds | The session went |
| The row is working | Keep waiting |
| The row is idle and a good result is there | The turn ended, straight away |
| Idle for 10 seconds after it worked, with no good result | The turn ended with no result |
| Idle for 120 seconds having never worked | The turn ended (the session never got going) |

The 10 seconds only applies when there's no good result: Claude Code has no end-of-turn signal,
the registry samples the rows every two seconds, and an idle sample can sit between two tool
calls, so Bifrost gives a session that worked a moment before it decides the turn ended with
nothing. The 30-minute limit and the 120 seconds are only fail-safes.

The wait hands the round the result that passed the check when the turn ended, and both kinds of
round work from those exact bytes. Neither reads `result.json` again, so a session that rewrites
the file after the end (a leftover background command, say) changes nothing. The file is read
again only to explain a failure when no good result was there.

`PRSessions` (`BifrostReviews/Services`) starts the sessions, waits for the turn ends and handles
the idle stop, with `RoundEnd` holding the rule and `PRSessionArgs` and `SessionNames` the flags
and the names. `ReviewQueue` runs the rounds in their slots. `PRSessionsTests`,
`RoundEndTests` and `ReviewQueueTests` cover them, on scripted session rows and a manual clock.

## Review rounds

A review round is Claude reviewing someone else's PR and leaving a pending review that only you can
see. It starts only when you click Review on a To review row (or Try again on one that failed),
never by itself, and a PR whose CI is failing gets no review at all. The row says "Queued" while
it waits for a slot, "Trust needed" while its repository waits for your trust step, and
"Reviewing" while it runs.

A round goes like this:

1. **The clone and the trust.** Bifrost makes the clone if it's missing (a click retries a failed
   clone straight away) and reads the trust of the clone again. If the read says Claude Code
   doesn't trust it, the round goes back to the queue and the repository shows in the Trust
   needed strip. A click on Review for such a repository, and the end of a trust step (the
   trust panel closing, even if the read still says no), gives it one start anyway, and `claude`
   itself decides: a background start in an untrusted folder simply fails, so Bifrost never
   answers a trust prompt. If `claude` refuses, the round waits again and nothing retries it
   until the next trust step; if it starts, the clone counts as trusted from then on. That way a
   trust the read can't see (say Claude Code keeps it somewhere else) never leaves a repository
   stuck at Trust needed.
2. **The PR.** Bifrost reads the PR from GitHub and fetches its head and its base branch into the
   clone. A PR that has closed fails the round, and so does one whose head moved between the read
   and the fetch. If Claude's own draft review for this commit is still pending on GitHub, the
   round fails too, because a second round would add every comment again.
3. **The input folder.** The previous session of the PR is deleted first, so it can never write
   into the new round's folders. Then the worktree goes to the head, and the input folder gets
   `input.json`, `full.diff` (from the merge base to the head), `since.diff` for a re-review,
   `mode.md` (a copy of the review skill's Bifrost mode) and `humanise-rules.md`. `input.json`
   carries a fresh token for the round, which the result file has to give back, so a result
   written by any other session (an earlier one, one a stop left behind, or another PR's) never
   counts. A diff over 3 MiB means no review.
4. **The session.** The review session starts and Bifrost waits for its turn to end (see "When a
   turn ends"). Then it counts what the session changed in its worktree, logs the count, and
   resets the worktree.
5. **The result.** Bifrost checks `result.json` strictly, then writes the pending review.

The input file tells the session what kind of review to do, based on your last submitted review
of the PR (a pending review, or a review made only of replies, doesn't count):

| Your last review | What the session reviews |
| --- | --- |
| None | The full diff |
| On the current head | The full diff, noted as unchanged |
| On an ancestor of the head | The changes since that commit, plus a check of your earlier threads and summaries |
| On a commit that's gone (a rewritten history) or that Bifrost can't find | The full diff, plus the same check of your earlier points |

The result check is strict: if one rule fails, Bifrost refuses the whole file and posts nothing,
and the reason it gives names only the field or the limit, never text from the file. The limits
are those of the Electron app: the file is at most 1 MiB, with at most 50 comments of up to 10,000
characters each, a summary of up to 20,000 characters, and a reason of up to 300 characters on one
line with no control or text-direction characters. The file must give back the round's token, a
comment must be on a file of the diff that isn't binary, and an Approve has no line comments.

Then the pending review. GitHub refuses a whole review if a single comment is on a line the diff
doesn't show, so such a comment moves into the summary with its path and line instead. If you
already have a pending review of your own on that commit, Claude's comments go into it as new
threads and its summary goes below yours after a blank line; if your pending review is on another
commit, the round fails and nothing is posted. Just before each write to your pending review,
Bifrost reads it again and only goes ahead if it's still pending and still yours, because GitHub
would otherwise happily edit a review you've already submitted. An Approve with nothing to say
posts nothing at all, and the row shows "Looks good".

Bifrost saves the round as posting before its first write. If GitHub may have made a write it
didn't confirm (a timeout, an answer it couldn't read), the round fails with a reason that sends
you to GitHub and never tries again by itself; the same happens at the next start for a round that
was posting when Bifrost quit, Electron rounds included. A round that was getting ready goes back
to the queue at the next start, and one whose session was still running carries on waiting for it.

A good round records the recommendation, the reviewed commit and the text of each draft comment,
sends one notification ("Your review draft is ready", or "Claude suggests you approve" when nothing
was posted) and polls at once, so the row shows the draft without waiting for the next poll. A
failed round shows "Review failed" with the reason in its tip and a Try again button, and sends no
notification. Stop session on a running round ends it with nothing posted, and the session stays
so you can read it. When the review request goes, its round stops, and its session, worktree,
input folder and queue entry go with it; a round that's in the middle of posting finishes its
writes first. Remove all clones stops the rounds, deletes the review sessions and drops the queued
reviews before it removes the clones.

`ReviewRounds` in `BifrostReviews/Services/ReviewRound.swift` runs the rounds, with
`ReviewQueries` for the reads, and `Baseline`, `ReviewInput`, `ReviewResult`, `DiffLines`,
`PendingReviewPlan` and `RoundFailure` in `BifrostReviews/Model/Review` for the rules and the
texts. `ReviewRoundTests` covers whole rounds with real git on a local repository, the fake GitHub
and scripted session rows, and each model file has its own suite.

## Request rounds

A request round is Claude working through the review comments on one of your own PRs: it fixes the
code, writes replies in your voice, or asks you a question when only you can decide. Claude never
touches GitHub itself. It works in a sandboxed session, writes what it did to a result file, and
Bifrost checks that file strictly before it commits, pushes or posts anything (see "The push and
the writes").

### What counts as work

A round starts from the open items of the PR (see "My PRs") and takes the ones that are work:

- an unresolved thread or a top-level comment from a trusted person (an owner, member or
  collaborator of the repository who isn't a bot and isn't you), and the body of their review when
  it requests changes or comments;
- the threads of the first Copilot review. Threads of later Copilot reviews wait for Handle Copilot
  comments, and the Copilot summary is never work;
- never anything from another bot or from an outsider, which still shows on GitHub as usual.

An item Bifrost has already handled only becomes work again when a trusted person comments after
Bifrost's last reply. Items from before the start of new work (`fixFrom`: the first turn-on, the
take-over of the Electron state, or the moment you confirmed "Handle comments on my PRs
automatically") wait for Handle now. When a round fails it holds its items, and nothing starts on
them again until you choose Try again or Handle now, or a trusted person adds a comment, so a
failure can't burn through tokens round after round. That comment has to come after the start of
new work too: a newer comment from before it, on an item that's held, handled or waiting for your
answer, puts the item with the ones waiting for Handle now. That way an item the take-over held,
or one the Electron app already handled, never starts a round on its own because of an old
comment once you confirm the automatic rounds. A round takes at most 30 items, oldest first,
and a PR from a fork never gets one, since Bifrost can only push to the repository of its clone.

### When a round starts

| What starts it | Which items it takes |
| --- | --- |
| A poll that shows new work, while "Handle comments on my PRs automatically" is on and you confirmed it in this app | All the work. A PR whose thread list GitHub cut also gets a round when it changed since the last full read, since the full read may find work the poll can't see |
| Handle now | All the work, the older and the held items too |
| Handle Copilot comments | The threads of later Copilot reviews |
| Try again, after a failed round | All the work, the older and the held items too, just like Handle now |
| An answer in the Answer panel | The questions you answered |

With the automatic rounds off, or before you've confirmed them in this app (right after the
take-over of the Electron state, for instance), no round starts by itself, and a click or an
answer starts a round on just its own items, so an answer never sweeps in other new comments. The
clicks are saved with the queue, so they survive a restart, and they're spent once the round's
session starts, the round fails, or Remove all clones stops it. A click only ever counts for its
own round: a saved click on its own never makes an automatic round start or take more items.

### A round step by step

1. **The clone and the trust**, exactly as for a review round.
2. **The full read.** The poll only reads the newest items of a PR, so the round reads every thread,
   comment and review, page by page: at most 10 pages per list and 200 calls for the whole read,
   with the main lists first so that a few very long threads can't crowd them out. A merged or
   closed PR ends the round quietly (the next poll tidies it up), and a PR that isn't yours or
   comes from a fork fails it. If GitHub has more than Bifrost can read and there's work, the round
   fails with "This pull request has too many comments for Bifrost to check, so nothing was posted.
   Reply to them on GitHub." and holds the items, because the unread part could hide a reply that
   Bifrost already sent. Otherwise the round chooses its items; with none, it just ends.
3. **The input folder.** Bifrost fetches the head, deletes the PR's previous request session, puts
   the worktree at the head and writes `input.json`, `full.diff` (left out when it's over 3 MiB,
   in which case the session reads the files), `mode.md` (a copy of the resolve-comments skill's
   Bifrost mode) and `humanise-rules.md`. `input.json` holds the PR, a fresh token for the round
   that the result has to give back, and each item with its comments, each one marked as trusted
   or not and as yours or not with the same rule Bifrost uses for work, plus any earlier question
   about it and your answer.
4. **The session**, which runs in the PR's worktree with the "Model for request sessions" setting:

   ```
   claude --bg --restricted --strict-mcp-config
          --tools Bash Read Glob Grep Edit Write Skill --permission-mode auto
          --add-dir <input folder> --plugin-dir <skills> --settings <the sandbox>
          [--model <model>] --name <name>
          "/bifrost-resolve-comments bifrost-input=<input.json>"
   ```

   Its name is `<repo>-<number>-request`. `--restricted` keeps Read, Grep, Glob, Edit and Write in
   the worktree and the input folder, and it loads no settings file at all, neither yours nor one
   in the PR head, so the rules below are the whole story and nothing in `~/.claude/settings.json`
   can weaken them. It also makes Claude Code ask a person before it writes a settings, git or tool
   configuration file. A round never answers, so that prompt ends the round at once (the row shows
   it, no timer involved) with "Claude stopped to ask for approval, for example to change a
   settings, git or tool file, and a round can't give it", and nothing is posted; make that change
   yourself, or try again. The turn ends as described in "When a turn ends", with a 30-minute
   limit, and Stop session, the time limit and a session that stops to ask all end the round with
   nothing posted.
5. **The result.** Bifrost checks `result.json` against what changed in the worktree and makes sure
   each earlier commit that a Fixed item names really belongs to the PR, then reads the PR again; a
   PR that merged or closed in the meantime gets nothing more.
6. **The outcome**, saved in one go (see below).
7. **The writes**: Bifrost commits the fix, pushes it and posts the replies (see "The push and the
   writes").

Unlike a review session, a request session has a shell, so the `--settings` value carries the
rules that keep it in check (`RequestSandbox`). They name real paths, since that's what Claude Code
compares:

| Rule | Why |
| --- | --- |
| No statusline and no hooks | A PR head can carry a `.claude` folder with hooks |
| The sandbox on, with `allowUnsandboxedCommands` off | Bash runs inside Claude Code's sandbox with no way out |
| A strict network allow list of package registries only (npm, Yarn, PyPI, crates.io, RubyGems, Maven, Gradle and NuGet) | No GitHub host, so nothing can be pushed or posted from the session |
| No writes to the clone's `.git` folder, by Bash, Edit or Write | The worktree's git data lives there, and Bifrost runs git on it |
| `blockWritesOutsideWorkingDirectories` | Edit and Write stay in the worktree and the input folder |
| Bash reads only its own folders | The sandbox refuses reads of the Reviews folder (the state, with every round's token, and every clone), the input folders and worktrees of the clone's other PRs, `~/.bifrost`, and the secret paths of your home: `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gh`, `~/.netrc`, `~/.git-credentials`, `~/.docker`, `~/.npmrc`, `~/.gem/credentials`, `~/.kube` and `~/Library/Keychains`. It still reads its own worktree, its own input folder and the clone's `.git` folder, which git needs. `SecretPath` is the one list of the secret paths |
| A deny list | `git push`, `git commit`, `gh`, WebFetch, WebSearch, and any read of those secret paths by the file tools |

### The result and the outcome

The result check is as strict as a review's: if one rule fails, Bifrost refuses the whole file,
posts nothing, and names only the field or the limit in the reason. Every item of the round gets
exactly one result with only the field its outcome needs. A reply has up to 4,000 characters and a
question up to 500, neither blank nor holding control or text-direction characters (line breaks and
tabs are fine). The commit message has up to 4,000 characters, a first line of 1 to 100, and no
control characters at all, and it may not ask GitHub to skip CI (`[skip ci]`, `[ci skip]`,
`[no ci]`, `[skip actions]`, `[actions skip]` or `skip-checks: true`, in any case): the session
can't install packages, so CI has to run on the fix. The commit lists 1 to 200 paths, each a clean
relative path outside any `.git` folder that really changed in the worktree, and each only once. A
Fixed item needs the commit unless it names the earlier commit of the PR that already did the fix,
a commit needs at least one Fixed item, and failed checks can't come with a commit, while checks
that were only blocked by the sandbox can.

| Outcome | What Claude did | What Bifrost does |
| --- | --- | --- |
| Fixed | Changed the code, or named the earlier commit that did | Commits the listed files, pushes, replies "Fixed by" the commit and resolves the thread |
| No fix | Wrote a reply in your voice | Posts the reply and resolves the thread |
| No action | Nothing (an approval, a thanks, a note to someone else) | Records the item as handled |
| Needs you | Wrote one short question | Saves the question for the Answer panel and posts nothing |

The outcome is saved in one go: each question with the place of its item (the file and line, or
"Comment from" the author) and a quote of the request, each No action item as handled, and the end
of any earlier question about an item that now has a new outcome. A round that adds questions sends
one notification, "Claude needs your answer on 2 comments", and its row shows Needs you with the
red box. With nothing to commit, the worktree is reset straight away; otherwise the fix stays there
for the commit.

A failed round holds its items, spends its click, shows Error with the reason in its tip and Try
again in the menu, and sends no notification. When a PR merges or closes (a complete poll no longer
lists it), its round stops with nothing more posted, and its request session, worktree, input
folder and queue entry go, along with its clicks, held items, questions and outbox; the items
Bifrost already handled stay. At the next start, a round that was getting ready goes back to the
queue, one whose session was running waits for it again, and one that was posting sends the rest of
its writes. Remove all clones stops the request rounds as well, and they hold their items, though a
round that's posting finishes its writes first.

`ReviewRounds` owns the queue for both kinds of round, and its extension in `RequestRounds.swift`
holds the request side (the clicks, the jobs and how they end). `RequestRound`
(`BifrostReviews/Services`) holds the steps of one request round and `RequestQueries` the full
read, and `WorkRule`, `RequestInput`, `RequestResult` and `RequestSandbox`
(`BifrostReviews/Model/Request`) hold the rules. `RequestRoundTests` runs whole rounds with real git
on a local repository, the fake GitHub and scripted session rows, and each model file has its own
suite.

### The push and the writes

Once the outcome is saved, Bifrost does all the writing itself, in a fixed order that it keeps in
the round's outbox: the fix commit, the push, then for each item in turn its reply and resolve (a
thread) or its PR comment (a top-level comment or a review body), and last the new review
requests. The outbox lives in the state file, and every write is saved as sending before it goes
and as done once it has, so a quit, a crash or an answer Bifrost can't read never makes anything
go to GitHub twice. If that save fails, the write doesn't go.

**The commit.** Bifrost commits only the files that the result lists, after the file rules above,
as one commit on the head of the round with Claude's message and your own git identity, and never
signs it. A file that Claude changed but didn't list stays out of the commit and is cleaned away
afterwards. A listed file that breaks a rule stops the round before anything reaches GitHub, and the
row names the rule.

Claude's session stays open after its turn, so something in it could still change the worktree
between those checks and `git add`, for example by turning a listed file into a link. That's why
Bifrost also checks the commit itself once git has made it: the commit may change only the listed
paths, and each of them has to be a plain or an executable file, never a link or a submodule. A
commit that fails this check is set aside, the worktree goes back to the head of the round, and
nothing reaches GitHub. A commit that a resume finds again after a quit gets the same check.

**The push.** Before any network call, Bifrost checks the target with local git alone: the branch
isn't the base branch or the repository's default branch (in any case), `origin` has exactly one
URL, the address Bifrost cloned from, and no push URL, no `insteadOf` or `pushInsteadOf` rule
changes where a fetch or a push goes, and the fix's only parent is the head of the round. A PR from
a fork never gets a push. Then Bifrost fetches the branch and acts on what it finds:

| The branch on GitHub | What Bifrost does |
| --- | --- |
| Already has the fix, from an earlier push that a quit cut off | Nothing |
| Is still at the head of the round | Pushes the fix as a fast-forward |
| Has new commits on top of the head, yours for example | Merges the fix and the branch with `merge-tree` and `commit-tree` (no worktree, no hooks, no signature) and pushes the merge, as long as the merge only changes files a fix commit may hold. `merge-tree` follows renames, so a fix to a file that someone moved under `.github/workflows` would land there; such a merge counts as a conflict |
| Has new commits that conflict with the fix | Pushes nothing. The other replies still go, the fixed items wait in held, and the row asks you to choose Try again |
| No longer holds the head of the round, because you rewrote it | Pushes nothing, as for a conflict |
| Is gone | Pushes nothing, and no reply says the item is fixed |

If GitHub refuses the push because the branch moved between the fetch and the push, Bifrost
fetches again and tries once more; a second refusal counts as a branch that kept moving. After each
push, another fetch shows whether it really landed, and a push that made the branch again (because
GitHub deleted it in between) fails the round with no "Fixed by" reply. If GitHub turns the branch
down outright (`[remote rejected]`, which is what a protected branch or a server hook gives), every
later try would get the same answer, so the round fails with GitHub's reason in the Event log.

**Signed commits.** With "Sign commits through GitHub" on when the round planned its writes, the
fix goes to GitHub through `createCommitOnBranch`, and GitHub makes and signs the commit, so you
don't need a signing key. Bifrost still makes its local commit first and sends exactly that
change, so the same file rules apply, every changed file has to stay a plain file (GitHub can't
keep a link or an executable bit) and the files can add up to 4 MiB at most. Each file's bytes come
from the commit as git stores it, not from the worktree, so a `.gitattributes` rule for line ends,
`ident` or an encoding, or a later change in the worktree, can't make the files differ from the
commit. The write expects the head of the round, so GitHub refuses it if the branch moved, and
Bifrost doesn't send it at all when its fetch already shows a moved branch; the fixed items then
wait for Try again. Afterwards a fetch finds the commit that GitHub made, a child of the round's
head with exactly the fix's files among the newest 20 commits, and the "Fixed by" replies name that
commit. If GitHub refuses the commit, its reason goes to the Event log with any token hidden, and
the row shows a fixed text.

**The replies.**

- A Fixed thread gets "Fixed by" and the short commit ID, then a resolve. A No fix thread gets
  Claude's reply and a resolve. No action and Needs you items get nothing.
- A top-level comment or a review body gets a new PR comment that quotes the first three lines of
  the request, 300 characters at most, before the reply.
- Every quote and reply gets a zero-width space after each @ that could start a mention, so
  nobody gets a fresh notification. An email address and an @ inside a link are left alone.
- A thread stays open when a trusted person wrote in it after the round read it, so the next round
  can handle the new comment.
- Each write goes to a thread or comment of a fresh read of the PR, with a one-second gap between
  two writes for GitHub's rate limits.
- A merged or closed PR, a PR that isn't yours, a fork, a read that GitHub cut short, or a draft
  review of yours (the replies would land in it) stops the writes. Before every write after the
  first, a small read of the PR's state checks that it's still open, so a PR that merges halfway
  through gets none of the rest.
- Each reply Bifrost posts is kept in the state with its ID and its text.

**New review requests.** After the replies, Bifrost reads the PR again and asks each reviewer whose
latest review requests changes, and whose threads are now all resolved, for a new review
(`requestReviews` with `union: true`, so the other requests stay). It asks each reviewer once per
head commit, never a bot or Copilot, never someone GitHub already lists as requested, and not while
that reviewer still has an open item: a question, a held item, waiting work, or a write of this
round that didn't go.

**When the writes stop.**

| What happened | The outbox | What the row says |
| --- | --- | --- |
| A listed file breaks a rule, git couldn't commit, the push target is refused, GitHub turned the branch down (a protected branch, for example), a signed fix can't go (too large, a link, or GitHub refused it), the branch is gone, or the PR closed, isn't yours, comes from a fork or has more than Bifrost can read | Goes. Items whose writes all went are handled, and the rest wait in held | The reason, and Try again starts a new round |
| GitHub refused a read or a write in a way that would come back on every try (anything but its rate limits, such as a comment "submitted too quickly") | Goes. Items whose writes all went are handled, and the rest wait in held | "GitHub stopped after 2 of 5 updates." with GitHub's reason, and "Bifrost dropped the rest, so choose Try again to start over." |
| A conflict, a rewritten branch or a branch that kept moving | Goes after the other writes. The "Fixed by" writes drop, and their items wait in held | The reason, and Try again starts a new round on the new code |
| A read or a write failed on the network, hit one of GitHub's rate limits or found gh logged out, a draft review of yours is in the way, git couldn't reach GitHub for the push, or Bifrost can't tell whether a write or the push landed | Stays, with the writes that are left | "GitHub stopped after 2 of 5 updates." with the reason, and Try again sends the rest before a new round |

A write that GitHub may have made is never sent again by itself. Only Try again goes on with it,
and it looks on GitHub first. A thread that stays open because someone wrote in it after the round
read it waits in held, however the writes end, so Handle now or the next round picks up the new
comment.

An outbox that stays goes first in every later round of the PR and keeps the automatic rounds away
from it, so you can let it go: Don't send the rest in the row menu drops it without sending
anything (`ReviewRounds.dropOutbox`). Items whose writes all went count as handled, the rest wait
in held, and the reason on the row clears.

**After a quit.** A round that was posting when Bifrost quit sends the rest of its writes at the
next start, and so does Try again after writes that stopped. A quit in the middle of the fix commit
or the push leaves both as they were, so the next start makes the commit or checks the branch and
carries on. While Try again sends the rest of an earlier round's writes, Stop session, a PR that
closes and Remove all clones don't cut them off: as with a posting round, the writes finish first,
and then the round stops before Claude starts. After a Stop session the row says just that: the
earlier updates went, and Claude didn't start. Writes that are done are skipped. A write that was
sending is checked first: a reply or PR comment counts as sent when GitHub has one of yours with
the same text, made no earlier than five minutes before the outbox started (GitHub's clock and your
Mac's can differ), the commit of an earlier run is found in the worktree, the push checks the
branch first, a resolved thread isn't resolved again, and a reviewer whom GitHub lists as requested
isn't asked again. An outbox that the Electron app left is never sent at all: the
take-over holds its items (see "The take-over"). Remove all clones drops an outbox whose commit or
push hadn't gone yet, because that commit lived in a clone that's gone, and its items wait in held.

`RoundWrites` (`BifrostReviews/Services`) runs the writes, `FixCommit`, `Pusher` and `SignedPusher`
do the git and the signed commit, and `OutboxRules`, `PushPlan` and `ReplyText`
(`BifrostReviews/Model/Request`) hold the rules. `FixCommitTests`, `PusherTests` and
`SignedPusherTests` run real git against a local repository that stands in for GitHub, and
`RoundWritesTests` and `RequestRoundTests` use the fake GitHub.

## The panel

The Reviews button sits in the side bar after Service status, and it shows a small dot while
something waits for you: a request that flashes, a draft to check, or a question from Claude on one
of your PRs. It opens the Reviews panel, which has the two tabs, To review and My PRs, each with its
count. The To review count turns red while a row flashes, and the My PRs count while Claude needs
you on one of your PRs. To the right of the tabs, "Last checked 09:07" says when the last good poll
was (with the day too once that's another day), and Refresh polls straight away.

What the panel shows below the tabs depends on where Reviews is:

| State | Panel |
| --- | --- |
| Watch GitHub is off | "Reviews is off. Turn on Watch GitHub in Settings to see your pull requests." and an Open Settings button, with no tabs |
| On, with no answer yet | "Checking GitHub…", with no tabs |
| On, but Bifrost can't find Claude Code | "Reviews needs Claude Code, and Bifrost can't find it. Install it, then open Bifrost again.", with no tabs; Reviews doesn't start in this run |
| The store didn't open | The store's own line, such as "Reviews is running in another copy of Bifrost.", with no tabs; this copy does nothing on GitHub |
| gh is missing or logged out before the first good poll | The friendly gh line in place of the rows |
| Any other failure of the first poll | Only the gh line, at the bottom |
| A good answer | The rows of the open tab, or "Nothing needs you here." |

When a later poll fails, the rows of the last good poll stay where they are and the gh line sits at
the bottom of the panel until a poll works again. While a repository needs trust, the Trust needed
strip sits under the tabs (see "Clones and trust").

Each row has the two lines described in "The rows". A new request flashes: a red layer behind the
row fades from full to a quarter and back once a second, the same rhythm as the Overview's red box,
and turning Row flash off in Settings stops it (the tab count stays red). The box before "Needs you"
on a My PRs row flashes the same way. The buttons on the right depend on the row: Approve in soft
green where Claude suggests approval (see "Approve"), Comment in amber or Request changes in red
where Claude left a draft for you to check (see "The Review panel"), Review on a request that waits
for you (a new request, one you've already seen, a team request, or one Claude found nothing to flag
on and that has no Approve), Try again on a failed review, Pause on a new request, and Remove on a
row that others approved, which hides it in Bifrost and changes nothing on GitHub. A PR with
failing CI gets no Review button.

- A click on a My PRs row where Claude has questions opens the Answer panel (see "The Answer
  panel"). A click on any other row opens the chat of its PR session while that session is working
  or needs you, and otherwise does nothing.
- Cmd+click on a row, or a click on its PR number, opens the PR on GitHub, and only ever its https
  address on github.com.
- A right-click or a Control-click shows the Bifrost menu with only the items that apply to the
  row. On a To review row they come in this order: Open on GitHub; Open session while the PR has a
  session that isn't parked; Approve while the row offers it, CI isn't running and no approval of
  the PR is in progress; Comment or Request changes while the row offers Claude's draft; Review
  (Try again on a failed row) whenever a round can start; Remove on a row that others approved;
  Cancel review while a review waits in the queue or for trust; Stop session; Pause on a new
  request; and End pause now on a paused row. On a My PRs row: Open on
  GitHub; Open session; Answer Claude while Claude has questions; Handle now and Handle Copilot
  comments while their items wait and Claude is waiting, needs you or failed; Try again after a
  failed round; Don't send the rest while the writes of a stopped round wait for Try again; Cancel
  while a round waits in the queue; and Stop session while a round runs. A PR from a fork has Open
  on GitHub only. While the menu is open it follows the row, and it closes if the row goes. Only
  Approve writes to GitHub, and only because you chose it: a review round only ever leaves a
  pending review, Comment and Request changes just open the Review panel, Don't send the rest
  sends nothing, and a request round's result is checked before Bifrost posts anything.
- The rows never take the keyboard focus, and neither does the panel.

The ages on line 2 and "Paused 42m" are worked out when the rows are built, so the panel keeps them
current with a display clock of its own: every 30 seconds while the panel is in a frame, it asks the
watcher to build the rows again at the current time (`ReviewsWatcher.refreshTimes`), which costs
no call to GitHub.

Until you turn on "Handle comments on my PRs automatically" in this app and confirm it, the My PRs
tab shows "Want Claude to fix and answer new review comments for you? Turn on Handle comments on my
PRs automatically in Settings." with an Open Settings button above the rows.

A click on a Reviews notification shows the window and opens the panel. Notifications only show
while the window doesn't have the focus, as with the box alerts, and one that macOS refuses leaves
a line in the Event log.

### Approve

Approve is the one-click way to agree with Claude. It shows on a To review row where Claude
suggests approving the commit you'd be approving: a Looks good row (Claude found nothing to flag
and posted nothing), a Draft ready row whose draft is Claude's Approve draft, or a row where you
deleted Claude's draft with Approve instead in the Review panel. It doesn't show once your latest
opinion on GitHub already approves the head commit, and a PR with failing CI gets none. While CI is
running the button is there but greyed out, with the tip "CI is still running. Approve when it has
passed.", and it stays out of the row menu.

Bifrost only approves when you click: the button (or the menu item) makes the click, and nothing
else in the app can. Before it writes anything, Bifrost reads the PR from GitHub again and checks
that it's still the PR Claude reviewed. The write then goes only to the PR whose address GitHub
gave back, only on the commit Claude reviewed, and only with Claude's own draft, so it either
approves that commit with no text or submits Claude's draft as the approval with its summary as it
is.

The row shows how the approval is going, so a click never looks stuck. As soon as you click, the
button gives way to a spinning loader and "Approving…", so there's nothing to click a second time,
and Approve leaves the row menu. With Reduce Motion on in System Settings, the loader stays still.
Once GitHub confirms the approval, a soft green check and "Approved" take its place for 3 seconds.
Bifrost polls straight away, and GitHub usually drops the review request once you've approved,
which would make the row vanish at once. Bifrost keeps the row in place until the 3 seconds are
up, and then it goes, or moves to You approved if GitHub still lists the request. If the approval
doesn't go through, the Approve button comes back at once and the reason shows in the error line.

When Bifrost doesn't approve, the reason shows in the error line at the bottom of the Reviews
panel:

| Why | Text |
| --- | --- |
| The PR closed or merged | "This pull request is closed or merged, so Bifrost didn't approve it." |
| It's your own PR | "You can't approve your own pull request." |
| Claude's suggestion changed, or a round runs or waits | "Claude doesn't suggest Approve for this pull request any more, so Bifrost didn't approve it." |
| New commits since the review | "This pull request changed after Claude's review, so Bifrost didn't approve it. It needs a new review." |
| CI failing, or still running | "CI is failing on this pull request, so Bifrost didn't approve it." or "CI is still running. Approve when it has passed." |
| You've already approved the head | "You already approved this commit on GitHub." |
| You have a draft review of your own | "You have a draft review on this pull request. Submit or delete it on GitHub first, then try again." |
| Claude's draft is gone, or on another commit | "Bifrost couldn't find Claude's draft review on GitHub, so it didn't approve. The draft may have been submitted or deleted." or "Claude's draft review is on another commit, so Bifrost didn't submit it." |
| GitHub refused it | "GitHub didn't accept the approval. The Event log has the details." |
| GitHub may have saved it | "Bifrost couldn't tell if GitHub saved your approval. Click Refresh to check." |

An approval that GitHub may have saved is never sent again by itself: Bifrost polls, and a second
click reads the PR again first, so it can't approve twice. GitHub's own words for a refusal go to
the Event log with any token hidden.

`ApproveFlow` runs the click and keeps the progress that the row shows (`ApproveProgress`, drawn by
`ApproveProgressLabel`), `ApproveGuard` holds the checks and the write, and `DraftQueries.fresh` is
the read. While an approval has a progress, the watcher keeps its row when a poll drops the PR
(`ReviewRows.holding`). `ApproveFlowTests`, `ApproveGuardTests` and
`ReviewDraftPanelTests.theRowShowsTheProgressOfItsApproval` cover them.

### The Review panel

When Claude leaves a Comment or Request changes draft, the row offers a button with that name. It
opens the Review panel, where you check Claude's draft review, edit it, and then send it, throw it
away or approve instead. The panel reads the draft from GitHub when it opens and starts with no
edits; its title has the PR after it, such as "Review Owner/Repo #7". While it's open for a PR,
clicking that PR's button again just brings the panel forward, so your edits stay, and an action
that's running carries on and shows its result. The click only reads the draft again when there's
nothing to keep: the first read failed, or Claude has left a newer draft since. Closing the panel
drops the edits, and turning Watch GitHub off closes it.

At the top, the panel shows Claude's suggestion and reason ("Claude suggests: Request changes. Two
small bugs."). Below it are the summary and each comment of the draft, with its place ("src/a.swift
line 12", or "lines 10-12" for a range), the last four lines of its diff and its text. A comment
you added to the draft on GitHub yourself says "Added by you". You can edit any text, and remove a
comment (Undo brings it back). Everything from GitHub shows as plain text only.

The footer has Discard draft and Approve instead on the left, and on the right the "Send as"
switch (Comment or Request changes, starting at Claude's suggestion) with Send review. Each button
makes your click; nothing else writes to the draft. What each does:

- **Send review** writes your changes to the draft (the summary, each changed comment, each removed
  comment), then submits it with the event of the switch. Request changes needs a summary, a send
  needs a summary or at least one comment, and an empty comment isn't allowed.
- **Discard draft** deletes Claude's draft review.
- **Approve instead** deletes the draft, then approves the commit with no text, as Approve does. It
  waits for CI, and stops before the delete if you've already approved that commit. If you click
  Approve on the row in the meantime, it waits for that approval and tells you how it went.

Before any write, Bifrost reads the PR and the draft again and stops if anything changed: the PR
closed, the draft isn't Claude's pending review any more, or the draft changed on GitHub after the
panel opened ("The draft changed on GitHub after you opened it, so Bifrost sent nothing. Close this
panel and open it again."). So it never writes over something you did on GitHub, and a delete never
takes a comment the panel didn't show you. If the PR has new commits since the review, the panel
says so and only Discard draft works. Just before each change to the summary or a comment, Bifrost
also checks that the review is still pending and yours, because GitHub's update would edit a
submitted review too.

If the draft holds comments you added on GitHub, Discard draft and Approve instead ask first
("Discard draft also deletes the comment you added to this draft on GitHub.") with Keep draft next
to the button. An action that works closes the panel and polls straight away. One that doesn't shows
its reason in the panel's error line and keeps your edits, so you can try again; a change that
GitHub may have saved is never sent again by itself. When the row no longer offers the draft (a
round started, or the draft is gone), the panel says "You can't change this draft right now. The row
in the Reviews panel shows why." and allows nothing.

`DraftFlow` runs the panel, `DraftEdits` holds the checks, the plan of a send and the guard of each
write, and `ReviewDraftPanels` is the panel. `DraftFlowTests`, `DraftEditsTests` and
`ReviewDraftPanelTests` cover them.

### The Answer panel

When a request round can't decide something on its own, Claude asks you, and the My PRs row shows
Needs you. Answer Claude in the row menu, or a click on the row, opens the Answer panel for that PR.
It opens with "Claude couldn't decide these on its own. Tell it what you'd like, or handle a comment
yourself.", the reason of the last failed round if there was one, and then each open question,
oldest first.

Each question shows the reviewer's comment it's about, with "user-b on src/a.swift line 12" (or "on
the PR") and View on GitHub, or just the place when Bifrost has no quote. Then come the question, a
box for your answer (up to 2,000 characters) and "I'll handle this one myself", which turns the box
off. Send to Claude works once every question has an answer or the check, and sends them all at
once: the answers start one request round, which takes them into its input, and each comment you
handle yourself is marked handled with no round. An answer is a click, so it starts a round even
with "Handle comments on my PRs automatically" off; the round then follows the usual work rules and
never starts another one by itself. Cancel closes the panel and sends nothing. If the questions
changed in the meantime, the panel says "Bifrost couldn't send your answers, because the questions
changed. Check them, then send them again." The panel takes at most 50 answers at a time.

While the panel is open for a PR, clicking that row again just brings it forward, so your answers
stay, and a send that's running carries on and shows its result. Closing the panel drops the
answers, and turning Watch GitHub off closes it.

`AnswerFlow` holds the answers and gives them to `ReviewRounds.answerQuestions`, and
`AnswerPanels` is the panel. `AnswerFlowTests` and `AnswerPanelTests` cover them.

### Where the panel lives

The panel lives in `BifrostWindows/UI/Reviews/` (`ReviewsPanel`, `ReviewRowView`, `ReviewsMenu`,
`TrustStrip`, `TrustPanels`, `ReviewDraftPanel`, `AnswerPanel` and `ReviewsPanels`), and reads the
services only through `ReviewsPanelLinks`. The app joins it to the store, the watcher, the clones
and the flows of Approve, the Review panel and the Answer panel in
`BifrostApp/UI/ShellReviews.swift`. `ReviewsPanelTests` and `ShellReviewsTests` cover it.

## Settings > Reviews

Settings > Reviews has one row for each Reviews setting, with the labels of the Electron app, and
the Settings search finds each row by its label (`ReviewsSettingsRow`):

| Row | Control | Default |
| --- | --- | --- |
| Watch GitHub | Check box; each turn-on asks first | Off |
| Handle comments on my PRs automatically | Check box; each turn-on asks first | On, but see the consent below |
| Sign commits through GitHub | Check box | Off |
| Show team requests | Check box | On |
| Maximum PR sessions | Number from 1 to 10 | 3 |
| Pause time | 15 or 30 minutes, or 1, 2, 4 or 8 hours | 1 hour |
| GitHub poll interval | 1, 2, 5 or 10 minutes | 2 minutes |
| Model for request sessions | Claude Code default, Opus, Sonnet or Haiku | Claude Code default |
| Model for review sessions | The same choices | Claude Code default |
| Repositories to ignore | A field with Add, and the list with a Remove button on each entry | Empty |
| Remove all clones | A Remove button; it asks first | None |

Turning on Watch GitHub or "Handle comments on my PRs automatically" first shows Bifrost's own
confirm dialog, with the texts of the Electron app, and Cancel leaves the box off. Turning either
off needs no confirm.

> **Watch GitHub?** Bifrost will use your gh login to check your review requests and your pull
> requests every few minutes. It makes its own copy of each of their repositories, and asks you to
> trust each copy once. When you click Review, Claude reviews the pull request and Bifrost saves a
> draft review that only you can see. On your own pull requests, Claude fixes or answers new review
> comments, and Bifrost pushes the fixes and posts the replies. Bifrost changes, sends or approves a
> review only when you click a button in the Review panel or Approve, and it never merges.

> **Handle comments automatically?** When someone reviews one of your pull requests, Claude fixes
> or answers each new comment. Bifrost then pushes the fixes to your branch, replies to each comment
> and resolves its thread. It never force-pushes, merges or approves. Comments from before now wait
> until you choose Handle now.

Remove all clones asks first with the text of the Electron app, then deletes Bifrost's copies of
your repositories and leaves the repos folder empty. A failure shows on its row.

> **Remove all clones?** Bifrost will delete its copies of your repositories, the review sessions
> that use them and any queued reviews. Your own checkouts and your draft reviews on GitHub stay
> as they are. While Watch GitHub is on, Bifrost copies the repositories of your open pull
> requests again.

While Reviews runs, the removal waits for the clone that's running, and then the set-up runs again
straight away with the last poll, so the repositories of your open pull requests get copied
again. With Watch GitHub off, it takes the lock of the Reviews folder for the
removal, so it never deletes the clones of another copy of Bifrost that's running Reviews.

The ignore list works like the list of slash commands. Enter or Add saves the typed entry in its
clean form, trimmed and in lower case, and Save in the footer saves it too. An entry the list can't
take shows its reason on the row (see "The rows" for the reasons), and the field keeps your text.

The app follows these settings through `ReviewsParts`, which holds the store, the GitHub client and
the watcher:

- Turning Watch GitHub on opens the store, which takes the lock, and starts the watcher. A store
  that can't open still gets a watcher, which never polls, and the panel shows why. Turning it off
  stops the polls, tells the health log that Reviews stopped, closes the store and frees the lock.
  Opens, closes and the edits Reviews makes to the settings run one at a time on one worker, so
  two stores of one run never fight over the lock. Turning it off or quitting stops the rounds at
  once, and the store closes only after each round has ended (each git of a round stops within a
  second), so no git, gh or claude of a round outlives Reviews. Quitting waits (within its usual
  2 s) until the last save is on disk and the lock is free. A click such as Pause, Remove or the
  consent changes the state at once and the save follows, so a change made just before you quit
  isn't lost.
- Every other Reviews setting, plus Row flash and macOS notification, goes straight to the watcher,
  so a change to Show team requests or the ignore list rebuilds the rows, and a new poll interval
  applies to the wait that's running.
- The consent of the automatic request rounds belongs to this app alone. Each time the store opens
  with "Handle comments on my PRs automatically" on but no consent in the state, Bifrost turns the
  setting off, so the switch always shows what will really happen. After the take-over of the
  Electron state that's always the case. Only the confirmed turn-on in Settings records the
  consent: once you confirm and the setting saves, Settings tells Reviews directly
  (`ReviewsLinks.confirmAutoFix`), and new work then starts from that moment
  (`ReviewsState.consentToAutoFix`). Any other way the setting can become true, such as an edit
  of the settings file or the Debug test port, records nothing. If you confirm while Watch GitHub
  is off, the consent is recorded the next time the store opens in the same run. No automatic
  request round can start without that consent (`ReviewsState.allowsAutoFix`).

`ReviewsSectionTests`, `ReviewsRowsTests` and `ShellReviewsTests` cover the section, its search and
the consent.
