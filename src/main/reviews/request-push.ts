// The push of a fix to the head branch of the user's PR. This is the only git write to GitHub.
// The push never uses any form of force, so git refuses each push that is not a fast-forward.
// When the branch moved, Bifrost merges with merge-tree and pushes the merge. It pushes nothing
// on a conflict, and nothing when the user rewrote the branch.
// Each git command names the .git folder of the clone. The session can never write that folder.
// No git command of the push can ask for anything (NO_PROMPT_CONFIG).
//
// With signed commits on, createSignedPusher sends the change of the fix commit to GitHub with
// commitOnBranch (createCommitOnBranch) in place of a git push. GitHub then makes and signs the
// commit. The local fix commit is the source of the change (ruling S21). Bifrost sends the change
// only on a head whose versions of the fix paths are the versions of the head of the round, so
// the change replaces no work of the user (ruling S25).

import { createHash } from 'node:crypto'
import { join } from 'node:path'
import { REPO_KEY } from '../../shared/reviews'
import type { ExecResult } from '../claude/cli'
import type { Gh } from './gh'
import { NO_PROMPT_CONFIG, type RepoGit } from './repo-git'
import { cleanMessage, commitParts, gitFailed, gitReason, OBJECT_ID } from './repo-store'
import { type BranchCommit, commitOnBranch } from './request-writes'
import {
  REASON_PUSH_CONFLICT,
  REASON_PUSH_GIT_FAILED,
  REASON_PUSH_MOVED,
  REASON_PUSH_NEW_BRANCH,
  REASON_PUSH_TARGET,
  REASON_SIGNED_EXECUTABLE,
  REASON_SIGNED_LINK,
  REASON_SIGNED_TOO_LARGE,
  reasonPushFailed,
} from './round-text'

// The most pushes for one fix. Each refused push fetches the branch again before the next one.
export const MAX_PUSH_TRIES = 2
// The largest sum of the files of a signed fix commit, in bytes (ruling S23).
export const MAX_SIGNED_BYTES = 4 * 1024 * 1024
// The most commits that the search for a signed commit on GitHub checks (ruling S26).
export const MAX_LOOKUP_COMMITS = 20
// The most commits that the search reads after the expected head, newest first. When more
// commits came after the head, the search can miss the commit of GitHub. The fix paths then differ
// from the head of the round, so the pusher gives a conflict and sends no second commit.
export const MAX_LOOKUP_RANGE = 1000

// not-landed: nothing of the push is on GitHub. Either git ended the push with an error, or
// GitHub refused the signed commit, and a fetch after it shows that the branch does not have the
// commit. Or the signed pusher refused the change before any write. A refused push can have
// reached GitHub. detail is the raw error text of GitHub for the signed commit, for the Event log
// only.
export type PushOutcome =
  | { ok: true; sha: string; merged: boolean; already: boolean }
  | {
      ok: false
      reason: 'conflict' | 'moved' | 'refused' | 'not-landed'
      message: string
      detail?: string
    }

export interface FixPusher {
  push(o: {
    clone: string
    number: number
    owner: string
    repo: string
    headRef: string
    baseRef: string
    defaultBranch: string
    fix: string
    // True for a PR from a fork. The signed pusher refuses a fork, and a missing value counts as
    // a fork. The git pusher does not read it.
    crossRepository?: boolean
  }): Promise<PushOutcome>
}

type PushInput = Parameters<FixPusher['push']>[0]

// Each git command of the push gets NO_PROMPT_CONFIG.
export { NO_PROMPT_CONFIG }

// A signed push can open a passphrase prompt, and GitHub does not take signed pushes.
const NO_PUSH_SIGN: readonly string[] = ['-c', 'push.gpgSign=false']
const NOT_ON_BRANCH = "the branch on GitHub doesn't have the fix after the push."
// The status of a push that is not a fast-forward, because the branch moved after the fetch.
const LOST_RACE = /\[rejected\]|fetch first|non-fast-forward/
// The porcelain status line of a push that made a new branch.
const NEW_BRANCH = /^\*\t/m

