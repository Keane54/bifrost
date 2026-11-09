# Bifrost Reviews R1 (read-only Reviews panel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only Reviews panel. It shows, from `gh`, the open PRs that request your review and your own open PRs. It has the review status, the failed-check icon, the red flash for new requests, Pause, and a Settings section. No Claude session starts in R1.

**Architecture:** A new main-process module `src/main/reviews/` polls GitHub with one `gh api graphql` query. It keeps its state in `~/.bifrost/reviews/state.json`. Pure functions build a sorted snapshot, and the watcher pushes it to the renderer on `reviews:update`. The renderer has a new panel kind `reviews` with two tabs and two-line rows (layout B of the mockup of 2026-11-09).

**Tech Stack:** Electron 44, electron-vite 6, React 19, TypeScript 5.9, Tailwind CSS 4.3, Base UI 1.9, lucide-react 1.61, Vitest 5, Playwright 1.64. The `gh` CLI. No new library.

**Spec:** `docs/specs/2026-11-09-bifrost-reviews-design.md` (the Reviews design). Main spec: `docs/specs/2026-11-04-bifrost-design.md`.

**Order:** This is plan 1 of 3. R2 (repositories, trust, review sessions) and R3 (request sessions) get their own plans after R1 is on `main`. R1 defines all shared Reviews types now, so R2 and R3 add no new state version.

**Inputs that exist:** the code map `/private/tmp/claude-501/-Users-dev-user-Developer-claude-statusline/b72dc96f-be42-469c-abbe-a0fee6807fa2/scratchpad/reviews-code-map.md` (file paths, signatures, conventions) and the spike report `/private/tmp/claude-501/-Users-dev-user-Developer-claude-statusline/b72dc96f-be42-469c-abbe-a0fee6807fa2/scratchpad/reviews-spike-report.md` (GitHub field facts). Read the code map section that a task names before the task starts.

## Global Constraints

- Write all prose, comments, docs and commit bodies in ASD-STE100. Never use the em dash (in a test string write `\u2014`). Conventional Commits. Commit body lines of 100 characters or less.
- Text that a person reads in the app is plain, friendly English (project `CLAUDE.md`). Say "folder", not "directory".
- ESM TypeScript only. Fake CLIs are POSIX `sh` scripts. Add no library. Use the `gh` CLI for all GitHub calls.
- Tests never call the real GitHub and never run the real `claude`. Tests never touch the real `~/.claude` or `~/.bifrost`. The smoke guard (`realFiles()`) must stay unchanged.
- Build each `className` with `cx()`. Colours only as tokens in `app.css`. Square corners. No `rounded` class.
- A refusal is `new Error('refused: <phrase>')` from a `REFUSED_*` constant, and each code gets a text in `FRIENDLY_ERRORS` (`src/renderer/src/actions/errors.ts`).
- IPC: each handler uses `fromPage` and checks each value. The renderer sends a PR key or nothing, never a path, a URL or a command. Main opens only a URL that came from `gh` and starts with `https://github.com/`.
- JSON writes use `writeJsonAtomic`. A store that cannot read its file does not save. A folder that Bifrost makes in `~/.bifrost` has mode 0700.
- Each long-lived part stops in `stopRegistry()`. A loop sets its next timer after the end of a round and keeps a generation counter.
- Run `pnpm check`, `pnpm typecheck` and `pnpm test` before each commit. Commit with explicit paths. Never use `git stash`, `git checkout --`, `git restore` or `git reset`.
- `Settings.version` stays 1. A bad settings value gets its default.
- Do not run, signal or drive the user's dev Bifrost (`electron-vite dev` in the main checkout). Work only in `.worktrees/reviews`.

## Decisions for R1 (controller rulings, 2026-11-09)

| ID | Decision |
|---|---|
| R1-1 | One GraphQL query for each poll, with two search aliases: `review-requested:@me` and `author:@me`, both with `is:pr is:open archived:false`, `first: 50`. A direct request is a PR whose open requests list the viewer login. Any other PR in the first list is a team request. |
| R1-2 | The request time is the `createdAt` of the newest `ReviewRequestedEvent` for the viewer (or for a team) in `timelineItems`. Without one, it is the PR `createdAt`. The To review age counts from it. |
| R1-3 | The snapshot is sorted in the main process with the order functions of `src/shared/reviews-order.ts`. The renderer shows it in that order. |
| R1-4 | The watcher runs also in a test home, with the `gh` from `PATH`, so the smoke test can use a fake `gh`. Its state goes to `paths.bifrostHome` of the test home. |
| R1-5 | A notification shows only for a new direct request (first arrival). The end of a pause does not notify. A click opens the Reviews panel on the To review tab. |
| R1-6 | `CheckRow`, `NumberRow` and `SelectRow` move from `GeneralSection.tsx` to `src/renderer/src/settings/rows.tsx`, so the Reviews section can use them. The source tests that count them change with the move. |
| R1-7 | In R1, the Claude state of each My PRs row is `waiting`, and To review has no `reviewing` or `queued` row. R2 and R3 fill these from the sessions. |

## Review Focus

