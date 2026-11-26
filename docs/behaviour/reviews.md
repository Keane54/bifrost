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
| Not installed | `gh` didn't start. The text says to install it and to log in with `gh auth login -s workflow` | No |
| Not logged in | Exit code 4, or an error that tells you to run `gh auth login`. The text says to run `gh auth login -s workflow` | No |
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

### The workflow scope

GitHub refuses a push that changes a file below `.github/workflows` unless the login has the
`workflow` scope. A conflict round is the usual case: the merge of the base branch brings in the
base's change of a workflow file, so the merge commit changes it too. When the `gh` login has no
such scope, the push fails and the round with it.

Bifrost reads the scopes of the login with one closed read, `gh api --include user`, and takes the
names from the `X-OAuth-Scopes` header (`GitHubScopes`). It keeps only those names, never a token.
A login with no such header, which is the case for a fine-grained token or a GitHub App token, has
unknown scopes, and Bifrost then warns about nothing. It reads the scopes once when Reviews first
starts in a run of the app, again at each Refresh click, and again when you turn on "Handle comments
on my PRs automatically" or "Resolve merge conflicts automatically". The confirm opens at once with
the last answer Bifrost knows, and the hint under the row follows the new read. A read that fails
keeps the last answer.

When the scopes are known and have no `workflow`, those two rows show a hint while their setting is
on, and the confirm of their turn-on has the same text:

> Your GitHub login can't push changes to workflow files, so a merge or fix that touches one will
> fail. Run gh auth refresh -h github.com -s workflow in a terminal to allow it.

A push that GitHub refuses for this reason, whether from the `[remote rejected]` line of `git push`
or from the error of a signed commit, names the words "workflow" and "scope" in its line
(`PushRefusal.server`). Bifrost looks for the words before it cuts the line to 200 characters. The
row then says what to run, in place of the hint about a protected branch. The line itself goes to
the Event log.

### Running git

`RepoGit` runs only the cases of `GitCommand`: clone, fetch, adding and pruning worktrees, reset and
clean, status, add and commit, a merge through `merge-tree` (which can also list just the names of
the conflicted files) and `commit-tree`, `write-tree` for the merge of a conflict round, a handful
of reads (`rev-parse`, `cat-file`, `config --get-all`, `remote get-url`, `ls-files --stage`,
`ls-tree`, `check-attr`, `hash-object`, `diff` of two commits or of some paths of them,
`merge-base --is-ancestor`, `rev-list`) and the push.

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

The submodule check lists the whole index and the whole tree of the head, so it runs once for each
commit. Its result is a proof that the add uses. The commit lists only the index again, because the
add changed it. These two listings may be larger than other output, so they have a larger limit.

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

### Merging the base branch

When one of your PRs conflicts with its base branch, Bifrost can merge the base into the PR's
branch and let Claude resolve the conflicts. It only ever merges, never rebases, so nothing that's
already on the branch gets rewritten and the push stays a plain fast-forward. Bifrost runs every git
command of the merge itself, in two steps either side of Claude's turn (`ConflictMerge` in
`BifrostReviews/Services`).

A poll only starts a conflict round by itself when GitHub says the PR conflicts, the PR isn't from
a fork or in the ignore list, "Resolve merge conflicts automatically" is on and you confirmed it in
this app, nothing else is going on with the PR, and Bifrost hasn't already tried this exact pair of
head and base commits (`ConflictRule` in `BifrostReviews/Model/Conflict`). Nothing else going on
means no round of any kind running or waiting in the queue, no own request of yours running, no
unsent writes, and none of your own work waiting for you: changes in the worktree that no round
made, or an own request that Bifrost didn't commit or push. A conflict round moves the worktree, so
it never starts on top of that work. Because each pair gets one attempt, a failure stays on the row
until the branch or its base moves. A poll that doesn't give both commits starts nothing, since
there would be no pair to remember.

A round that ends with nothing to show doesn't spend the pair: the PR closed, GitHub no longer
sees the conflict, the head moved, or the setting went off. The poll that started it can be a
minute old, so the same pair would start the same round at every poll. Bifrost keeps that pair in
memory and skips it for 15 minutes, unless the setting is off. A new head or base, and Resolve
now, never wait. A person using Claude's session when the round reaches its turn also leaves the
pair untried, and the next poll after the session is free starts the round. Resolve now shows the
reason in that case instead.

First, Bifrost merges in its clone with `merge-tree`, which needs no worktree and runs no hook, and
reads the list of conflicted files. git works out the merge bases itself, so when the two branches
have more than one (each merged the other at some point, which stacked PRs can cause), it merges
them first, just as `git merge` and GitHub do, and finds the same conflicts. If the merge comes out
clean, GitHub most likely hasn't caught up with the branch yet, so nothing starts. Otherwise each
conflicted file has to be one Claude can safely work on:

| Refused | Because |
| --- | --- |
| A path that the rules of a fix commit refuse, such as a workflow | Bifrost would never commit it |
| More than 50 conflicted files | That's too many for one round |
| A conflict that isn't a plain text change: a file one side deleted or renamed, a binary file, a link, a submodule, a file over 1 MiB, or any file without conflict markers | Claude can only resolve conflicts in text |

Bifrost then keeps the merge, markers and all, as a commit whose parents are the PR's head and the
base, and the worktree moves to it, so Claude edits the conflicted files in place. Before Claude
starts, the conflicted files also go through the checks of a fix commit as they stand. A file with
a `filter` attribute, or a repository with a submodule, would fail those checks after every turn,
so the round stops there and asks you to resolve the conflicts yourself.

Claude's turn runs in the PR's request session, the same one that works through its review comments,
with the prompt `/bifrost-resolve-conflicts bifrost-input=<input file>`. The round's files sit in
the PR's round folder, each named with the round's token as a request round's are. The input file
(`ConflictInput`) holds the token, the PR, the head, the base tip that Bifrost fetched, their merge
base and the conflicted files, plus the paths of two diffs of just those files, one for each side
since the merge base (left out when it's over 3 MiB, and Claude then reads the changes with git),
and the path of the PR's own request file, the same one a request round's input names. It has no PR
description and no comments, and it never lists more than 50 files. Because the conflict skill's
Bifrost mode carries the same rules for a request you type between rounds as the resolve-comments
one, an own request works the same way when the last round, or the only one so far, was a conflict
round. A request you type while a conflict round runs waits, though: the worktree then holds the
merge, which isn't on GitHub yet, and any change to a conflicted file would go into the merge
commit. Claude finishes the round, changes nothing for the request, writes no own request file, and
tells you to send the request again once the round is finished. It also checks the subject of the
worktree's commit before any request, so a request that arrives after the turn but before the round
is finished waits too.

The skill's Bifrost mode lets Claude edit only the conflicted files, in place, keeping the intent of
both sides and removing every marker line that git added, while any line that was already in the
file, such as the `=======` under a heading, stays. Claude uses the shell only to read git (`git
log`, `git show`, `git diff`) and to run checks that write nothing outside the files git ignores: it
never stages, commits, merges, checks out, resets or stashes, and it never touches a workflow,
`.claude` or `.gitmodules`. It never deletes a file, since a conflict where one side deleted the
file never reaches it. When the merge breaks code in a file without conflicts, which Claude may not
change, or when it isn't sure, it gives up with a one-line reason that the row shows.

The result file says `resolved`, listing every conflicted file exactly once, or `needs-you`, with a
reason of 1 to 300 characters on one line and no control or text-direction characters. Like a
request round's result, it has to give back the PR, the head, the base and the round's token, it
may hold no other field, and one broken rule refuses the whole file (`ConflictResult`). A good
result only means Claude says it's done: Bifrost still checks the merge itself, as below.

After Claude's turn, Bifrost makes the merge commit. The merge Claude worked on has to be the merge
of the head and the base that the commit gets as parents, so a push to the branch in the meantime
can't be undone by a merge of the older head. The worktree may differ from the merge only in the
conflicted files, so any other change, a new file included, stops the commit. The conflicted
files then pass the same checks as the files of a fix commit, `git add` takes just those paths,
`write-tree` turns the index into a tree, and `commit-tree` makes the commit, "Merge <base> into
<branch>", with the head and the base as its parents. It's never signed, even with Sign commits
through GitHub on, because the write that GitHub signs makes a commit with one parent and can't
record a merge.

Claude's session stays open after its turn, so Bifrost checks the made commit once more, from git's
own objects rather than the worktree. It has to be unsigned, have the head and the base as its
parents, differ from the merge Claude started from only in the conflicted files, keep each of them a
plain or executable file of at most 1 MiB, and hold no conflict markers that the merge added. A line
that starts with seven or more `<`, `>` or `|` counts as a marker line, and so does a line of
exactly seven `=`, the line git puts between the two sides. Such lines can be in a file for other
reasons, such as the underline of a heading in a README, so a file only fails when it has more
marker lines than the PR's version and the base's version of it each have. A merge that keeps both
sides with the `=` line still between them fails, and a heading that was already there stays. A
conflicted file that's missing from the made commit fails it too: no delete conflict ever reaches
Claude, so a missing file can only be a mistake, and the merge must not drop a file that both sides
keep.

The push goes through `Pusher`, like a fix, with two differences: the commit must have exactly the
head and the base as its parents, and a branch that gained new commits since the round read it gets
nothing at all, not even a merge, because the new head is a new conflict to look at. The texts of a
failed merge are in `ConflictFailure` (`BifrostReviews/Model/Conflict/`), and `ConflictMergeTests`
runs real git against a local repository that stands in for GitHub.

Each end leaves the copy on a commit that GitHub has, and the person's work stays:

- A push that went moves the copy to the merge. When the copy can't be reset (a person uses the
  session, or a change that no round made is in it), Bifrost still moves HEAD and the index to the
  merge and leaves the files, so the copy isn't left on the commit with the markers.