// True when git ended by itself with an error code. A timeout, an abort, a signal or too much
// output also gives an error code, but with a flag. For these, the answer is false.
const exitedWithError = (result: ExecResult): boolean =>
  result.code !== 0 &&
  result.timedOut !== true &&
  result.overflow !== true &&
  result.aborted !== true &&
  result.signal === undefined

// True when git ended by itself with the exit code 1.
const exitOne = (result: ExecResult): boolean => result.code === 1 && exitedWithError(result)

const target = (): PushOutcome => ({ message: REASON_PUSH_TARGET, ok: false, reason: 'refused' })
const failure = (
  line: string,
  reason: 'refused' | 'not-landed' = 'refused',
  detail?: string,
): PushOutcome => ({
  message: reasonPushFailed(line),
  ok: false,
  reason,
  ...(detail === undefined ? {} : { detail }),
})

// A failed git command of the push. The message is a fixed text for the row. detail is the first
// line of the stderr of git, for the Event log only.
class GitError extends Error {
  constructor(
    message: string,
    readonly detail?: string,
  ) {
    super(message)
  }
}

// The error of a failed git command: a fixed text, and the line of git as the detail.
const gitError = (r: ExecResult): GitError => new GitError(REASON_PUSH_GIT_FAILED, gitReason(r))

// The git commands of a push on the clone. Each command names the .git folder of the clone and
// gets NO_PROMPT_CONFIG.
function cloneGit(git: RepoGit, o: PushInput) {
  const run = (
    args: string[],
    config: readonly string[] = [],
    encoding?: 'latin1',
  ): Promise<ExecResult> =>
    git.run([`--git-dir=${join(o.clone, '.git')}`, ...NO_PROMPT_CONFIG, ...config, ...args], {
      cwd: o.clone,
      ...(encoding === undefined ? {} : { encoding }),
    })
  // Run a git command that must not fail. A failure throws its first line of stderr.
  const must = async (args: string[]): Promise<string> => {
    const result = await run(args)
    if (gitFailed(result)) throw gitError(result)
    return result.stdout.trim()
  }
  // True when commit a is an ancestor of commit b, or the same commit.
  const isAncestor = async (a: string, b: string): Promise<boolean> => {
    const result = await run(['merge-base', '--is-ancestor', a, b])
    if (!gitFailed(result)) return true
    if (exitOne(result)) return false
    throw gitError(result)
  }
  // The commit of the head branch on the remote, in a ref of Bifrost.
  const local = `refs/bifrost/remote/${o.number}`
  const fetchBranch = async (): Promise<string> => {
    await must([
      'fetch',
      '--quiet',
      '--no-tags',
      '--',
      'origin',
      `+refs/heads/${o.headRef}:${local}`,
    ])
    const sha = await must(['rev-parse', '--verify', '--quiet', `${local}^{commit}`])
    if (!OBJECT_ID.test(sha)) throw new GitError("the branch on GitHub isn't a commit.")
    return sha
  }
  // Fetch the branch, with one more try after a failed fetch. Give its commit or the error.
  const fetchAgain = async (): Promise<string | GitError> => {
    try {
      return await fetchBranch()
    } catch (first) {
      if (!(first instanceof GitError)) throw first
    }
    try {
      return await fetchBranch()
    } catch (second) {
      if (second instanceof GitError) return second
      throw second
    }
  }
  return { fetchAgain, fetchBranch, isAncestor, must, run }
}

type CloneGit = ReturnType<typeof cloneGit>