1. **`gh` fails during a poll** (logged out, network down, rate limit, a timeout). The panel keeps the last rows, shows a friendly line, and the state file does not change. Test: Task 5, `keeps the last snapshot when a poll fails`.
2. **A truncated answer** (more than 50 PRs, or more threads than one page). Items that the answer did not include are never added to the baseline. Test: Task 4, `does not add items of a truncated PR to the baseline`.
3. **A restart of Bifrost.** Requests that were open before the restart do not flash again. A request that arrived while Bifrost was closed flashes. Test: Task 5, `a request that is known after a restart does not flash`.
4. **A request that goes and comes back** (you submit a review, the author asks again). It flashes again and notifies again. Test: Task 5, `a request that comes back flashes and notifies`.
5. **A pause that ends while Bifrost is closed.** At the next start, the row flashes, with no notification. Test: Task 5, `an ended pause flashes again without a notification`.

---

### Task 1: Settings keys, the Watch GitHub effect, and a larger stdout limit

**Files:**
- Modify: `src/shared/settings.ts`, `src/main/settings/effects.ts`, `src/main/claude/cli.ts`, `src/main/ipc.ts` (the two new effect kinds do nothing yet)
- Test: `test/shared/settings.test.ts`, `test/main/settings/effects.test.ts`, `test/main/claude/cli.test.ts`

**Interfaces:**
- Produces: these `Settings` fields with these defaults and checks:

| Key | Type | Default | Check |
|---|---|---|---|
| `reviewsWatch` | `boolean` | `false` | `isBoolean` |
| `reviewsAutoFix` | `boolean` | `true` | `isBoolean` |
| `reviewsTeamRequests` | `boolean` | `true` | `isBoolean` |
| `reviewsMaxSessions` | `number` | `3` | `onStep(1, 10, 1)` |
| `reviewsPauseMinutes` | `number` | `60` | `oneOf([15, 30, 60, 120, 240, 480])` |
| `reviewsPollMinutes` | `number` | `2` | `oneOf([1, 2, 5, 10])` |
| `reviewsRequestModel` | `ModelChoice` | `''` | `oneOf(['', 'opus', 'sonnet', 'haiku'])` |
| `reviewsReviewModel` | `ModelChoice` | `''` | same |
| `reviewsIgnore` | `string[]` | `[]` | its own parse and check, as `slashCommands` |

- Produces: `export const REVIEWS_IGNORE_ENTRY = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/(?:\*|[A-Za-z0-9._-]{1,100})$/` and `export const MAX_REVIEWS_IGNORE = 50` in `src/shared/settings.ts`. An entry is trimmed and lower-cased. Duplicates go.
- Produces: `SettingsEffect` gets `{ kind: 'reviews'; on: boolean }` (when `reviewsWatch` changes) and `{ kind: 'reviews-view' }` (when `reviewsTeamRequests` or `reviewsIgnore` changes).
- Produces: `ExecFn` options get `maxBuffer?: number`. `execFile` passes it to Node. The default stays the Node default.

- [ ] **Step 1: Write the failing tests**
  - `settings.test.ts`: the full `DEFAULT_SETTINGS` object includes the nine keys with the defaults above; `applyPatch` refuses `reviewsMaxSessions: 11` and `reviewsPauseMinutes: 45` with `'refused: bad <key>'`; `parseSettings` gives `[]` for `reviewsIgnore: 'x'`; the ignore parse keeps `['acme/api', 'acme/*']` from `[' Acme/API ', 'acme/*', 'acme/api', 'bad']`.
  - `effects.test.ts`: `reviewsWatch` false to true gives `[{ kind: 'reviews', on: true }]`; a change of `reviewsIgnore` gives `[{ kind: 'reviews-view' }]`; a change of `reviewsMaxSessions` gives no Reviews effect.
  - `cli.test.ts`: `execFile` with `maxBuffer: 16` on a command that prints 64 bytes gives `code: 1` and a `stderr` that names the limit.
- [ ] **Step 2: Run** `pnpm vitest run test/shared/settings.test.ts test/main/settings/effects.test.ts test/main/claude/cli.test.ts`. Expected: FAIL.
- [ ] **Step 3: Implement** the keys, the list parse (`parseReviewsIgnore(value: unknown): string[]`, `checkReviewsIgnore(value: unknown): boolean`), the branch in `checkField` and `parseSettings`, the two effect kinds, and `maxBuffer`. In `ipc.ts` `runSettingsEffect`, add the two kinds as calls that do nothing yet (Task 5 fills them).
- [ ] **Step 4: Run** the three files, then `pnpm typecheck` and `pnpm check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(settings): add the Reviews settings and the Watch GitHub effect`.

### Task 2: The GitHub reader

**Files:**
- Create: `src/shared/reviews.ts`, `src/main/reviews/gh.ts`, `src/main/reviews/pr-data.ts`, `src/main/reviews/query.ts`
- Create: `test/fixtures/reviews/poll-basic.json`, `test/fixtures/reviews/poll-truncated.json`
- Test: `test/main/reviews/gh.test.ts`, `test/main/reviews/query.test.ts`