- At the end of every turn, only the conflicted files count as the round's. A file of yours that
  changed during the turn stays, the round stops with Needs you, and nothing deletes the file.
- A turn that runs out of time after Claude edited a conflicted file counts those edits as the
  round's, because the round made them on its own merge commit, and the copy goes back to the head.
  A change to any other file stays, so the copy stays as it is and the next round stops for you.
- A round that was posting when Bifrost quit first looks at the branch. A merge that's already
  there counts as pushed even when the setting is off now.
- A pushed merge clears an old reason on the row, because the round proved the copy clean.
- A failure that has no pair to mark, such as Resolve now with no base commit and a failed read,
  writes a line in the Event log.

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
the answer lacks, or that has the wrong form, counts as cut too, and so does a list whose `nodes`
or `pageInfo` Bifrost can't read (GitHub sends `nodes: null` when it fails to list them), because
it may be missing items rather than empty. A field of the wrong form in one PR reads as missing
without dropping the PR.

| What | How many | Marked cut as |
| --- | --- | --- |
| PRs of a search | The first 50 | `toReviewCut`, `mineCut` |
| Reviews of a PR | The first 30 | `truncatedReviews` |
| Latest opinion of each reviewer | 20 | `truncatedReviews` |
| Review threads | The newest 20, with their first 10 comments | `truncatedThreads` |
| Top-level comments | The newest 30 | `truncatedComments` |
| Checks of the newest commit | 20 on To review, 50 on My PRs | `truncatedChecks` |
| Review requests and request events | 10 and the newest 10 | Not marked |

A To review PR reads no reviews, threads or comments. It reads the latest opinion of each reviewer,
which gives your own last review (for the Approve button) and the count of other approvals. A My
PRs PR reads the whole conversation, and its latest opinions give the decisions. It also reads its
merge state (`mergeable`: mergeable, conflicting or unknown while GitHub works it out) and the
commit its base branch is on (`baseRefOid`), which the conflict rounds need, and it reads up to 50
checks rather than 20, because the CI rounds only act on a full list.

Each check carries its name, its outcome and where it comes from (`HeadChecks`). A check run of
GitHub Actions (the app `github-actions`) also brings its job ID and the ID of its workflow run,
which is what Bifrost needs to read the job's logs and re-run it. A check run of any other app, an
Actions run that lacks either ID, and a commit status from another CI service only ever show their
state. The checks of a head are settled once they belong to the head commit, the list isn't cut
and nothing is still running. The failed jobs are the Actions jobs whose conclusion is a failure,
a timeout or a startup failure, in job ID order, and their IDs together form the key of that
failure. The failed checks that aren't Actions jobs are listed separately, as something only you
can look at. An Actions job that was cancelled or needs an action is in neither list, and so is a
finished check whose result Bifrost can't read. The CI state still counts both. The count of
failed checks on the row counts a cancelled or action-required job, but a check with an unreadable
result only through GitHub's combined result. Either way, "no failed jobs" never means the head
passed.

A conflict or CI round doesn't trust a poll that may be a minute old, so it reads the head of the PR
again first (`HeadQueries`, the read `pr-head`). That read asks for the state, the author, the
branches and their commits, the default branch, the merge state and the same 50 checks, with the
owner, repository and number as variables. It fails when GitHub gives no known state, no head
commit or no fork flag, because the push target comes from it. Errors that come next to a full
head are logged and the read carries on, as in a poll.

The conflict and CI rounds act on the checks and the merge state, so Bifrost reads them with care.
A check value it can't read never makes the checks look done: a check whose progress is unreadable
counts as running, and a rollup, a list of checks, its nodes or its page info that Bifrost can't
read, or a node that isn't a check run or a status, marks the list cut. Checks with no head commit,
no commit ID or no head ID aren't the checks of the head, so they don't settle either. A missing or
unfamiliar merge state leaves the PR with no merge state at all, and the PR itself always stays.
When GitHub leaves out one of these fields or sends it in another form, the log names that field
the first time it happens in a run of the app, so a change on GitHub's side shows up in the log
instead of quietly breaking a round, without repeating at every poll.

Some details that the rows rely on:

- A request is direct when you are one of the requested users, and a team request otherwise. The
  request time is the newest request event for you (direct) or for any team (team), or the time the
  PR was created when GitHub gave no event.
- The checks of the newest commit give one state: failing, running or passed. A result for another
  commit than the head counts as running, and a PR with no checks has no state. A failed state with
  no failed check among the checks read still counts as one failed check.
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
request rounds (`autoFixConsent`), conflict rounds (`conflictConsent`) and CI rounds (`ciConsent`),
the queue, the review requests Bifrost has seen, the pauses and the To review rows you removed, the
comments Bifrost posted, the draft comments of its reviews, and a record for each PR: its sessions,
the round that's running, the items it has handled (each with the time of its last reply, so a newer
trusted comment makes it work again), the items held back by a failed round, Claude's open
questions, the writes of the last request round (the outbox), the reviewers it asked for a new
review, and a Handle now or Handle Copilot comments click that's waiting for its round. The record
also keeps Bifrost's attempt at the merge conflicts of the last head and base (`conflict`), the CI
budget of the current chain of commits with the failure it took and its question for you (`ci`),
and a Resolve now click that's waiting for its round, or whose round is still running
(`resolveNow`). Bifrost writes these fields
only when they have a value, so a file from an older release reads without them. The types
are in `BifrostReviews/Model/State/`, and the store in `Services/ReviewsStore.swift`. Its lock is
the shared `FileLock` of BifrostFoundation, which the Daily update store uses too.

Bifrost adds one field of its own. A review request has `noticeWaitsForCI` while its notification
waits for its CI to stop failing (see "What each poll records"). The file has this field only while
it is true, so every other request keeps the Electron form.

Every field is optional, so a file from any release of the Electron app opens unchanged, and the
read is lenient one field at a time:

- A field of the wrong form gets its empty value and the other fields stay. The log names the
  fields it dropped, each one once in a run of the app, never a PR key or any other text from the
  file.
- An outbox is all or nothing. One damaged write drops the whole outbox, because Bifrost must never
  send part of a damaged list of writes.
- A conflict or CI record that Bifrost can't read in full is read the way that starts no more
  automatic work on that PR. If a CI record loses any field, or holds a count it can't read, its
  fixes and re-runs count as used up, and a chain with a bad commit in it is read as no chain at
  all. A CI record with other fields but no chain counts as damaged in the same way, because a good
  save never writes one like that, so it can't hand a PR a fresh budget. A conflict record whose
  outcome can't be read keeps its head and base as a failed attempt with no reason, so Bifrost never
  tries that pair again by itself and the row offers Resolve now; only a record without a readable
  head or base goes. You can still start a round with a click.