export function createFixPusher(deps: { git: RepoGit; remoteBase: string }): FixPusher {
  return {
    async push(o) {
      const { fetchAgain, fetchBranch, isAncestor, must, run } = cloneGit(deps.git, o)

      // The merge commit of the fix and the remote, or null on a conflict. merge-tree and
      // commit-tree need no worktree, and they run no hook. commit-tree never signs.
      const mergeOf = async (remote: string): Promise<string | null> => {
        const tree = await run(['merge-tree', '--write-tree', '--no-messages', o.fix, remote])
        if (exitOne(tree)) return null
        if (gitFailed(tree)) throw gitError(tree)
        const id = tree.stdout.split('\n', 1)[0]?.trim() ?? ''
        if (!OBJECT_ID.test(id)) throw new GitError("git didn't give the merged files.")
        const sha = await must([
          'commit-tree',
          '--no-gpg-sign',
          id,
          '-p',
          o.fix,
          '-p',
          remote,
          '-m',
          `Merge remote-tracking branch 'origin/${o.headRef}'`,
        ])
        if (!OBJECT_ID.test(sha)) throw new GitError("git didn't make the merge commit.")
        return sha
      }

      // Each check of the target runs before any network call.
      const base = await checkTarget(o, deps.remoteBase, run)
      if (base === null) return target()

      try {
        for (let tries = 1; tries <= MAX_PUSH_TRIES; tries++) {
          const remote = await fetchBranch()
          if (await isAncestor(o.fix, remote)) {
            return { already: true, merged: false, ok: true, sha: o.fix }
          }
          // The head commit of the round must still be on the branch. Else the user rewrote the
          // branch, and a merge or a fast-forward would put back what the user removed.
          if (!(await isAncestor(base, remote))) {
            return { message: REASON_PUSH_CONFLICT, ok: false, reason: 'conflict' }
          }
          const merged = !(await isAncestor(remote, o.fix))
          const sha = merged ? await mergeOf(remote) : o.fix
          if (sha === null) return { message: REASON_PUSH_CONFLICT, ok: false, reason: 'conflict' }
          const pushed = await run(
            [
              'push',
              '--porcelain',
              '--no-follow-tags',
              '--recurse-submodules=no',
              'origin',
              `${sha}:refs/heads/${o.headRef}`,
            ],
            NO_PUSH_SIGN,
          )
          const good = !gitFailed(pushed)
          // GitHub deleted the branch after the fetch, for example at the merge of the PR. The
          // push made the branch again, so no reply may say that the fix is on the PR.
          if (good && NEW_BRANCH.test(pushed.stdout)) {
            return { message: REASON_PUSH_NEW_BRANCH, ok: false, reason: 'refused' }
          }
          // A refusal of the server ("[remote rejected]") is not a lost race.
          const lost =
            !good &&
            !pushed.timedOut &&
            !pushed.stdout.includes('[remote rejected]') &&
            LOST_RACE.test(`${pushed.stdout}\n${pushed.stderr}`)
          if (lost) continue
          // The branch on the remote gives the true outcome. A failed push can still have reached
          // the remote, for example at a timeout.
          const why = good ? NOT_ON_BRANCH : REASON_PUSH_GIT_FAILED
          const detail = good ? undefined : gitReason(pushed)
          const after = await fetchAgain()
          if (after instanceof GitError) {
            return good
              ? failure(after.message, 'refused', after.detail)
              : failure(why, 'refused', detail)
          }
          if (await isAncestor(sha, after)) return { already: false, merged, ok: true, sha }
          // git ended with an error of its own, so the push is over, and the branch does not have
          // the commit. A push that git did not end (a timeout) can still reach GitHub later.
          return failure(why, !good && exitedWithError(pushed) ? 'not-landed' : 'refused', detail)
        }
        return { message: REASON_PUSH_MOVED, ok: false, reason: 'moved' }
      } catch (error) {
        if (error instanceof GitError) return failure(error.message, 'refused', error.detail)
        throw error
      }
    },
  }
}

// The mode of a regular file. GitHub gives each file of a signed commit this mode.
const PLAIN_FILE = '100644'
const NO_FILE = '000000'
// The modes of a link and of a submodule.
const LINK_MODES: readonly string[] = ['120000', '160000']
// The ref in the clone that holds the head that the last signed commit of the PR expected. A run
// after a quit or an unknown result looks for the commit of GitHub after this head.
const sentRef = (number: number): string => `refs/bifrost/sent/${number}`