**Interfaces:**
- Produces in `src/shared/reviews.ts` (used by main and renderer):
  - `export const PR_KEY = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}#[1-9][0-9]{0,9}$/`
  - `export function prKey(owner: string, repo: string, number: number): string` gives `owner/repo#number`.
  - `export const COPILOT_LOGIN = 'copilot-pull-request-reviewer'`
  - `export const TRUSTED_ASSOCIATIONS: readonly string[] = ['OWNER', 'MEMBER', 'COLLABORATOR']`
  - `export type ReviewsAvailability = 'off' | 'starting' | 'ok' | 'no-gh' | 'logged-out' | 'error'`
  - `export type ToReviewState = 'new' | 'draft-ready' | 'waiting' | 'reviewing' | 'queued' | 'paused' | 'approved-by-others' | 'team'`
  - `export type ReviewStatus = 'changes-requested' | 'comments' | 'approved' | 'pending'`
  - `export type ClaudeState = 'needs-you' | 'fixing' | 'queued' | 'trust-needed' | 'cloning' | 'waiting' | 'error'`
  - `export interface ToReviewRow { key: string; owner: string; repo: string; number: number; title: string; author: string; additions: number; deletions: number; requestedAt: number; state: ToReviewState; flash: boolean; pauseEndsAt: number | null; sessionId: string | null }`
  - `export interface MyPrRow { key: string; owner: string; repo: string; number: number; title: string; status: ReviewStatus; reviewers: string[]; failedChecks: number; laterCopilot: number; olderOpen: number; claude: ClaudeState; fixing: number; error: string | null; sessionId: string | null; updatedAt: number }`
  - `export interface TrustNeed { repo: string; waiting: number }`
  - `export interface ReviewsSnapshot { availability: ReviewsAvailability; message: string | null; polledAt: number | null; toReview: ToReviewRow[]; mine: MyPrRow[]; trust: TrustNeed[] }`
  - `export const EMPTY_REVIEWS: ReviewsSnapshot` (availability `'off'`, all lists empty, `polledAt: null`, `message: null`).
  - The friendly texts: `REASON_GH_MISSING = "GitHub CLI (gh) isn't installed."`, `REASON_GH_LOGGED_OUT = "GitHub CLI (gh) isn't logged in. Run gh auth login in a terminal, then click Refresh."`, `REASON_GH_TIMEOUT = "GitHub didn't answer in time. Bifrost will try again."`.
- Produces in `src/main/reviews/pr-data.ts` (main only):
  - `export interface Author { login: string; bot: boolean; association: string }`
  - `export interface PrComment { id: string; databaseId: number; author: Author; body: string; createdAt: number }`
  - `export interface PrThread { id: string; isResolved: boolean; path: string; line: number | null; reviewId: string | null; comments: PrComment[] }` (`reviewId` is the review of the first comment)
  - `export type ReviewState = 'APPROVED' | 'CHANGES_REQUESTED' | 'COMMENTED' | 'DISMISSED' | 'PENDING'`
  - `export interface PrReview { id: string; databaseId: number; author: Author; state: ReviewState; body: string; submittedAt: number | null; commit: string | null }`
  - `export interface PrData { key: string; owner: string; repo: string; number: number; title: string; url: string; author: string; isDraft: boolean; additions: number; deletions: number; createdAt: number; updatedAt: number; reviewDecision: 'APPROVED' | 'CHANGES_REQUESTED' | 'REVIEW_REQUIRED' | null; requestedUsers: string[]; requestedTeams: string[]; requestedAt: number; reviews: PrReview[]; threads: PrThread[]; comments: PrComment[]; failedChecks: number; headRef: string; headSha: string; baseRef: string; isCrossRepository: boolean; viewerPendingReviewId: string | null; truncated: boolean }`
  - `export interface PollData { viewer: string; toReview: PrData[]; mine: PrData[] }`
- Produces in `src/main/reviews/gh.ts`:
  - `export const GH_TIMEOUT_MS = 30_000`, `export const GH_MAX_BUFFER = 16 * 1024 * 1024`
  - `export interface Gh { run(args: string[], opts?: { cwd?: string; timeoutMs?: number }): Promise<ExecResult> }`
  - `export function createGh(deps: { exec: ExecFn; env(): Promise<Record<string, string>> }): Gh` (runs the bare name `gh` with the given env, `GH_TIMEOUT_MS`, `GH_MAX_BUFFER`).
  - `export type GhFailure = { availability: 'no-gh' | 'logged-out' | 'error'; message: string }`
  - `export function ghFailure(result: ExecResult): GhFailure | null` (`null` for code 0). `ENOENT` gives `no-gh`. Exit code 4, or stderr with `gh auth login`, gives `logged-out`. `timedOut` gives `error` with `REASON_GH_TIMEOUT`. Else `error` with the first stderr line, cut at 200 characters.
- Produces in `src/main/reviews/query.ts`:
  - `export const POLL_QUERY: string` (one query: `viewer { login }`, `rateLimit { cost remaining }`, and the two searches of R1-1 with one PR fragment; the fragment reads every field of `PrData`, with `reviewThreads(first: 100)`, `comments(first: 50)` in each thread, `comments(last: 100)` on the PR, `reviews(first: 100)`, `reviews(states: PENDING, first: 1)`, the newest 20 `REVIEW_REQUESTED_EVENT` timeline items, and the check contexts of the last commit, each with `pageInfo { hasNextPage }`).
  - `export function pollArgs(): string[]` gives `['api', 'graphql', '-f', 'query=' + POLL_QUERY]`.
  - `export function parsePoll(stdout: string): { ok: true; data: PollData } | { ok: false; message: string }`
  - `export function countFailed(contexts: unknown[]): number` (a `CheckRun` with conclusion `FAILURE`, `TIMED_OUT`, `CANCELLED`, `STARTUP_FAILURE` or `ACTION_REQUIRED`; a `StatusContext` with state `FAILURE` or `ERROR`).

