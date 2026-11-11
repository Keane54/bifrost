// The start of a review session for a PR (design 12): a read-only claude --bg session in the
// worktree of the PR. The registry marks it as a PR session, so it gets no yellow box.

import { MAX_NAME, type ModelChoice } from '../../shared/new-session'
import type { SessionRow } from '../../shared/types'
import { claudeFailure, SHORT_ID } from '../actions/claude-output'
import {
  NO_STATUSLINE_SETTINGS,
  RUN_TIMEOUT_MS,
  startBackground,
  TrustNeededError,
} from '../actions/session-actions'
import type { RunClaude } from '../claude/cli'

// The tools of a review session. It can read, search and write its result file.
export const REVIEW_TOOLS: readonly string[] = ['Read', 'Glob', 'Grep', 'Write', 'Skill']

// A test home starts each PR session name with this text.
export const TEST_PREFIX = 'bifrost-test-'

const NO_CLAUDE = 'claude not found'
const REFUSED_SHORT_ID = 'refused: bad session ID'

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
    NO_STATUSLINE_SETTINGS,
  ]
  if (o.model !== '') args.push('--model', o.model)
  args.push('--name', o.name, o.prompt)
  return args
}

export type StartOutcome =
  | { ok: true; shortId: string; sessionId: string }
  | { ok: false; trust: boolean; message: string }

export interface ReviewSessions {
  start(o: { cwd: string; args: string[] }): Promise<StartOutcome>
  stop(shortId: string): Promise<void>
  remove(row: { shortId: string; sessionId: string }): Promise<void>
}

export function createReviewSessions(deps: {
  run(): Promise<RunClaude | null>
  waitForRow(match: (row: SessionRow) => boolean, timeoutMs: number): Promise<SessionRow>
  markStarted(id: string): void
  markPrSession(id: string): void
  forget(id: string): void
  log(m: string): void
}): ReviewSessions {
  const claude = async (): Promise<RunClaude> => {
    const run = await deps.run()
    if (!run) throw new Error(NO_CLAUDE)
    return run
  }
  const checkShortId = (shortId: string): void => {
    if (!SHORT_ID.test(shortId)) throw new Error(REFUSED_SHORT_ID)
  }

  return {
    // Stop, then remove. A failed stop does not matter. A refusal of rm goes to the log. The
    // registry forgets the row in each case.
    async remove(row) {
      checkShortId(row.shortId)
      const run = await claude()
      await run(['stop', row.shortId], { timeoutMs: RUN_TIMEOUT_MS })
      const result = await run(['rm', row.shortId], { timeoutMs: RUN_TIMEOUT_MS })
      if (result.code !== 0) deps.log(claudeFailure(result, 'claude rm'))
      deps.forget(row.sessionId)
    },
    async start({ args, cwd }) {
      let run: RunClaude
      try {
        run = await claude()
      } catch (error) {
        return { message: messageOf(error), ok: false, trust: false }
      }
      try {
        const row = await startBackground(deps, run, args, cwd)
        deps.markPrSession(row.sessionId)
        return { ok: true, sessionId: row.sessionId, shortId: row.shortId ?? '' }
      } catch (error) {
        return { message: messageOf(error), ok: false, trust: error instanceof TrustNeededError }
      }
    },

    async stop(shortId) {
      checkShortId(shortId)
      const run = await claude()
      const result = await run(['stop', shortId], { timeoutMs: RUN_TIMEOUT_MS })
      if (result.code !== 0) throw new Error(claudeFailure(result, 'claude stop'))
    },
  }
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