// One change of the fix commit against its parent, from git diff-tree --raw -z.
interface FileChange {
  path: string
  oldMode: string
  newMode: string
  blob: string
  deleted: boolean
}

// The changes of git diff-tree -r -z --raw, or null when the output is not in that form.
function rawChanges(raw: string): FileChange[] | null {
  const parts = raw.split('\0')
  if (parts.at(-1) === '') parts.pop()
  if (parts.length % 2 !== 0) return null
  const changes: FileChange[] = []
  for (let i = 0; i < parts.length; i += 2) {
    const match = /^:(\d{6}) (\d{6}) [0-9a-f]+ ([0-9a-f]+) ([A-Z])\d*$/.exec(parts[i] as string)
    const path = parts[i + 1] as string
    if (match === null || path === '') return null
    const [, oldMode = '', newMode = '', blob = '', status = ''] = match
    changes.push({ blob, deleted: status === 'D', newMode, oldMode, path })
  }
  return changes
}

// The git object ID of a file: SHA-1, or SHA-256 for a SHA-256 repository.
function blobId(bytes: Buffer, length: number): string {
  return createHash(length === 64 ? 'sha256' : 'sha1')
    .update(`blob ${bytes.length}\0`)
    .update(bytes)
    .digest('hex')
}

// The headline and the body of a commit message, as GitHub takes them. GitHub makes the message
// "headline", or "headline", an empty line and "body".
function messageParts(message: string): { headline: string; body: string } {
  const text = cleanMessage(message).replace(/\n$/, '')
  const end = text.indexOf('\n')
  if (end === -1) return { body: '', headline: text }
  return { body: text.slice(end + 1).replace(/^\n/, ''), headline: text.slice(0, end) }
}

// The change of a signed fix commit, without the branch and the head.
type SignedChange = Omit<BranchCommit, 'branch' | 'expectedHeadOid' | 'repository'> & {
  // Each path of the fix: changed, new and deleted files.
  paths: string[]
}

// Read the change of the fix commit against its parent, the head of the round, from the commit
// only (ruling S21). Give a refusal for a file that is not a regular file in the parent or in the
// fix (ruling S22), and for a change over MAX_SIGNED_BYTES (ruling S23). A refusal comes before
// any write.
async function readSignedChange(
  g: CloneGit,
  base: string,
  fix: string,
): Promise<SignedChange | PushOutcome> {
  const listed = await g.run([
    'diff-tree',
    '-r',
    '-z',
    '--raw',
    '--no-renames',
    '--no-abbrev',
    base,
    fix,
  ])
  if (gitFailed(listed)) throw gitError(listed)
  const changes = rawChanges(listed.stdout)
  if (changes === null || changes.length === 0) {
    throw new GitError("git didn't give the changes of the fix.")
  }
  // A delete needs no mode. A link or a submodule, in the parent or in the fix, gets its own text.
  const kept = changes.filter(c => !c.deleted)
  if (kept.some(c => LINK_MODES.includes(c.oldMode) || LINK_MODES.includes(c.newMode))) {
    return { message: REASON_SIGNED_LINK, ok: false, reason: 'not-landed' }
  }
  if (kept.some(c => c.newMode !== PLAIN_FILE || ![NO_FILE, PLAIN_FILE].includes(c.oldMode))) {
    return { message: REASON_SIGNED_EXECUTABLE, ok: false, reason: 'not-landed' }
  }
  const additions: BranchCommit['additions'] = []
  const deletions: BranchCommit['deletions'] = []
  let total = 0
  for (const change of changes) {
    if (change.deleted) {
      deletions.push({ path: change.path })
      continue
    }
    // latin1 keeps each byte. The object ID proves that the bytes are the file of the commit.
    const read = await g.run(['cat-file', 'blob', change.blob], [], 'latin1')
    if (gitFailed(read)) throw gitError(read)
    const bytes = Buffer.from(read.stdout, 'latin1')
    if (blobId(bytes, change.blob.length) !== change.blob) {
      throw new GitError("git didn't give the files of the fix.")
    }
    total += bytes.length
    if (total > MAX_SIGNED_BYTES) {
      return { message: REASON_SIGNED_TOO_LARGE, ok: false, reason: 'not-landed' }
    }
    additions.push({ contents: bytes.toString('base64'), path: change.path })
  }
  const parts = messageParts(commitParts(await g.must(['cat-file', 'commit', fix])).message)
  return {
    additions,
    body: parts.body,
    deletions,
    headline: parts.headline,
    paths: changes.map(c => c.path),
  }
}