- [ ] **Step 1: Write the fixtures.** Hand-made GraphQL answers in the shape of the spike report. `poll-basic.json`: viewer `dev-user`; To review: one direct request, one team request, one PR with `reviewDecision: APPROVED`; My PRs: one PR with a `CHANGES_REQUESTED` review from a `MEMBER`, one unresolved thread from Copilot (`__typename: Bot`, login `copilot-pull-request-reviewer`, association `NONE`), one failed `CheckRun`; one PR with an `APPROVED` review and no open thread. `poll-truncated.json`: one PR with `reviewThreads.pageInfo.hasNextPage: true`.
- [ ] **Step 2: Write the failing tests**
  - `gh.test.ts`: `createGh` calls exec with `('gh', args, { env, timeoutMs: 30000, maxBuffer: 16777216 })`; `ghFailure` maps `{ code: 1, stderr: 'spawn gh ENOENT' }` to `no-gh`, `{ code: 4, stderr: '' }` to `logged-out`, `{ code: 1, timedOut: true }` to `REASON_GH_TIMEOUT`, and a long stderr to its first 200 characters.
  - `query.test.ts`: `parsePoll(poll-basic)` gives viewer `dev-user`, 3 To review PRs and 2 My PRs; the Copilot author is `{ login: 'copilot-pull-request-reviewer', bot: true, association: 'NONE' }`; the team PR has `requestedUsers` without `dev-user`; `failedChecks` is 1; `requestedAt` is the newest request event time; `parsePoll(poll-truncated)` sets `truncated: true`; `parsePoll('not json')` and an answer with `errors` give `ok: false`; `countFailed` counts the six failure kinds and ignores `SUCCESS` and `NEUTRAL`.