- A PR record that loses any field, isn't an object at all, or holds a null conflict or CI field
  (Bifrost never writes null there), may have lost its conflict record with it, and so may a
  list of PRs that loses a record (a list that isn't an object, a key that isn't a PR, or two
  keys for one PR). Bifrost doesn't guess which pair was tried: the first poll that lists such a
  PR records its current head and base as a failed attempt with no reason, so no automatic round
  starts on that pair and the row offers Resolve now. When the list itself lost records, every PR
  of the next complete poll is treated that way. The log says which PRs. The file keeps this
  doubt until a poll settles it, so a quit before the first poll doesn't lose it.
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
| A question about failed CI and its answer | At most 500 and 2,000 UTF-16 units, or the question goes; the first 5 names of failed jobs |
| The chain of commits of the CI budget | The newest 8 |
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
- A new request whose CI fails sends no notification yet, because you can't review it. Its
  notification waits for the first poll where its row flashes, and then it shows one time. If the
  row stops being a new request first (you review it, start a review or pause it, or others
  approve it), or the request ends, no notification comes. The wait is in the state, so it lasts
  over a restart.
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
| 4 | New commits | "New commits", in amber, with the tip "Claude reviewed an older commit. Review again to check the new changes." and a Review button | Claude's review, or its draft, is on an older commit than the head, because the author pushed new commits after it |
| 5 | Review failed | "Review failed", with the reason as its tip | The last review round failed |
| 6 | Waiting for you | "Waiting for you" | A direct request that was open at the first turn-on, or that you acted on (a Review click or a round) since Bifrost first saw it |
| 7 | Trust needed | "Trust needed" | The review waits in the queue for you to trust the clone of its repository |
| 8 | Reviewing | "Reviewing" | A review round runs |
| 9 | Queued | "Queued" | The review waits for a free session |
| 10 | Paused | "Paused 42m", the minutes left and at least 1 | You paused the request |
| 11 | You approved | "You approved", in soft green | Your latest opinion approves the head commit |
| 12 | You requested changes | "You requested changes", in red | Your latest opinion requests changes on the head commit |
| 13 | You commented | "You commented", in amber | You commented on the head commit, and you haven't approved it or requested changes on it |
| 14 | Approved by others | "Approved by others" | GitHub's review decision is approved, so your approval changes nothing |
| 15 | Team request | "Team request", in the light cyan accent | The request only names a team of yours |

The state comes from the first rule that holds: a running or queued round (a queued round whose
repository needs trust is Trust needed; see "Clones and trust"), the team filter, a review you've
just given in Bifrost, a pending review, your review of the head, a failed round, Claude's Approve
with nothing posted, a pause, others' approval, a team request, and last a new request or one that
waits for you. So a PR you've reviewed never flashes, and a pause hides the flash of a new request
until it ends.

Your review of the head is your latest opinion on GitHub when it's on the head commit: an approval
gives You approved and a change request gives You requested changes. With no such opinion, a
comment of yours on the head gives You commented, and a comment never changes an opinion, so
commenting after you've approved still reads You approved. Your review counts only once the request
isn't new: someone who asks again on the same commit gets a new, flashing row. A review you've just
given in Bifrost (with Approve or Send review) counts as soon as GitHub confirms it, even before a
poll lists it, and it stops counting once you start a new review round on the PR; see "Approve"
and "The Review panel". Only a new request flashes, and the panel also stops the flash when the Row
flash setting is off.

A new request whose CI fails doesn't flash either, and it doesn't turn the To review count red or
light the attention dot. Bifrost won't review or approve it while CI fails, so it doesn't need you
yet. The row stays a new request: it keeps its place at the top, the "CI failing" text and the
Pause button. At the first poll where CI no longer fails (it runs, it passed, or the PR has no
checks), and you still haven't acted on the request, it flashes, turns the count red and notifies,
as any new request does (see "The watcher").

New commits replaces Claude's result when the head commit has moved on since Claude's review. The
row shows no verdict and no Approve button, because Bifrost offers Approve only for the exact commit
that Claude reviewed. The Review button starts a new review of the head, as on a new request.
Failing or running CI still replaces the text, so a failing CI on the new head shows "CI failing".

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
| You requested changes | "You requested changes on this pull request on GitHub." |
| You commented | "You commented on this pull request on GitHub." |

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

After the rows, `ReviewsState.recordNotices` decides which new requests notify. A request notifies
one time, at the first poll where its row flashes:

- A request that arrives while its CI fails gets `noticeWaitsForCI`, and it keeps that mark over the
  polls where CI still fails.
- The first poll where its row flashes sends the notification and clears the mark. A later fail and
  pass of CI sends nothing.
- The mark goes with no notification when the row stops being a new request: you acted on it,
  started or gave a review, paused it (Pause clears it at once), or others approved it.
- A PR with no row keeps the mark, because a cut answer can miss an open request. A request that
  leaves a full answer loses its entry, and the mark with it. A request made again is new again,
  with no mark.

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
| Needs you | "Needs you" | Red | "Claude needs your answer on 2 comments. Click to answer." With a question about failed CI as well: "Claude needs your answer on 2 comments and on the failed checks. Click to answer.", or with only that question: "Claude needs your help with the failed checks. Click to answer." |
| Needs you, for your change | "Needs you" | Red | Why your own request didn't go, or why the round didn't start (see "Your own requests") |
| Unpushed changes | "Unpushed changes" | Amber | "Bifrost won't merge the base branch over changes that aren't on GitHub. Ask Claude to commit them, or discard them." Buttons: Open session, Discard changes |
| Unpushed changes, for a comment round | "Unpushed changes" | Amber | "Bifrost won't handle new comments over changes that aren't on GitHub. Ask Claude to commit them, or discard them." Buttons: Open session, Discard changes |
| Ask again | "Ask again" | Amber | "Bifrost didn't apply your change, because Claude was busy resolving conflicts. Discard the edits Claude made for your request so the merge can be resolved first, then ask again." Button: Discard edits |
| Fixing | "Fixing 3", the items of the round | Plain | "Claude is working on 3 comments." |
| Resolving conflicts | "Resolving conflicts" | Plain | "Claude is resolving the merge conflicts with the base branch." |
| Fixing CI | "Fixing CI" | Plain | "Claude is looking at the failed checks." |
| Queued | "Queued" | Grey | "Waiting for a free session slot." |
| Trust needed | "Trust needed" | Grey | "Bifrost needs you to trust this repository first. Click Trust at the top of the panel." |
| Cloning | "Cloning" | Grey | "Bifrost is copying this repository." |
| Waiting | "Waiting" | Grey | None |
| Error | "Error" | Red | The reason the last round failed |
| Retrying CI | "Retrying CI" | Grey | "Bifrost re-ran the failed jobs and is waiting for the result." |
| Fork | "Fork" | Grey | "This pull request comes from a fork. Bifrost can't push there, so Claude leaves its comments to you." |
| Has conflicts | "Has conflicts" | Amber | "This branch has conflicts with its base branch. Choose Resolve now to let Claude resolve them." |
| Has conflicts, after a failed attempt | "Has conflicts" | Red | Why Bifrost's attempt on this head and base failed |

From the state, the Claude state is the first that holds of: a round runs (Fixing for a request
round, Resolving conflicts for a conflict round, Fixing CI for a CI round), a round of yours waits
in the queue (Queued), Claude has open questions or a question about failed CI (Needs you), your
own change waits for you (Needs you, for your change), the last round failed (Error), Bifrost
re-ran the failed jobs of the head and is waiting for the result (Retrying CI), the PR comes from a
fork (Fork), and GitHub says the PR has conflicts with its base branch (Has conflicts); otherwise
it's Waiting. A round in the queue shows Cloning while the clone of its repository runs, and Trust
needed while that clone waits for your trust (see "Clones and trust").

Has conflicts turns red, with the failure as its tip, only when Bifrost's attempt on this exact
head and base commit failed. As soon as either branch moves there's a new pair to try, so the row
goes back to amber. Retrying CI lasts while CI runs on the head, or while GitHub still shows the
same failed jobs that the CI round took, and a new result ends it, whether the jobs pass or fail
again. The question about failed CI shows on the row, and counts as a question, while "Fix failing
CI automatically" is on and you've confirmed it in this app, the question is still unanswered, and
it's about the PR's current head. Has conflicts and Retrying CI don't count as needing you, so
those rows keep their place in their status group.

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
| `<clone>/.bifrost-worktrees/<number>` | The worktree of one PR, detached at the head that the round looks at, with mode 0700. It's the folder the PR session works in. A review round makes it afresh each time, while a request round keeps it from round to round and moves it to the new head |
| `<clone>/.bifrost-io/<number>` | The input folder of one PR, with mode 0700. A review round makes it afresh each time. A request round keeps the folder but empties it, and gives each file the round's ID in its name, such as `input-0f8a2c1e5b7d.json` |

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
file back, since a session can change it. The removal runs only after a reset that worked. If the
reset fails, for example because of a lock file, every file stays where it is. Because the
request session of a PR works in the same folders from round to round, and you can use that
session yourself, a request round never touches
those folders while the session is working or showing a box: it waits until the session is idle
with no box, has stopped, or is gone (see "PR sessions"), so it never changes them while you're
using the session. A reset after a request round is skipped in the same way while you're using
the session. After its wait, the next round looks at what's in the worktree first: a change you
asked Claude for goes to GitHub before the round, and a change that no round made stops the round
rather than being reset away (see "Your own requests"). What's left over from the last round
itself is reset as usual. Then the round keeps the worktree of the last round when it's still in
place (a real folder, not a link, that belongs to the clone): it resets it to the new head and
cleans it the same way. If the reset fails, `git status` still lists a file that git doesn't
track, or the worktree's `HEAD` isn't the new head, Bifrost makes the worktree again instead and
logs why, and the round then starts a new session. A folder at that place that doesn't belong to
the clone (its admin folder is damaged) can't be checked for changes, so Bifrost never deletes
it: it moves the folder next to the worktree as `<worktree>~kept-<time>`, with all its files, and
the log gives the new path. A request that goes (merged or closed) follows the same rule. Use the
kept folder only to copy files out: its `.git` file names the admin folder of the new
worktree. Remove all clones deletes it too, and you can delete it earlier yourself. When a
review request goes, its worktree and input folder go too. The clones themselves stay until you use
Remove all clones in Settings. Every removal first checks that the path really is below the repos
folder, also after resolving the links above it, and a link inside it is removed as a link, never
followed.

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