// The pusher of signed commits. It sends the change of the fix commit to GitHub, which makes and
// signs the commit. The commit of GitHub has the head that the clone fetched as its parent. It
// never uses force. Its outcomes are the outcomes of the git pusher (ruling S28).
export function createSignedPusher(deps: { git: RepoGit; gh: Gh; remoteBase: string }): FixPusher {
  return {
    async push(o) {
      const g = cloneGit(deps.git, o)
      // Each check of the target runs before any network call (ruling S27).
      const base = await checkTarget(o, deps.remoteBase, g.run)
      if (base === null || o.crossRepository !== false) return target()
      const conflict: PushOutcome = { message: REASON_PUSH_CONFLICT, ok: false, reason: 'conflict' }
      const sent = sentRef(o.number)
      try {
        const change = await readSignedChange(g, base, o.fix)
        if ('ok' in change) return change
        const { paths } = change
        // True when one or more paths of the fix differ between the two commits.
        const touched = async (a: string, b: string): Promise<boolean> => {
          const args = ['diff-tree', '-r', '-z', '--no-renames', '--name-only', a, b, '--']
          return (await g.must(['--literal-pathspecs', ...args, ...paths])) !== ''
        }
        // The commit of GitHub for this fix on the branch, or null (ruling S26). It is a child of
        // the head that the last call expected, after the head of the round. The proof is the
        // content only: for each path of the fix, it has the file of the fix commit, and a
        // deleted path is absent. The message does not count.
        const landed = async (remote: string): Promise<string | null> => {
          const from = await g.run(['rev-parse', '--verify', '--quiet', `${sent}^{commit}`])
          if (exitOne(from)) return null
          if (gitFailed(from)) throw gitError(from)
          const expected = from.stdout.trim()
          // A head from before the head of the round is from the call of an earlier fix.
          if (!OBJECT_ID.test(expected) || !(await g.isAncestor(base, expected))) return null
          const list = await g.must([
            'rev-list',
            '--ancestry-path',
            '--parents',
            `--max-count=${MAX_LOOKUP_RANGE}`,
            `${expected}..${remote}`,
          ])
          const children = list
            .split('\n')
            .map(line => line.trim().split(' '))
            .filter(ids => ids.length === 2 && ids[1] === expected)
            .map(ids => ids[0] as string)
            .slice(0, MAX_LOOKUP_COMMITS)
          for (const sha of children) {
            if (!(await touched(o.fix, sha))) return sha
          }
          return null
        }
        // True when the branch holds the commit.
        const contains = async (branch: string, sha: string): Promise<boolean> => {
          if (gitFailed(await g.run(['cat-file', '-e', `${sha}^{commit}`]))) return false
          return g.isAncestor(sha, branch)
        }
        const pr = {
          baseRef: o.baseRef,
          crossRepository: o.crossRepository,
          defaultBranch: o.defaultBranch,
          headRef: o.headRef,
          owner: o.owner,
          repo: o.repo,
        }

        for (let tries = 1; tries <= MAX_PUSH_TRIES; tries++) {
          const remote = await g.fetchBranch()
          // A run after a quit or an unknown result: the commit can be on GitHub already.
          const found = await landed(remote)
          if (found !== null) return { already: true, merged: false, ok: true, sha: found }
          // The head of the round must still be on the branch, and no fix path may differ.
          // Else the change could replace work of the user.
          if (!(await g.isAncestor(base, remote)) || (await touched(base, remote))) return conflict
          await g.must(['update-ref', sent, remote])
          const r = await commitOnBranch(deps.gh, pr, {
            additions: change.additions,
            body: change.body,
            branch: o.headRef,
            deletions: change.deletions,
            expectedHeadOid: remote,
            headline: change.headline,
            repository: `${o.owner}/${o.repo}`,
          })
          // The guard sent nothing.
          if (!r.ok && r.message === REASON_PUSH_TARGET) return target()
          // The branch on GitHub gives the true outcome.
          const after = await g.fetchAgain()
          if (r.ok) {
            if (after instanceof GitError) return failure(after.message, 'refused', after.detail)
            if (await contains(after, r.value.oid)) {
              return { already: false, merged: false, ok: true, sha: r.value.oid }
            }
            return failure(NOT_ON_BRANCH)
          }
          if (after instanceof GitError) return failure(r.message, 'refused', r.detail)
          const made = await landed(after)
          if (made !== null) return { already: false, merged: false, ok: true, sha: made }
          // GitHub can still make the commit after a timeout, so the outbox stays.
          if (r.unknown) return failure(r.message, 'refused', r.detail)
          // GitHub refused. A branch that moved gets one more try on its new head (ruling S25).
          if (after !== remote) continue
          return failure(r.message, 'not-landed', r.detail)
        }
        return { message: REASON_PUSH_MOVED, ok: false, reason: 'moved' }
      } catch (error) {
        if (error instanceof GitError) return failure(error.message, 'refused', error.detail)
        throw error
      }
    },
  }
}

