// The start of a review session for a PR (design 12): a read-only claude --bg session in the
// worktree of the PR. The registry marks it as a PR session, so it gets no yellow box.

import { MAX_NAME, type ModelChoice } from '../../shared/new-session'
import type { SessionRow } from '../../shared/types'
import { claudeFailure, SHORT_ID } from '../actions/claude-output'
import {
  messageOf,
  NO_STATUSLINE_SETTINGS,
  REFUSED_BAD_ID,
  RUN_TIMEOUT_MS,
  resolveClaude,
  startBackground,
  TrustNeededError,
} from '../actions/session-actions'
import type { RunClaude } from '../claude/cli'

// The tools of a review session. It can read, search and write its result file.
export const REVIEW_TOOLS: readonly string[] = ['Read', 'Glob', 'Grep', 'Write', 'Skill']

// The --settings value of a review session: no statusline, and no hooks at all. A PR head can hold
// a .claude folder with hooks, so the session runs no hook (defense in depth). This also stops the
// hooks that --settings itself gives. One argument, and no shell reads it.
export const REVIEW_SETTINGS = JSON.stringify({
  ...JSON.parse(NO_STATUSLINE_SETTINGS),
  disableAllHooks: true,
})

// A test home starts each PR session name with this text.
export const TEST_PREFIX = 'bifrost-test-'

// The name of a review session: <repo>-<number>-review. On a clash with a name in use, the owner
// comes first. The repository part is cut so that the name has MAX_NAME characters or less.
export function reviewSessionName(
  pr: { owner: string; repo: string; number: number },
  names: ReadonlySet<string>,
  testHome: boolean,
): string {
  const prefix = testHome ? TEST_PREFIX : ''
  const tail = `-${pr.number}-review`
  const build = (head: string): string => {
    const room = MAX_NAME - prefix.length - tail.length
    return `${prefix}${head.slice(0, Math.max(room, 0))}${tail}`
  }
  const plain = build(pr.repo)
  if (!names.has(plain)) return plain
  return build(`${pr.owner}-${pr.repo}`)
}

// The prompt of a review session. It names the input file.
export function reviewPrompt(inputFile: string): string {
  return `/bifrost-review bifrost-input=${inputFile}`
}

// The arguments of "claude --bg" for a review session. The prompt is last. A flag with many
// values (--tools, --add-dir, --plugin-dir) never comes right before it.
export function reviewSessionArgs(o: {
  ioDir: string
  pluginDir: string
  model: ModelChoice
  name: string
  prompt: string
}): string[] {
  const args = [
    '--bg',
    '--restricted',
    '--strict-mcp-config',
    '--tools',
    ...REVIEW_TOOLS,
    '--permission-mode',
    'auto',
    '--add-dir',
    o.ioDir,
    '--plugin-dir',
    o.pluginDir,
    '--settings',
    REVIEW_SETTINGS,
  ]
  if (o.model !== '') args.push('--model', o.model)
  args.push('--name', o.name, o.prompt)
  return args
}

// The name goes in each outcome, so the caller can find the session by name when its row shows.
export type StartOutcome =
  | { ok: true; shortId: string; sessionId: string; name: string }
  | { ok: false; trust: boolean; message: string; name: string }

export interface ReviewSessions {
  start(o: { cwd: string; args: string[]; name: string }): Promise<StartOutcome>
  stop(shortId: string): Promise<void>
  remove(row: { shortId: string; sessionId: string; name: string }): Promise<void>
}

export function createReviewSessions(deps: {
  run(): Promise<RunClaude | null>
  waitForRow(match: (row: SessionRow) => boolean, timeoutMs: number): Promise<SessionRow>
  markStarted(id: string): void
  expectPrSession(name: string): void
  releasePrSession(name: string): void
  forget(id: string): void
  log(m: string): void
}): ReviewSessions {
  const checkShortId = (shortId: string): void => {
    if (!SHORT_ID.test(shortId)) throw new Error(REFUSED_BAD_ID)
  }

  return {
    // Stop, then remove. A failed stop does not matter. A refusal of rm goes to the log. The
    // row and its PR mark stay, so the session keeps the PR rule. After a working rm the
    // registry releases the name and forgets the row.
    async remove(row) {
      checkShortId(row.shortId)
      const run = await resolveClaude(deps)
      await run(['stop', row.shortId], { timeoutMs: RUN_TIMEOUT_MS })
      const result = await run(['rm', row.shortId], { timeoutMs: RUN_TIMEOUT_MS })
      if (result.code !== 0) {
        deps.log(claudeFailure(result, 'claude rm'))
        return
      }
      deps.releasePrSession(row.name)
      deps.forget(row.sessionId)
    },
    // The registry gets the name first. So the session has the PR rule from its first row, also
    // when the row shows late. A start that cannot have made a session releases the name.
    async start({ args, cwd, name }) {
      deps.expectPrSession(name)
      try {
        const run = await resolveClaude(deps)
        const { row, shortId } = await startBackground(deps, run, args, cwd)
        return { name, ok: true, sessionId: row.sessionId, shortId }
      } catch (error) {
        const trust = error instanceof TrustNeededError
        if (trust) deps.releasePrSession(name)
        return { message: messageOf(error), name, ok: false, trust }
      }
    },

    async stop(shortId) {
      checkShortId(shortId)
      const run = await resolveClaude(deps)
      const result = await run(['stop', shortId], { timeoutMs: RUN_TIMEOUT_MS })
      if (result.code !== 0) throw new Error(claudeFailure(result, 'claude stop'))
    },
  }
}