- [ ] **Step 3: Run** the two test files. Expected: FAIL.
- [ ] **Step 4: Implement** the three modules. `parsePoll` checks each field and drops a PR that lacks a key field (owner, repo, number, url). Times are milliseconds since the epoch.
- [ ] **Step 5: Run** the two files, `pnpm typecheck`, `pnpm check`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(reviews): read the review requests and the own PRs from gh`.

### Task 3: The Reviews state store

**Files:**
- Create: `src/main/reviews/state.ts`, `src/main/reviews/state-store.ts`
- Test: `test/main/reviews/state.test.ts`, `test/main/reviews/state-store.test.ts`

**Interfaces:**
- Produces in `state.ts`:
  - `export interface SessionRef { sessionId: string; name: string }`
  - `export interface PrState { handled: Record<string, { at: number; lastReplyAt: number | null }>; firstCopilotReview: string | null; lastReviewedCommit: string | null; request: SessionRef | null; review: SessionRef | null; handleOlder: boolean; handleCopilot: boolean; rerequested: Record<string, string>; lastError: string | null }`
  - `export interface PostedComment { id: string; prKey: string; body: string; at: number }`
  - `export interface DraftComment { reviewId: string; prKey: string; path: string; line: number; body: string; at: number }`
  - `export interface VoicePair { prKey: string; draft: string; final: string; at: number }`
  - `export interface ReviewsState { version: 1; turnedOnAt: number | null; baseline: string[]; requests: Record<string, { firstSeen: number; baseline: boolean }>; pauses: Record<string, number>; prs: Record<string, PrState>; posted: PostedComment[]; drafts: DraftComment[]; voicePairs: VoicePair[] }`
  - `export const EMPTY_STATE: ReviewsState`, `export function emptyPrState(): PrState`
  - `export const MAX_POSTED = 2000`, `export const MAX_DRAFTS = 2000`, `export const MAX_VOICE_PAIRS = 1000` (the oldest go first)
  - `export function parseState(data: unknown): ReviewsState` (checks each field; a bad field gets its empty value; a key that fails `PR_KEY` goes; version other than 1 gives `EMPTY_STATE`)
- Produces in `state-store.ts`:
  - `export interface ReviewsStateStore { get(): ReviewsState; change(fn: (s: ReviewsState) => ReviewsState): Promise<ReviewsState> }`
  - `export async function openReviewsStateStore(file: string, log?: (m: string) => void): Promise<ReviewsStateStore>` (a queue of writes with `writeJsonAtomic`; the folder gets mode 0700; a file that cannot be read gives `EMPTY_STATE` and no save, as `openStore` in `registry/store-file.ts`)
  - `export function reviewsStateFile(bifrostHome: string): string` gives `<bifrostHome>/reviews/state.json`.

- [ ] **Step 1: Write the failing tests:** `parseState` keeps a valid state, drops a bad PR key, caps `posted` at `MAX_POSTED` keeping the newest, and gives `EMPTY_STATE` for `{ version: 2 }`; the store writes the file, makes the folder with mode 0700, runs two `change` calls in order, and does not save after a read error (a folder in the place of the file).
- [ ] **Step 2: Run** both files. Expected: FAIL.
- [ ] **Step 3: Implement** both modules.
- [ ] **Step 4: Run** both files, `pnpm typecheck`, `pnpm check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(reviews): keep the Reviews state in ~/.bifrost/reviews`.

### Task 4: The Reviews model (pure)

**Files:**
- Create: `src/main/reviews/model.ts`, `src/shared/reviews-order.ts`
- Test: `test/main/reviews/model.test.ts`, `test/shared/reviews-order.test.ts`

**Interfaces:**
- Consumes: `PrData`, `PollData`, `Author` (Task 2), `ReviewsState` and `PrState` (Task 3).
- Produces in `model.ts`:
  - `export function isCopilot(a: Author): boolean` (bot and login `COPILOT_LOGIN`)
  - `export function isTrustedHuman(a: Author, viewer: string): boolean` (not a bot, association in `TRUSTED_ASSOCIATIONS`, login not the viewer)
  - `export function firstCopilotReviewId(pr: PrData): string | null` (the Copilot review with the earliest `submittedAt`)
  - `export interface WorkItem { id: string; kind: 'thread' | 'comment' | 'review-body' }`
  - `export interface WorkSplit { work: WorkItem[]; older: WorkItem[]; laterCopilot: WorkItem[] }`
  - `export function splitWork(pr: PrData, viewer: string, prState: PrState, baseline: ReadonlySet<string>): WorkSplit` (design 10.2: unresolved threads whose first comment is from a trusted human or from the first Copilot review; non-empty review bodies and PR comments from trusted humans; items in `prState.handled` are not work unless a trusted human commented after `lastReplyAt`; items in `baseline` go to `older`; Copilot threads of later reviews go to `laterCopilot`; Copilot review bodies and other bots are never work)
  - `export function reviewStatus(pr: PrData, viewer: string, split: WorkSplit): ReviewStatus` (design 9.2; open work counts the unresolved threads of `work` and `older`, and the top-level items of `work`; `laterCopilot` threads never change the status)
  - `export interface RequestContext { now: number; known: { baseline: boolean } | undefined; pauseEndsAt: number | null; teamRequests: boolean; session: 'reviewing' | 'queued' | null }`
  - `export function toReviewState(pr: PrData, viewer: string, ctx: RequestContext): ToReviewState | null` (precedence: session, then `draft-ready` when `viewerPendingReviewId` is set, then `paused` while `now < pauseEndsAt`, then `approved-by-others`, then `team` (or `null` when `teamRequests` is off), then `waiting` for a baseline request, else `new`)
  - `export function isIgnored(owner: string, repo: string, ignore: readonly string[]): boolean`
  - `export interface SnapshotInput { poll: PollData; state: ReviewsState; now: number; settings: Pick<Settings, 'reviewsTeamRequests' | 'reviewsIgnore'>; session(key: string): 'reviewing' | 'queued' | null; claude(key: string): { claude: ClaudeState; fixing: number; error: string | null; sessionId: string | null } }`
  - `export function buildSnapshot(input: SnapshotInput): ReviewsSnapshot` (`availability: 'ok'`; `flash` is `state === 'new'`; reviewers are the requested users and the review authors without the viewer, with Copilot shown as `Copilot`; both lists sorted with `reviews-order.ts`)
  - `export function baselineOf(poll: PollData): { items: string[]; requests: string[] }` (all open work and older item IDs of My PRs, and all To review keys; a truncated PR adds no items)
- Produces in `src/shared/reviews-order.ts`:
  - `export const TO_REVIEW_ORDER: readonly ToReviewState[] = ['new', 'draft-ready', 'waiting', 'reviewing', 'queued', 'paused', 'approved-by-others', 'team']`
  - `export const MINE_ORDER: readonly ReviewStatus[] = ['changes-requested', 'comments', 'pending', 'approved']`
  - `export function sortToReview(rows: ToReviewRow[]): ToReviewRow[]` (group order above; inside a group the oldest `requestedAt` first; `paused` by the earliest `pauseEndsAt`)
  - `export function sortMine(rows: MyPrRow[]): MyPrRow[]` (`claude === 'needs-you'` first, then `MINE_ORDER`, then the newest `updatedAt`)

- [ ] **Step 1: Write the failing tests** in `model.test.ts`, one `it` for each rule, with small `PrData` builders:
  - `a MEMBER thread is work and an outsider thread is not`
  - `only the first Copilot review gives work; later Copilot threads count as laterCopilot`
  - `a handled thread is work again only after a trusted comment newer than lastReplyAt`
  - `the viewer's own comments are never work`
  - `an empty review body is not work, a CHANGES_REQUESTED body from a MEMBER is`
  - `baseline items go to older`
  - `reviewStatus: changes requested wins over open threads`
  - `reviewStatus: open Copilot thread gives comments, Copilot approval never gives approved`
  - `reviewStatus: an open thread of a later Copilot review alone gives pending, not comments`
  - `reviewStatus: approved with all threads resolved gives approved; no reviewer gives pending`
  - `toReviewState: precedence session > draft-ready > paused > approved-by-others > team > waiting > new`
  - `toReviewState: a team request is null when teamRequests is off`
  - `isIgnored matches owner/* and owner/repo, case-insensitive`
  - `buildSnapshot: an ignored repo shows in neither list`
  - `does not add items of a truncated PR to the baseline`