A PR session is the Claude Code background session that does the work of a round. It's an
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

A review round always starts a fresh session, and the previous review session of that PR is
deleted first: the input file carries everything the new one needs to know, and independent
reviews are the point. The session stays after its round so you can read its chat, Bifrost stops
it after 10 minutes idle with nothing open on it, and it goes for good when the review request
goes.

A request session works the other way. Each of your own PRs has one, and it carries on from round
to round, so Claude keeps the history of the earlier rounds (what it fixed, what it asked you and
what you answered) instead of starting cold and repeating itself. The PR's conflict rounds run in it
too (see "Merge conflicts"), so whichever kind of round starts it, it's called
`<repo>-<number>-request`. The first round starts it with the request flags (see "Request rounds"),
and a later round reaches it in one of two ways:

- **It's running.** Bifrost types the round's prompt into it, just as you'd type into its chat,
  but only once it's idle with no box on it. While it's working, or showing a box you might be
  answering, the round waits for up to two minutes and then gives up with "Claude's session for
  this pull request was busy, so Bifrost didn't start the round. Choose Try again when it's
  finished." Until then the round doesn't touch the worktree or the input folder either, so the
  work of a session you're using stays as it is, also when the round gives up, you stop it, or
  you interrupt its prompt. Bifrost never stops a session you might be using just to type into
  it. If it can't type for another reason (the app has no text input for the session yet, say),
  it stops the session and resumes it instead, and gives the stopped row at least 30 seconds to
  show, since a hidden window only reads the session list every 15 seconds.
- **It's stopped**, usually by the 10-minute idle stop. Bifrost resumes it with
  `claude --bg --resume <session id> "<prompt>"` and no other flag, because a resume with flags
  starts a copy. Claude Code restores the flags the session started with and prints a note that
  lists them, and Bifrost needs every limit in that note (`--restricted`, `--strict-mcp-config`,
  `--tools`, `--permission-mode`, `--settings`, `--add-dir` and `--plugin-dir`). If one's missing,
  it removes the woken session rather than let it run with fewer limits, and the round fails.
  Bifrost only resumes a row that has really stopped: parked, with no process, and gone from
  Claude Code's list of active sessions.

Before it types or resumes, Bifrost checks that the session is still the one it started for that
PR: the same session ID, a Bifrost session marked as a PR session, the same name, and the PR's
worktree as its folder. Anything else gets a new session, and so do a few cases where carrying on
wouldn't be right: after ten rounds, so the context doesn't grow without limit; when Bifrost had
to make the worktree again; and when the flags would change, for example because you picked
another model for request sessions, since a resume can't change them. A new session replaces the
old one: Bifrost removes the old session with its chat and its own requests, so read or copy
anything you need from it before then. Like a review session, the
request session stays after each round so you can read its chat, and Bifrost stops it after 10
minutes idle with nothing open on it. Between rounds you can also ask it for a change yourself, and
Bifrost commits and pushes that change for you (see "Your own requests"). It goes for good when the
PR merges or closes, or when you use Remove all clones.

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
| The row shows a prompt (a red box) | The round ends straight away as blocked, because a round's session must never ask, and Bifrost stops the session |
| More than 30 minutes since the session started | A good result wins at an idle row (or once a missing row has been gone for 60 seconds); otherwise the round times out |
| No row for 60 seconds | The session went |
| The row is working | Keep waiting |
| The row is idle and a good result is there | The turn ended, straight away |
| Idle for 10 seconds after it worked, with no good result, and a later session list still shows it idle | The turn ended with no result |
| Idle for 120 seconds having never worked, and a later session list still shows it idle | The turn ended (the session never got going) |

The 10 seconds only applies when there's no good result: Claude Code has no end-of-turn signal,
the registry samples the rows every two seconds, and an idle sample can sit between two tool
calls, so Bifrost gives a session that worked a moment before it decides the turn ended with
nothing. Bifrost only looks at the row when something changes, and it can miss a short spell of
work that way, so an idle row that the session list showed busy since the turn began also counts as
having worked; no other change of the row does. The 30-minute limit and the 120 seconds are only
fail-safes.

The idle sample that starts those 10 seconds can itself be old. With the window hidden, the
registry only reads the session list every 15 seconds, and a Mac under heavy load can take far
longer to run `claude agents` at all, so the 10 seconds can pass without a single new look at the
session. That's why an end with no result also needs a session list that started after the 10 (or
120) seconds were up and still shows the row idle. A list that shows it working again simply carries
on with the turn, and until a list comes, only the 30-minute limit can end it.

The wait hands the round the result that passed the check when the turn ended, and both kinds of
round work from those exact bytes. Neither reads the result file again, so a session that rewrites
it after the end (a leftover background command, say) changes nothing. The file is read again only
to explain a failure when no good result was there. A request round's result file has the round's
ID in its name, so in the shared request session a late write for an earlier round lands in a file
that the current round never looks at.

`PRSessions` (`BifrostReviews/Services`) starts the sessions, begins each turn of a request
session (`beginTurn`), waits for the turn ends and handles the idle stop, with `RoundEnd` holding
the rule and `PRSessionArgs` and `SessionNames` the flags and the names. `ReviewQueue` runs the
rounds in their slots. `PRSessionsTests`, `RoundEndTests` and `ReviewQueueTests` cover them, on
scripted session rows and a manual clock.

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
2. **The PR.** Bifrost reads the PR from GitHub, with the issues it closes (up to 10), and
   fetches its head and its base branch into the clone. A PR that has closed fails the round, and
   so does one whose head moved between the read and the fetch. If Claude's own draft review for
   this commit is still pending on GitHub, the round fails too, because a second round would add
   every comment again.