// Check the target of the push with local git commands only. Give the parent of the fix, which
// is the head commit of the round, or null when Bifrost must not push.
async function checkTarget(
  o: PushInput,
  remoteBase: string,
  run: (args: string[]) => Promise<ExecResult>,
): Promise<string | null> {
  const name = o.headRef
  if (name === '' || name.startsWith('-') || !OBJECT_ID.test(o.fix)) return null
  if (!Number.isSafeInteger(o.number) || o.number <= 0) return null
  if (!REPO_KEY.test(`${o.owner}/${o.repo}`)) return null
  // Never the base branch or the default branch, in any case. An empty name cannot be checked.
  const lower = name.toLowerCase()
  if (o.baseRef === '' || o.defaultBranch === '') return null
  if (lower === o.baseRef.toLowerCase() || lower === o.defaultBranch.toLowerCase()) return null

  // --branch expands a name like @{-1}. So the output must be the same name.
  const format = await run(['check-ref-format', '--branch', name])
  if (gitFailed(format) || format.stdout.trim() !== name) return null
  // origin/HEAD of the clone names the default branch at the time of the clone.
  const head = await run(['symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD'])
  if (!gitFailed(head) && head.stdout.trim().toLowerCase() === `refs/remotes/origin/${lower}`) {
    return null
  }
  // git pushes to each URL of the remote, so there must be one URL, and no push URL.
  const url = `${remoteBase}${o.owner.toLowerCase()}/${o.repo.toLowerCase()}.git`
  const urls = await run(['config', '--get-all', 'remote.origin.url'])
  if (gitFailed(urls) || urls.stdout !== `${url}\n`) return null
  const pushUrls = await run(['config', '--get-all', 'remote.origin.pushurl'])
  if (!exitOne(pushUrls) || pushUrls.stdout !== '') return null
  // insteadOf and pushInsteadOf of the user config can send the fetch or the push to another URL,
  // for example over SSH. These two commands only read the config.
  const fetchUrl = await run(['ls-remote', '--get-url', 'origin'])
  if (gitFailed(fetchUrl) || fetchUrl.stdout !== `${url}\n`) return null
  const pushUrl = await run(['remote', 'get-url', '--push', '--all', 'origin'])
  if (gitFailed(pushUrl) || pushUrl.stdout !== `${url}\n`) return null

  const parent = await run(['rev-parse', '--verify', '--quiet', `${o.fix}^1^{commit}`])
  const base = parent.stdout.trim()
  return gitFailed(parent) || !OBJECT_ID.test(base) ? null : base
}