- [ ] **Step 2: Write the failing tests** in `reviews-order.test.ts`: `sortToReview` gives the group order of `TO_REVIEW_ORDER` and the oldest request first in a group; `sortMine` puts `needs-you` first, then the status order, then the newest update.
- [ ] **Step 3: Run** both files. Expected: FAIL.
- [ ] **Step 4: Implement** both modules as pure functions with no I/O.
- [ ] **Step 5: Run** both files, `pnpm typecheck`, `pnpm check`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(reviews): compute the review status, the work and the row order`.

### Task 5: The watcher, its IPC and the notification

**Files:**
- Create: `src/main/reviews/watcher.ts`
- Modify: `src/main/ipc.ts`, `src/shared/api.ts`, `src/preload/index.ts`, `src/renderer/src/actions/errors.ts`
- Test: `test/main/reviews/watcher.test.ts`

**Interfaces:**
- Consumes: `Gh`, `ghFailure`, `pollArgs`, `parsePoll` (Task 2); `ReviewsStateStore` (Task 3); `buildSnapshot`, `baselineOf`, `toReviewState` (Task 4).
- Produces in `watcher.ts`:
  - `export const POLL_DEADLINE_MS = 60_000`, `export const REFRESH_GAP_MS = 5_000`
  - `export const REFUSED_UNKNOWN_PR = 'refused: unknown pull request'`, `export const REFUSED_REVIEWS_OFF = 'refused: reviews are off'`
  - `export interface WatcherDeps { gh: Gh; store: ReviewsStateStore; settings(): Pick<Settings, 'reviewsTeamRequests' | 'reviewsIgnore' | 'reviewsPollMinutes' | 'reviewsPauseMinutes'>; now(): number; emit(s: ReviewsSnapshot): void; notifyRequest(row: ToReviewRow): void; log(m: string): void }`
  - `export interface ReviewsWatcher { start(): void; stop(): void; requestPoll(): void; rebuild(): void; current(): ReviewsSnapshot; pause(key: string): Promise<void>; endPause(key: string): Promise<void>; urlOf(key: string): string | null }`
  - `export function createReviewsWatcher(deps: WatcherDeps): ReviewsWatcher`
- Behaviour:
  - Shape as `account-usage/poller.ts`: a generation counter, a `busy` flag, `POLL_DEADLINE_MS`, the next poll `reviewsPollMinutes` after the end of a poll, `requestPoll` with `REFRESH_GAP_MS`. `start` emits `availability: 'starting'` and polls at once. `stop` emits `EMPTY_REVIEWS` (`'off'`).
  - After a good poll: if `turnedOnAt` is null, write the baseline (`baselineOf`) and `turnedOnAt`. Update `requests`: add each new To review key with `baseline: false` and `firstSeen: now`; remove each key that is gone; remove ended pauses. Save once. Build and emit the snapshot.
  - A failed poll emits the last snapshot with the new `availability` and `message`, and does not change the state.
  - `notifyRequest` runs for each To review row that is `new` and whose key was not in `requests` before this poll. Not for the first poll after the first turn-on, and not for a pause that ended.
  - `pause(key)` sets `pauses[key] = now + reviewsPauseMinutes * 60_000`, saves, rebuilds. `endPause(key)` removes it. Both refuse a key that is not in the current snapshot with `REFUSED_UNKNOWN_PR`.
  - `rebuild()` builds the snapshot again from the last poll data, with no `gh` call.
  - `urlOf(key)` gives the PR URL from the last poll, only when it starts with `https://github.com/`.
- Produces in `api.ts` (`BifrostApi`): `reviews: { snapshot(): Promise<ReviewsSnapshot>; onUpdate(cb: (s: ReviewsSnapshot) => void): () => void; refresh(): Promise<void>; pause(key: string): Promise<void>; endPause(key: string): Promise<void>; openPr(key: string): Promise<void>; onOpen(cb: () => void): () => void }`. Channels: `reviews:snapshot`, `reviews:update`, `reviews:refresh`, `reviews:pause`, `reviews:end-pause`, `reviews:open-pr`, `reviews:open`.
- Wiring in `ipc.ts`: create the watcher inside `registerIpc` after `paths` and `settings`, with `createGh({ exec: execFile, env: async () => childEnv(await loginEnv, { pty: false }) })` and the store at `reviewsStateFile(paths.bifrostHome)`. Start it when `reviewsWatch` is on (at settings open, and on the `reviews` effect). Run `rebuild` on `reviews-view`. Stop it in `stopRegistry()`. `notifyRequest` shows a notification (title `<repo> #<number>`, body `"<author> asked for your review: <title>"`) only when `settings.notifications` is on and the window is not focused; its click shows the window and sends `reviews:open` (keep one pending open for a page that is not loaded yet, as `PendingOpen` does for a session). Each `reviews:*` handler refuses with `REFUSED_REVIEWS_OFF` while the watcher is off, except `reviews:snapshot`.
- `errors.ts`: friendly texts for the two new codes ("That pull request isn't in the list any more." and "Turn on Watch GitHub in Settings first.").

- [ ] **Step 1: Write the failing tests** in `watcher.test.ts` with fake timers, a fake `Gh` that returns fixture answers in order, and an in-memory store:
  - `the first poll writes the baseline and nothing flashes`
  - `a new request after the baseline flashes and notifies once`
  - `a request that is known after a restart does not flash` (a store with `requests` from an earlier run)
  - `a request that comes back flashes and notifies`
  - `pause stops the flash and the end of the pause brings it back`
  - `an ended pause flashes again without a notification`
  - `keeps the last snapshot when a poll fails` (logged out, then timeout; the state file is the same)
  - `stop clears the timer and a late answer of an old generation emits nothing`
  - `pause refuses an unknown key`
  - `urlOf gives only https://github.com/ URLs`
- [ ] **Step 2: Run** the file. Expected: FAIL.
- [ ] **Step 3: Implement** `watcher.ts`, then the wiring, the API, the preload and the friendly texts.
- [ ] **Step 4: Run** `pnpm test`, `pnpm typecheck`, `pnpm check`. Expected: PASS (the `errors.test.ts` source test finds the two new codes).
- [ ] **Step 5: Commit** `feat(reviews): poll GitHub in the background and notify new review requests`.

### Task 6: The Reviews panel