3. **The input folder.** The previous session of the PR is deleted first, so it can never write
   into the new round's folders. Then the worktree goes to the head, and the input folder gets
   `input.json`, `full.diff` (from the merge base to the head), `since.diff` for a re-review,
   `mode.md` (a copy of the review skill's Bifrost mode) and `humanise-rules.md`. `input.json`
   carries a fresh token for the round, which the result file has to give back, so a result
   written by any other session (an earlier one, one a stop left behind, or another PR's) never
   counts. A diff over 3 MiB means no review. The issues the PR closes go in `pr.linkedIssues`
   (number, repository, title, URL and body), so the session can check that the PR does what its
   description and those issues ask. Each body is cut at 20,000 characters, as the PR description
   is. If the read of the issues fails or has nothing, the list is empty and the round goes on.
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

A round whose full read fails hasn't chosen any items yet, so nothing is held, and the next poll
would simply queue it again. Instead, while that error shows on the row, the polls leave the PR
alone for 15 minutes (`WorkRule.readRetry`) before they queue it again. A read that keeps failing
then costs one read every 15 minutes, a short GitHub outage still ends in a good round, and Try
again or Handle now never waits.

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
3. **The input folder.** Bifrost fetches the head. Then it waits until the PR's request session
   is idle with no box, has stopped, or is gone (see "PR sessions"). If an own request of yours is
   waiting, it goes to GitHub first and the round starts again from the full read, on the new
   head; if the worktree holds changes that no round made, the round stops there and leaves them
   alone (see "Your own requests"). Only then does Bifrost move the worktree to the head, keeping
   the worktree of the last round when it can (see "Clones and trust"). Then it empties the input
   folder and writes the round's files, each named with the first 12 hex digits of a fresh token
   for the round: `input-<id>.json`, `full-<id>.diff` (left
   out when it's over 3 MiB, in which case the session reads the files), `mode-<id>.md` (a copy
   of the resolve-comments skill's Bifrost mode) and `rules-<id>.md` (the humanise rules). The
   input file holds the PR, the token that the result has to give back, the path of the round's
   result file, and each item with its comments, each one marked as trusted or not and as yours
   or not with the same rule Bifrost uses for work, plus any earlier question about it and your
   answer.
4. **The turn** in the PR's request session (see "PR sessions"). The first round starts the
   session in the PR's worktree with the "Model for request sessions" setting:

   ```
   claude --bg --restricted --strict-mcp-config
          --tools Bash Read Glob Grep Edit Write Skill --permission-mode auto
          --add-dir <input folder> --plugin-dir <skills> --settings <the sandbox>
          [--model <model>] --name <name>
          "/bifrost-resolve-comments bifrost-input=<input file>"
   ```

   A later round types the same `/bifrost-resolve-comments bifrost-input=<input file>` prompt
   into the running session, or resumes the stopped session with it. The mode file tells Claude
   that each such message is a new round, with its own input file, token and result file, and a
   worktree that Bifrost has reset to the new head, so the earlier rounds are history only. The
   session's name is `<repo>-<number>-request`.

   `--restricted` keeps Read, Grep, Glob, Edit and Write in the worktree and the input folder, and
   it loads no settings file at all, neither yours nor one in the PR head, so the rules below are
   the whole story and nothing in `~/.claude/settings.json` can weaken them. It also makes Claude
   Code ask a person before it writes a settings, git or tool configuration file. A round never
   answers, so that prompt ends the round at once (the row shows it, no timer involved) and
   Bifrost stops the session, with "Claude stopped to ask for approval, for example to change a
   settings, git or tool file, and a round can't give it", and nothing is posted; make that change
   yourself, or try again. The turn ends as described in "When a turn ends", with a 30-minute
   limit, and Stop session, the time limit and a session that stops to ask all end the round with
   nothing posted.
5. **The result.** Bifrost checks the round's result file against what changed in the worktree and
   makes sure each earlier commit that a Fixed item names really belongs to the PR, then reads the
   PR again; a PR that merged or closed in the meantime gets nothing more.
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
for the commit, and the reset comes after it. While you're using the session at that moment (it's
working or showing a box), the reset waits for the next round instead.

A failed round holds its items, spends its click, shows Error with the reason in its tip and Try
again in the menu, and sends no notification. When a PR merges or closes (a complete poll no longer
lists it), its round stops with nothing more posted, and its request session, worktree, input
folder and queue entry go, along with its clicks, held items, questions and outbox; the items
Bifrost already handled stay. The search can leave out an open PR, so a PR that the poll doesn't
list gets one small read of its state first (`RequestQueries.stateOrGone`), and only a merged,
closed or not found PR is dropped. An open PR keeps everything, and so does a PR whose read
failed: the next poll reads again. An open PR that the search never lists (an archived
repository, for example) keeps its work, and each poll reads it, until the search lists it again or
you use Remove all clones. GitHub also answers "not found" for a private repository that the
signed-in `gh` account can't see, so after a switch of account the work of its PRs goes.
A PR that the poll lists needs no read. No round or own request
of the PR starts while its drop runs, and Remove all clones waits for the drop. When the copy had
changes that no round made (the safety net's files, the files of the row, or an own request that
didn't go), the Event log gets one line with the PR, the count and the first three file names:
"Reviews: Bifrost deleted its copy of owner/repo#7 with 2 changes that no round made and that
are not on GitHub: a.swift, b.swift." At the next start, a round that was getting ready goes back
to the queue, one whose session was running waits for it again, and one that was posting sends the
rest of its writes. Remove all clones stops the request rounds as well, and they hold their items,
though a round that's posting finishes its writes first.

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
changes where a fetch or a push goes, and the fix's only parent is the head of the round (the merge
of a conflict round has exactly the head and the base as its parents, in that order). A PR from a
fork never gets a push. Then Bifrost fetches the branch and acts on what it finds:

| The branch on GitHub | What Bifrost does |
| --- | --- |
| Already has the fix, from an earlier push that a quit cut off | Nothing |
| Is still at the head of the round | Pushes the fix as a fast-forward |
| Has new commits on top of the head, yours for example | Merges the fix and the branch with `merge-tree` and `commit-tree` (no worktree, no hooks, no signature) and pushes the merge, as long as the merge only changes files a fix commit may hold. `merge-tree` follows renames, so a fix to a file that someone moved under `.github/workflows` would land there; such a merge counts as a conflict. The merge of a conflict round gets nothing instead, and no merge of its own, because the new head is a new conflict to look at |
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
| A listed file has an edit that no round made (see "Your edits never ride in a fix") | Goes after the other writes. The "Fixed by" writes drop, and their items wait in held | "Needs you", with the files, and Handle now starts a new round once you dealt with them |
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

### Your own requests

The request session of each of your PRs stays open between rounds, so you can open its chat and
ask Claude for something yourself, say "also rename this function". Claude makes the change in the
PR's worktree, but it can't commit, push or reach GitHub from there, and no round result lists what
it changed. So your request ends the way a round does: Claude describes the change in a small file,
and Bifrost checks that file, then commits and pushes the change itself.

When the PR merges or closes, an own request that didn't go is deleted with the copy, and the
Event log names its files (see "Request rounds").

**The file.** When the change touched files, Claude ends its turn by writing the own request file,
`own-request.json` in the PR's input folder (every round's input file names it as
`files.ownRequest`, and the path never changes). It holds a version, the PR, the commit the
worktree is at (`headSha`) and a commit with a message and the list of paths. A request that
changes nothing writes no file, and the file can't carry replies, outcomes or questions.

The session has read review comments from other people, so Bifrost trusts that file no more than a
round's result. The message and the paths follow exactly the rules of a round's commit: no control
characters, nothing that asks GitHub to skip CI, and 1 to 200 clean relative paths outside any
`.git` folder, each one really changed in the worktree and listed once. The PR has to be this one,
and `headSha` has to be the commit the worktree is at. One broken rule refuses the whole file, and
Bifrost commits nothing.

**When Bifrost acts.** Only while nobody's using the session and no round holds it: straight after
your turn ends (the session list shows the session idle with no box again), straight after a round
ends, and after each poll in case that moment was missed. Bifrost never acts on the file while a
round runs. A round that gets the session while your request is waiting lets it go first: the round
changes nothing, Bifrost commits and pushes your change, and the round starts again from the full
read, on the new head. A PR from a fork never gets a push.

**A message you type while a round runs.** Claude Code holds it and runs it once the round's work
is done, often in what Bifrost still sees as the round's turn. When Claude writes the file for it,
Bifrost takes that as a sign that you were in the turn: it counts none of the turn's changes as the
round's, so no reset removes them (Stop session included), and the file goes as your own request
right after the round. Bifrost can't be sure you asked, so the Event log line for it says "a change
that Claude made while it worked on" the PR. If the round committed a fix in the meantime, the
worktree's head has moved, so the file is refused and the row shows "Needs you": ask Claude to try
again. A message with no file can't be told apart from the round's own work (the session runs with
no hooks, so Bifrost doesn't see your prompt), and its changes count as the round's.

**Your edits never ride in a fix.** Bifrost makes a fix commit from the listed files, and an edit of
yours in one of them must not go to GitHub inside Claude's commit. So it checks the listed files
before and after it makes the commit. A listed file with a change that no round made (for example a
request you typed that Claude did in the same turn, or an edit of yours in the seconds after the
result) stops the fix: Bifrost makes no commit, or moves a commit it made back to plain changes, the
"Fixed by" replies don't go, their items wait in held, and the row shows "Needs you" with the files.
The other replies still go. When Claude wrote an own request file in that turn, every listed file
counts as changed, so the fix stops and your own request goes alone, on the head of the round. A fix
that is committed but doesn't reach GitHub (a conflict, for example) also moves the worktree back to
the head of the round, unless you are using the session, so the next own request pushes. Each outbox
keeps the stamp of every listed file from the end of the turn (or, for an own request, from the read
of its file), so this holds also after Bifrost quit: a clean fix commits and pushes again, and an
edit after the result still stops it. A round that finds no record of the copy (Bifrost restarted in
a turn that left an own request file) stops the fix too. Only an outbox saved by an older version,
with no stamps, counts the files that are there as the round's.

**The commit and the push.** Bifrost reads the file and removes it straight away, so nothing reads
it twice. Then it saves an outbox with just two writes, the commit and the push, and sends them
through the same path as a round's fix (see "The push and the writes"): the same file rules, the
same local commit with your git identity, "Sign commits through GitHub" when it's on, the same
checks of the push target, the same fetch, and the same outcomes when the branch has moved,
conflicts, was rewritten or is gone. Unlike a fix, a file Claude changed but didn't list stays in
the worktree after the commit, so the next round stops and asks you about it (see "The safety net").
Bifrost keeps the stamp of each listed file when it reads the file. When a listed file changes
before or while Bifrost commits, it moves the commit back to plain changes and sends the change
again later (at the next poll or the end of the next turn, while nobody uses the session), so the
commit holds the file as it is then. If Bifrost quits half way, the next poll carries on from where
it stopped.

**When it doesn't go.** A refused file, a listed file that a commit rule refuses, or a push that
doesn't land makes the PR's row show "Needs you", with the reason as its tip, and the same reason
goes to the Event log; a change that went gets a line there too. Your change is never thrown away.
If Bifrost had already made the commit, it moves the worktree back to the head and keeps the files,
so the change is there as plain changes again, ready for you to ask Claude to try again once you've
dealt with the reason. When the branch on GitHub moved in the way (a conflict, or a rewrite), the
worktree can only follow it once your change is out of it, so the tip says to ask Claude to undo
it, choose Handle now, then ask for it again. When Bifrost can't tell whether the push landed, or
couldn't reach GitHub, the outbox stays instead: Try again pushes it again through the same steps,
with the same texts and Event log lines, and Don't send the rest drops it and keeps the change in
the worktree. Neither shows while the push is still running. Handle now shows on every row that
needs you for your change, and it clears the reason until the next round looks again.

**While the copy holds a merge.** During a conflict round the worktree sits on Bifrost's merge with
its conflict markers, which isn't on GitHub (see "Merge conflicts"). Claude's mode file tells it to
leave a request alone then, but Bifrost doesn't rely on that. If the own request file turns up at
the end of a conflict round's turn, or before its commit, Bifrost refuses the file, commits and
pushes nothing (neither your change nor the merge), keeps the worktree as it is, and the row shows
"Needs you". An own request that comes later while the worktree is still on that merge, because a
round couldn't put it back, is refused the same way, since a commit on top of it would push the
merge with its markers. Discard these changes on such a copy puts it back on the PR's head, not on
the merge, so the next request works on the real branch.

**The safety net.** A change with no file, because Claude didn't write one or you edited the
worktree yourself, would otherwise be reset away by the next round. So before a round resets the
worktree, Bifrost compares what's there with what it knows about: whatever the last round left at
the end of its turn, and whatever stayed after Bifrost's own last reset. Anything else counts as
yours. The round then doesn't start, its items wait for Handle now, and the row shows "Needs you".
Once you've asked Claude in the session to commit the changes (it writes the file) or to undo them,
Handle now starts the round again. A round checks again before it sends its prompt a second time,
for example after a box at the send that you answered, and the resets after a round's turn and
after its fix commit skip a worktree that holds a change of yours. Files that the last round itself
left behind without listing them are still reset as before. The comparison works on `git status`,
which leaves out the files git ignores, so an ignored file you asked for (a local `.env`, say) still
goes with the round's clean. Bifrost keeps its record in memory only, so after a restart every
change in the worktree counts as yours.

When a round would need a new session (the old one is gone, or isn't the PR's any more), it runs
the same check before it removes the old session, so a session that's still there stays for you to
use. When there's no session to ask, or you'd rather drop the changes, the row's menu has
"Discard these changes". It shows only on a "Needs you, for your change" row whose reason came with
changed files that Bifrost found in its copy (the safety net's list, or the change of an own request
that didn't go), and with no update waiting to be sent; a row that waits for you with no such files
doesn't get it. When you pick it, Bifrost reads the copy again and asks in its own dialog, which
names the files ("Discard the changes in 3 files?", "They aren't on GitHub, and you can't get them
back: notes.txt, src/a.swift and src/b.swift. Files that git ignores in Bifrost's copy go too.",
with up to five names and then "and 2 more"), and only Discard goes ahead: Bifrost resets the copy
to the commit it's at, removes the files git doesn't track (ignored ones too) and any own request
file, clears the reason and writes a line to the Event log. Cancel changes nothing. Handle now then
starts the round. If the changes are already gone, nothing is asked: the panel's error line says
"There's nothing to discard: Bifrost's copy of this pull request has no changes now." and the
reason clears. While a round, an own request or a drop runs, while updates wait to be sent, or
while someone's using the session, the error line says that Bifrost can't discard the changes now,
and no round or own request starts while a discard runs. If git can't reset the copy, the changes
and the reason stay, and the error line says so.

| Case | Row tip |
| --- | --- |
| Changes no round made | "Unpushed changes" in amber, with the tip "Bifrost won't handle new comments over changes that aren't on GitHub. Ask Claude to commit them, or discard them." and the buttons Open session and Discard changes. The Event log keeps the long text: "Bifrost's copy of this pull request has changes that aren't on GitHub yet, so Claude didn't start on the new comments ..." |
| Discard these changes (the dialog) | Title "Discard the changes in `<n>` files?" ("1 file" for one), body "They aren't on GitHub, and you can't get them back: `<names>`. Files that git ignores in Bifrost's copy go too.", button "Discard" |
| Discard these changes (the error line) | "There's nothing to discard: Bifrost's copy of this pull request has no changes now." / "Bifrost can't discard the changes now, because Claude or a round is using this pull request's copy. Try again when it's finished." / "Bifrost couldn't discard the changes, so they're still there. The Event log has the details." A failed reset leaves every file and the reason of the row as they are |
| A refused file | "Claude wrote a commit request Bifrost couldn't use (`<reason>`), so Bifrost didn't commit your change." + K + " Ask Claude in its session to try again." |
| A file while the copy holds a conflict round's merge | The row shows "Ask again" (see "Merge conflicts"). The Event log has: "Claude was resolving merge conflicts in Bifrost's copy of this pull request, so Bifrost didn't commit your change or push the merge." + K + " Choose Discard these changes, then ask Claude again." |
| A listed file a commit rule refuses | "Bifrost didn't commit your change. `<rule>`" + K |
| git couldn't commit | "Bifrost couldn't commit your change. The Event log has the details." + K |
| A conflict | "Someone pushed to this branch, and your change doesn't merge cleanly, so Bifrost didn't push it." + K + A |
| A rewritten branch | "Someone rewrote this branch, so Bifrost didn't push your change." + K + A |
| A branch that kept moving | "The branch kept changing while Bifrost pushed, so your change didn't go." + K + " Ask Claude in its session to try again." |
| A gone branch | "The branch is gone from GitHub, so Bifrost didn't push your change." + K |
| A refused target or a fork | "Bifrost won't push to this branch, so it didn't push your change." + K, or "This pull request comes from a fork, where Bifrost can't push, so it didn't push your change." + K |
| GitHub refused the push | "GitHub didn't accept your change, so the branch may be protected. The Event log has GitHub's reason." + K |
| GitHub refused the push for the workflow scope | "GitHub refused your change because it touches a workflow file and your GitHub login can't push workflow changes, so run gh auth refresh -h github.com -s workflow in a terminal and then try again." + K |
| A signed commit that can't go | "Your change is over 4 MB, which is too large for a commit that GitHub signs." or "Your change touches a link or a file that must stay executable, and GitHub can't keep that in a commit it signs.", then "Turn off Sign commits through GitHub, then ask Claude in its session to try again." + K |
| git or GitHub couldn't be reached | "Bifrost couldn't push your change. The Event log has the details. Choose Try again to push it." (or the GitHub error with the same ending) |
| The push may have landed | "Bifrost can't tell if your change reached GitHub. Check the pull request on GitHub, then choose Try again." |

K is " Your change is still in Bifrost's copy of this pull request.", and A is " Ask Claude in its
session to undo it, choose Handle now, then ask for it again."

`OwnRequests` (`BifrostReviews/Services`) runs an own request, `OwnRequestFile` and `OwnRequestStop`
(`BifrostReviews/Model/Request`) hold the file check and the texts, `RepoStore` keeps the safety
net's record (`markLeftovers`, `unknownChanges`) and moves a commit that didn't land back to changes
(`uncommit`), `ReviewRounds.discardChanges` runs Discard these changes, and `PRSessions` spots the
end of a turn (`requestFree`). `OwnRequestTests` covers the
check and the texts, and `RequestRoundTests` runs own requests and the safety net end to end with
real git, the fake GitHub and scripted session rows.

## Merge conflicts

When one of your PRs conflicts with its base branch, a conflict round merges the base into the PR's
branch, lets Claude resolve the conflicts in the PR's request session, and pushes the merge once
Bifrost has checked it. The git side of that, from the merge in the clone to the checks of the
made commit, is described under "Merging the base branch"; this section is about when a round runs
and how it ends.

**When a round starts.** After each good poll, a PR of yours gets a round by itself only when
"Resolve merge conflicts automatically" is on and you confirmed it in this app, GitHub says the PR
conflicts, and Bifrost hasn't tried this head and base before (`ConflictRule`). Nothing else may be
going on with the PR either: no round of any kind running or queued, no own request or drop
running, no Discard these changes in progress, nobody using its request session, no unsent updates,
and none of your own work waiting for you. Resolve now queues one round on a row that conflicts,
isn't from a fork, and has no round, no queued round of its own and no unsent updates. It works with
the setting off and on a pair that was already tried, and the click is kept in the state until its
round ends, so a restart in between doesn't lose it. It's the "Resolve now" item of the row menu
(see "The panel"), and it shows only while the row is resolvable (`MyPRRules.isResolvable`).

**A round step by step.**

1. **The clone and the trust**, as for a request round. Unsent updates end the round quietly,
   because their fix can still be in the worktree.
2. **A fresh read of the head.** A poll can be a minute old, so the round reads the PR again. A PR
   that closed, one that GitHub no longer says conflicts, and an automatic round whose setting or
   consent went off in the meantime end quietly. A PR that isn't yours or comes from a fork fails.
3. **The attempt.** Bifrost records this head and base as being worked on, so no automatic round
   tries the pair again, whatever happens next.
4. **The merge.** Bifrost fetches the head and the base branch. A head that moved since the read
   ends the round quietly, since the new head is a new pair. Then it merges the base into the head
   in its clone.
5. **The turn.** The round goes through the PR's one request session, exactly as a request round
   does: it starts the session, types its prompt into it or resumes it, and waits until nobody's
   using it first (see "PR sessions"). Only then does it touch the session's folders. A waiting own
   request goes first; changes in the worktree that no round made stop the round with "Needs you"
   (see "The safety net"); then the worktree moves to the merge with its markers, the submodule and
   filter checks run, and the round folder gets the input file, the mode file and the two diffs,
   each named with the round's token. The prompt is `/bifrost-resolve-conflicts
   bifrost-input=<input file>`.
6. **The end of the turn**, as in "When a turn ends", with the same 30-minute limit. A result of
   `needs-you` fails the round with Claude's reason. An own request file at this point means Claude
   changed files for a request during the round, so Bifrost refuses it and stops (see "Your own
   requests").
7. **The commit** of the merge. A change that no round made, found just before the commit or just
   after it (someone typed into the session after the turn), stops the round with "Needs you" and
   the merge doesn't go.
8. **A fresh read again.** A PR that closed, a head that moved, and an automatic round whose setting
   or consent went off end quietly, with nothing pushed.
9. **The push.** The round is saved as posting with the merge, then `Pusher` pushes it: the merge
   must have the head and the base as its parents, and a branch with new commits gets nothing.

| How it ends | The attempt | The row |
| --- | --- | --- |
| The merge reached GitHub | Kept with the merge, which also joins the CI chain of the head; the worktree moves to the merge, and a poll runs at once | The next poll shows the new head |
| A failure | Kept with the reason, which only Resolve now or a new head or base clears | "Has conflicts" in red, with the reason |
| A quiet end (closed, no conflict now, a moved head or branch, the setting off) | Dropped, so the pair counts as not tried | As GitHub shows the PR |
| Your work in the way (the safety net, an own request in the turn) | Dropped, and the worktree stays as it is | "Unpushed changes" or "Ask again" in amber, with Discard changes or Discard edits |

After a failure the worktree goes back to the PR's head, unless someone's using the session or it
holds a change that no round made. The Event log gets git's line when the merge or the push failed
in git. A failure never goes to the row's error, and no conflict round sends a notification.

Stop session during a round records "You stopped Claude, so Bifrost pushed nothing. Choose Resolve
now to try again." on the attempt. When the PR merges or closes, the round stops and its session,
worktree, attempt and click go, along with the rest of the PR's work. Remove all clones stops the
round and drops its attempt. At the next start, a round that was getting ready goes back to the
queue, one whose session was running waits for it and goes on with the merge it saved, one that
was posting pushes again (the push checks the branch first, so a merge that already landed isn't
pushed twice), and one you stopped before the quit fails with the stop text.

A session that ends by itself during a round (its row goes, and nobody stopped it) records "Claude's
session ended before the round finished, so Bifrost pushed nothing." in the same way. A request
round shows the same wording with "posted nothing".

| Case | Row tip |
| --- | --- |
| Changes that no round made | "Unpushed changes" in amber, with the tip "Bifrost won't merge the base branch over changes that aren't on GitHub. Ask Claude to commit them, or discard them." and the buttons Open session and Discard changes. The Event log keeps the long text: "Bifrost's copy of this pull request has changes that aren't on GitHub yet, so Bifrost didn't push a merge of the base branch ..." |
| An own request file in the turn | "Ask again" in amber, with the tip "Bifrost didn't apply your change, because Claude was busy resolving conflicts. Discard the edits Claude made for your request so the merge can be resolved first, then ask again." and the button Discard edits |

`ReviewRounds` runs the rounds, with the poll, Resolve now and the ends in
`BifrostReviews/Services/ConflictRounds.swift` and the steps of one round in `ConflictRound.swift`.
`ConflictRule`, `ConflictFailure`, `ConflictInput` and `ConflictResult` in
`BifrostReviews/Model/Conflict` hold the rules and the texts, and `ConflictRoundTests` runs whole
rounds with real git on a local repository, the fake GitHub and scripted session rows.

**Trying it by hand.** On a scratch branch of one of your own repositories, open a PR, then push a
conflicting change to the base. The row shows "Resolving conflicts" while the round runs, and then
GitHub shows a "Merge <base> into <branch>" commit on the branch. Bifrost never force-pushes.

## The panel

The Reviews button sits in the side bar after Service status, and it shows a small dot while
something waits for you: a request that flashes, a draft to check, or a question from Claude or a
change of yours that needs you on one of your PRs. It opens the Reviews panel, which has the two
tabs, To review and My PRs, each with its count. The To review count turns red while a row flashes,
and the My PRs count while a row of yours shows "Needs you". To the right of the tabs, "Last
checked 09:07" says when the last good poll was (with the day too once that's another day), and
Refresh polls straight away. Its icon turns, once a second and with no end, from your click until
the poll that the click asked for ends, also when that poll fails. A click during a poll of the
timer asks for one more poll, so the icon turns until that one ends. A poll of the timer and the
first poll never turn it, and with Reduce Motion on it stays still (`ReviewsWatcher.refreshing`).

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

Each row has the two lines described in "The rows". A new request flashes, unless its CI fails (see
"To review"): a red layer behind the row fades from full to a quarter and back once a second, the
same rhythm as the Overview's red box, and turning Row flash off in Settings stops it (the tab count
stays red). The box before "Needs you" on a My PRs row flashes the same way. The buttons on the
right depend on the row: Approve in soft green where Claude suggests approval (see "Approve"),
Comment in amber or Request changes in red where Claude left a draft for you to check (see "The
Review panel"), Review on a request that waits for you (a new request, one you've already seen, a
team request, or one Claude found nothing to flag on and that has no Approve), Try again on a failed
review, Pause on a new request, and Remove on a row that others approved, which hides it in Bifrost
and changes nothing on GitHub. A PR with failing CI gets no Review button.

- A click on a My PRs row where Claude has questions opens the Answer panel (see "The Answer
  panel"). A click on any other row opens the chat of its PR session while that session is working
  or needs you, and otherwise does nothing.
- Cmd+click on a row, or a click on its PR number, opens the PR on GitHub, and only ever its https
  address on github.com.
- A right-click or a Control-click shows the Bifrost menu with only the items that apply to the
  row. On a To review row they come in this order: Open on GitHub; Open session while the PR has a
  session that isn't parked; Approve while the row offers it, CI isn't running and nothing is being
  written to the PR; Comment or Request changes while the row offers Claude's draft and nothing is
  being written to the PR; Review
  (Try again on a failed row) whenever a round can start; Remove on a row that others approved;
  Cancel review while a review waits in the queue or for trust; Stop session; Pause on a new
  request; and End pause now on a paused row. On a My PRs row: Open on
  GitHub; Open session; Answer Claude while Claude has questions; Handle now and Handle Copilot
  comments while their items wait and Claude is waiting, needs you or failed; Resolve now while
  the PR has conflicts that a round can resolve (no round, no queued round, no unsent updates);
  Try again after a failed round; Don't send the rest while the writes of a stopped round wait
  for Try again; Cancel while a round waits in the queue; and Stop session while a round runs. A PR
  from a fork has Open on GitHub only. While the menu is open it follows the row, and it closes if
  the row goes. Only Approve writes to GitHub, and only because you chose it: a review round only
  ever leaves a pending review, Comment and Request changes just open the Review panel, Don't send
  the rest sends nothing, and a request round's result is checked before Bifrost posts anything.
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
and Approve leaves the row menu. The state text, such as "Approval recommended", goes too, because
it no longer fits once you've clicked; it comes back only if the approval fails. With Reduce Motion
on in System Settings, the loader stays still. Once GitHub confirms the approval, a soft green check
and "Approved" take its place for 3 seconds. Bifrost polls straight away, and GitHub usually drops
the review request once you've approved, which would make the row vanish at once. Bifrost keeps the
row in place until the 3 seconds are up, and then it goes, or moves to You approved if GitHub still
lists the request. GitHub can take a moment to list a new review, so Bifrost remembers the approval
that GitHub confirmed, and the row says You approved until a poll shows the review too (or until
you start a new review round on the PR): it never goes back to offering Approve. If the approval
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

`ApproveFlow` runs the click, `ApproveGuard` holds the checks and the write, and
`DraftQueries.fresh` is the read. `ReviewWrites` keeps the progress that the row shows
(`ReviewWriteProgress`, drawn by `WriteProgressLabel`) and the approvals GitHub confirmed, and it
does the same for a send of the Review panel. While an approval has a progress, the watcher keeps
its row when a poll drops the PR (`ReviewRows.holding`). `ApproveFlowTests`, `ApproveGuardTests`
and `ReviewDraftPanelTests.theRowShowsTheProgressOfItsApproval` cover them.

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

Send review shows how the send is going, the same way Approve does on a row. As soon as you click,
the button gives way to a spinning loader with "Commenting…" or "Requesting changes…", so there's
nothing to click a second time, and the row in the Reviews panel shows the same progress in place
of its state text and buttons, with Comment or Request changes gone from its menu. Once GitHub
confirms the review, the panel closes and the row shows a check with "Commented" in amber or
"Changes requested" in red for 3 seconds, staying in place even if the poll straight after drops
the PR. GitHub usually drops the review request once you've reviewed, so the row then goes. If
GitHub still lists the request, the row says You commented or You requested changes, with no
button for the draft and no Review button, and it stays that way until a poll shows your review on
that commit, the PR gets new commits or the request goes. That way a poll that's a moment behind
GitHub never brings Claude's draft back. A poll never lists a comment, though, so starting a new
review round on the PR (Review in the row menu) also ends it: the row then shows the round, and
then the round's own draft. If the send doesn't go through, the progress ends at once,
Send review comes back and the reason shows in the panel's error line.

If the draft holds comments you added on GitHub, Discard draft and Approve instead ask first
("Discard draft also deletes the comment you added to this draft on GitHub.") with Keep draft next
to the button. An action that works closes the panel and polls straight away. One that doesn't shows
its reason in the panel's error line and keeps your edits, so you can try again; a change that
GitHub may have saved is never sent again by itself. When the row no longer offers the draft (a
round started, or the draft is gone), the panel says "You can't change this draft right now. The row
in the Reviews panel shows why." and allows nothing.

`DraftFlow` runs the panel, `DraftEdits` holds the checks, the plan of a send and the guard of each
write, and `ReviewDraftPanels` is the panel. `ReviewWrites` keeps the progress of a send and the
review that GitHub confirmed, as it does for Approve. `DraftFlowTests`, `DraftEditsTests` and
`ReviewDraftPanelTests` cover them, and
`ShellReviewsTests.aConfirmedSendShowsYouRequestedChangesWhileThePollIsBehind` covers a poll
that's behind.

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
handle yourself is marked handled with no round. That round runs in the PR's request session, the
same session that asked the questions (see "PR sessions"), so Claude reads your answers with the
whole conversation that led to them. An answer is a click, so it starts a round even
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

Settings > Reviews has one row for each Reviews setting, with the labels of the Electron app plus
two rows that are new to this app, and the Settings search finds each row by its label
(`ReviewsSettingsRow`):

| Row | Control | Default |
| --- | --- | --- |
| Watch GitHub | Check box; each turn-on asks first | Off |
| Handle comments on my PRs automatically | Check box; each turn-on asks first | On, but see the consent below |
| Resolve merge conflicts automatically | Check box; each turn-on asks first | Off |
| Fix failing CI automatically | Check box; each turn-on asks first; hidden for now | Off |
| Sign commits through GitHub | Check box | Off |
| Show team requests | Check box | On |
| Maximum PR sessions | Number from 1 to 10 | 3 |
| Pause time | 15 or 30 minutes, or 1, 2, 4 or 8 hours | 1 hour |
| GitHub poll interval | 1, 2, 5 or 10 minutes | 2 minutes |
| Model for request sessions | Claude Code default, Opus, Sonnet or Haiku | Claude Code default |
| Model for review sessions | The same choices | Claude Code default |
| Repositories to ignore | A field with Add, and the list with a Remove button on each entry | Empty |
| Remove all clones | A Remove button; it asks first | None |

Turning on Watch GitHub, or any of the three settings that let Bifrost work on your own pull
requests by itself (comments, merge conflicts and failing CI), first shows Bifrost's own confirm
dialog, and Cancel leaves the box off. Watch GitHub and "Handle comments on my PRs automatically"
keep the texts of the Electron app. "Resolve merge conflicts automatically" and "Fix failing CI
automatically" are new to this app, and their rows sit straight after the comments row. Turning
any of them off needs no confirm.

The Fix failing CI row doesn't show in the section, and the search doesn't find it, because the CI
watcher that it controls doesn't exist yet. The setting, its key and its consent stay. The row comes
back with the CI watcher (`ReviewsSettingsRow.shown` lists the rows that show).

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

> **Resolve merge conflicts automatically?** When GitHub says one of your pull requests has
> conflicts, Bifrost merges the base branch into your branch in its own copy of the repository, and
> Claude resolves the conflicts. Bifrost checks Claude's work, then commits the merge and pushes it
> to your branch. It never rebases or force-pushes, and it tries once for each new conflict. This
> includes pull requests that have conflicts now.

> **Fix failing CI automatically?** When GitHub Actions fails on one of your pull requests, Claude
> reads the failed logs and your code. Bifrost then pushes Claude's fix to your branch, or re-runs
> the failed jobs if Claude thinks they were flaky, and asks you when Claude isn't sure. Each commit
> you push gets at most two fixes and one re-run. This includes pull requests that are failing now.

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
- Each of the three settings that work on your own pull requests by themselves has a consent, and
  the consents belong to this app alone: `autoFixConsent` for the comments, `conflictConsent` for
  merge conflicts and `ciConsent` for failing CI, all kept in the state. Each time the store opens,
  Bifrost turns off every one of these settings that's on without its consent, in a single edit of
  the settings, so each switch always shows what will really happen. For the comments that's always
  the case after the take-over of the Electron state. Only the confirmed turn-on in Settings records
  a consent: once you confirm and the setting saves, Settings tells Reviews directly through that
  setting's link (`ReviewsLinks.confirmAutoFix`, `confirmResolveConflicts` and `confirmFixCI`). For
  the comments, new work then starts from that moment (`ReviewsState.consentToAutoFix`); the other
  two don't move the start of new work, because their confirms say that pull requests which already
  conflict or fail are included (`consentToConflictFix`, `consentToCIFix`). Any other way a setting
  can become true, such as an edit of the settings file or the Debug test port, records nothing. If
  you confirm while Watch GitHub is off, the consent is recorded the next time the store opens in
  the same run, unless you turn that setting off first. Turning a setting off stops its work but
  keeps its consent. No automatic request round can start without its consent
  (`ReviewsState.allowsAutoFix`), and the same goes for the conflict and CI rounds
  (`allowsConflictFix`, `allowsCIFix`). A re-run of failed jobs needs more than a check: it takes a
  `CIConsent`, which only `ReviewsState.ciConsent(_:)` can make, and only while the setting is on
  and the consent is recorded.

`ReviewsSectionTests`, `ReviewsRowsTests` and `ShellReviewsTests` cover the section, its search and
the consents.