**Files:**
- Create: `src/renderer/src/reviews/use-reviews.ts`, `src/renderer/src/reviews/ReviewsPanel.tsx`, `src/renderer/src/reviews/ReviewRow.tsx`, `src/renderer/src/reviews/row-text.ts`
- Modify: `src/renderer/src/wm/state.ts`, `src/renderer/src/panels/panels.tsx`, `src/renderer/src/wm/SideBar.tsx`, `src/renderer/src/actions/actions-context.tsx` (the `reviews.onOpen` route), `test/renderer/theme.test.ts` (box token allow list)
- Test: `test/renderer/reviews/row-text.test.ts`, `test/renderer/wm/state.test.ts`, `test/renderer/reviews/reviews-panel-source.test.ts`

**Interfaces:**
- Consumes: `window.bifrost.reviews` (Task 5), `ReviewsSnapshot` and the row types (Task 2), `useSettings`, `useActions().run('open', id)`, `Tip`, `MENU_*`, `cx`, `ErrorLine`, `NoticeLine`, `useSettingsNav().open(section)`.
- Produces:
  - `PanelKind` gets `'reviews'`. Panel ID `reviews`. `DEFAULT_SIZES.reviews = { h: 420, w: 480 }`. `panelTitle` gives `Reviews`.
  - A side bar button with the lucide icon `GitPullRequest`, label `Reviews`, and a dot while one or more To review rows flash.
  - `export function useReviews(): ReviewsSnapshot` (subscribe first, then `snapshot()`, as `ServiceStatusPanel.tsx:154-171`).
  - `row-text.ts`: `export function ageText(ms: number): string` (`15m ago`, `2h ago`, `3d ago`, `just now` under 1 minute), `export function sizeText(add: number, del: number): string` (`+184 −22` with U+2212), `export function toReviewText(row: ToReviewRow, now: number): string` (`Draft ready`, `Waiting for you`, `Reviewing`, `Queued`, `Paused 42m`, `Approved by others`, `Team request`; `new` shows the buttons instead), `export function statusText(s: ReviewStatus): string` (`Changes requested`, `Comments`, `Approved`, `Pending`), `export function claudeText(row: MyPrRow): string` (`Needs you`, `Fixing 3`, `Queued`, `Trust needed`, `Cloning`, `Waiting`, `Error`), `export function laterCopilotText(n: number): string | null` (`Copilot: 3 more`, `null` for 0).
- Behaviour (design sections 8, 9 and 13; the mockup `.superpowers/brainstorm/74668-1794218564/content/reviews-layout-v2.html` in the main checkout):
  - Tabs `To review` and `My PRs` in the Settings tab style, each with a count. The count is `text-box-red` while a To review row flashes, or while a My PRs row is `needs-you`.
  - Two lines for each row. Line 1: repo, `#number`, title (truncated), a `team` tag for a team request, and on My PRs a red `✕` with a `Tip` "N checks failed" when `failedChecks > 0`. Line 2 as in the design.
  - The flash is an overlay `<span aria-hidden>` with `animate-box-flash bg-box-red/35`, shown when `row.flash && settings.rowFlash`. The text stays solid.
  - `Review` (disabled in R1, `Tip` "Coming soon") and `Pause` buttons on a `new` row. A Refresh button at the right of the tab row.
  - A click on a row with a `sessionId` runs `run('open', sessionId)`; else it does nothing. Cmd+click runs `reviews.openPr(key)`.
  - A right-click menu with the items that apply: Open on GitHub, Pause (a `new` row), End pause now (a `paused` row).
  - States: `off` shows "Reviews is off. Turn on Watch GitHub in Settings to see your pull requests." with a button that opens Settings on the Reviews section (Task 7); `starting` shows "Checking GitHub…"; `no-gh` and `logged-out` show the message; `error` keeps the rows and shows an `ErrorLine`. An empty tab shows "Nothing needs you here." 
  - `reviews.onOpen` opens the `reviews` panel and selects the To review tab.

- [ ] **Step 1: Write the failing tests:** `row-text.test.ts` for each text function (exact strings above); `state.test.ts`: `panelKind('reviews')` is `'reviews'` with size 480 by 420; `reviews-panel-source.test.ts` reads `ReviewsPanel.tsx` and `ReviewRow.tsx` and checks that the flash class sits on an `aria-hidden` overlay, that it reads `settings.rowFlash`, and that `metaKey` leads to `openPr`.
- [ ] **Step 2: Run** the three files. Expected: FAIL.
- [ ] **Step 3: Implement** the panel, the registration, the side bar button and the route. Add `reviews/ReviewRow.tsx` and `reviews/ReviewsPanel.tsx` to the box token allow list in `theme.test.ts`.
- [ ] **Step 4: Run** `pnpm test`, `pnpm typecheck`, `pnpm check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(reviews): add the Reviews panel with two tabs`.

### Task 7: The Reviews section in Settings

**Files:**
- Create: `src/renderer/src/settings/rows.tsx`, `src/renderer/src/settings/ReviewsSection.tsx`
- Modify: `src/renderer/src/settings/GeneralSection.tsx`, `settings-nav.tsx`, `SettingsPanel.tsx`, `search.ts`, `general-rows.ts` (or a new `reviews-rows.ts` with `REVIEWS_ROWS`)
- Test: `test/renderer/settings/search.test.ts`, `test/renderer/settings/search-rows.test.ts`, `test/renderer/settings/general-section.test.ts`, `test/renderer/settings/reviews-section-source.test.ts`

**Interfaces:**
- Produces: `SettingsSection` gets `'reviews'`. `TABS` is `['general', 'slash', 'keys', 'reviews', 'live']`. Section title `Reviews`.
- Produces: `export const REVIEWS_ROWS = { watch: 'Watch GitHub', autoFix: 'Handle comments on my PRs automatically', teamRequests: 'Show team requests', maxSessions: 'Maximum PR sessions', pauseTime: 'Pause time', pollInterval: 'GitHub poll interval', requestModel: 'Model for request sessions', reviewModel: 'Model for review sessions', ignore: 'Repositories to ignore' } as const` in `src/renderer/src/settings/reviews-rows.ts`. The search index lists them.
- Produces: `CheckRow`, `NumberRow`, `SelectRow` exported from `settings/rows.tsx` (R1-6).
- Behaviour:
  - The first turn-on of Watch GitHub (with `reviewsWatch` false) asks with `useConfirm` before it saves. The text says, in friendly English: Bifrost uses your `gh` login to read your review requests and your PRs every few minutes; later versions can start Claude sessions that reply on your PRs and write draft reviews; nothing is posted until those parts are on. Buttons "Turn on" and "Cancel".
  - "Handle comments on my PRs automatically" shows with the hint "Comes in a later version." and stays saved, but has no effect in R1.
  - The model selects show `Claude Code default`, `Opus`, `Sonnet`, `Haiku`.
  - Pause time shows `15 minutes` to `8 hours`. Poll interval shows `1`, `2`, `5`, `10 minutes`.
  - The ignore list works as the slash command list: a field with placeholder `owner/repo or owner/*`, an Add button, a Remove button on each entry, and the friendly error "Use owner/repo or owner/*." for a bad entry.
  - The section has a `RowFilterContext` provider, so the search shows only the matching rows.

- [ ] **Step 1: Write the failing tests:** `search.test.ts` expects five sections with the titles; a search for `team` finds `Show team requests`; `search-rows.test.ts` and `general-section.test.ts` get the new counts after the move (count the `useRowSave(` calls in `rows.tsx` and in each section); `reviews-section-source.test.ts` checks that each row label comes from `REVIEWS_ROWS` and that the Watch GitHub row calls `useConfirm` before `update({ reviewsWatch: true })`.
- [ ] **Step 2: Run** the four files. Expected: FAIL.
- [ ] **Step 3: Implement** the move, the section and the search entries.
- [ ] **Step 4: Run** `pnpm test`, `pnpm typecheck`, `pnpm check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(settings): add the Reviews section`.

### Task 8: Smoke test, the read-only live check, and the spec

**Files:**
- Create: `test/smoke/fake-claude/gh`, `test/smoke/fixtures/reviews-1.json`, `test/smoke/fixtures/reviews-2.json`, `test/smoke/reviews.spec.ts`, `scripts/reviews/check-reader.ts`
- Modify: `docs/specs/2026-11-04-bifrost-design.md` (sections 5.3, 8.2, 10, 12), `docs/specs/2026-11-09-bifrost-reviews-design.md` (status line: "R1 built")

**Interfaces:**
- Consumes: everything above.
- The fake `gh` answers only `api graphql -f query=...` (match `"$1 $2 $3"` = `api graphql -f`). It returns `reviews-1.json` on the first call and `reviews-2.json` on each later call (a counter file in `$BIFROST_TEST_HOME`). `reviews-2.json` adds one direct request. It also answers the Show Info call `pr view --json number,title,url,state` with exit 1 and `no pull requests found`. Each other call goes to `unknown.log` and exits 2.
- `scripts/reviews/check-reader.ts`: runs `createGh` and `parsePoll` against the real `gh` (read only, one query), and prints only counts: viewer login, To review count (direct, team, approved by others), My PRs count, PRs with failed checks, the GraphQL cost. It prints no title, no body and no token. Run with `node scripts/reviews/check-reader.ts`.

- [ ] **Step 1: Write the smoke spec** `reviews.spec.ts`. Its steps:
  1. Start the app with the test home.
  2. Open Settings > Reviews. Turn on Watch GitHub and accept the confirm.
  3. Open the Reviews panel from the side bar. Expect the To review rows of `reviews-1.json`, with no flash.
  4. Click Refresh. Expect one new row with the flash overlay and a red tab count.
  5. Open My PRs. Expect the status words and one `✕`.
  6. Expect an empty `unknown.log` and unchanged `realFiles()`.

  Do not test Cmd+click, because it opens a browser.
- [ ] **Step 2: Run** `pnpm smoke`. Expected: FAIL until the fake `gh` and fixtures exist, then PASS.
- [ ] **Step 3: Write and run** `check-reader.ts`. Expected: the counts print and match the spike counts within the changes since 2026-11-09 (about 25 direct requests, 2 own PRs). Put the printed counts in the task report.
- [ ] **Step 4: Update the main spec:** a `Reviews` row in the panel table (8.2); the Reviews settings rows in section 12; the new request notification in section 10; `~/.bifrost/reviews/` in section 5.3. Point to the Reviews design. Run the STE checker on the changed sections.
- [ ] **Step 5: Run** `pnpm test`, `pnpm typecheck`, `pnpm check`, `pnpm smoke`. Expected: PASS.
- [ ] **Step 6: Commit** `test(reviews): add the Reviews smoke test and the reader check` and `docs(spec): describe the Reviews panel in the main spec`.

## Exit check for R1

- All checks pass on the branch: `pnpm test`, `pnpm typecheck`, `pnpm check`, `pnpm smoke`.
- `check-reader.ts` prints sensible counts from the real GitHub.
- The user turns on Watch GitHub in his own Bifrost after the merge and sees his requests and PRs. The controller does not drive his app.
