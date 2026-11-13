// The live check of the bifrost-daily-update skill in Bifrost mode. The script runs one real
// claude -p run with the Haiku model. A fake board (fake-board.ts) is the MCP server of the
// tickets. The script checks the result with the checks of the product. It prints only: "valid"
// or the failure, the item count of each area, the unplaced count, and the tool calls that the
// fake board logged.
//
// Run it by hand only, from the root of the repository:
//   node scripts/daily-update/check-daily-skill.ts
// It does not run in CI or in pnpm test. Each run costs tokens.
//
// The set-up:
// - The input has two areas: billing and mobile. No area takes the rest. The input has one
//   merged PR that names the billing ticket. The fake board gives three tickets: one for each
//   area, and one for no area. The expected counts: billing 2, mobile 1, unplaced 1.
// - The run folder is a new temporary folder. It is not in a git repository, and it is not
//   under ~/.bifrost. So the run also shows whether claude -p asks for trust in a new folder.
// - The fake board comes in with --mcp-config only. The script does not make the MCP config
//   strict, because the product does not. So the MCP servers of the user load too. A probe
//   reads all servers and their tools. Then the args of the product allow only the read tool
//   of the fake board, and deny its write tool and each other server.
// - claude runs with the env line of .m0-sandbox/cl.sh, but in the run folder. cl.sh always
//   runs in .m0-sandbox, and that folder is in the git repository.
// The check fails when the fake board logged a call of work_items_update. At the end, the
// script deletes its temporary folder.
//
// The modules of src/main import each other with no file extension. Plain node cannot load them.
// So the script first adds a resolve hook that tries a .ts file when a path fails.

import { spawn } from 'node:child_process'
import { existsSync, realpathSync } from 'node:fs'
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { registerHooks } from 'node:module'
import { homedir, tmpdir, userInfo } from 'node:os'
import { join, resolve } from 'node:path'
import type { ExecResult } from '../../src/main/claude/cli.ts'
import type { McpInventory } from '../../src/main/daily-update/mcp-inventory.ts'
import type { DailyInput } from '../../src/main/daily-update/run-input.ts'

registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context)
    } catch (err) {
      const relative = specifier.startsWith('.') || specifier.startsWith('/')
      if (!relative) throw err
      for (const suffix of ['.ts', '/index.ts']) {
        try {
          return nextResolve(specifier + suffix, context)
        } catch {
          // Try the next suffix.
        }
      }
      throw err
    }
  },
})

const { execFile } = await import('../../src/main/claude/cli.ts')
const { createSpawnLines } = await import('../../src/main/claude/spawn-lines.ts')
const { claudeFailure, isTrustError } = await import('../../src/main/actions/claude-output.ts')
const { parseInitEvent, PROBE_ARGS, PROBE_TIMEOUT_MS } = await import(
  '../../src/main/daily-update/mcp-inventory.ts'
)
const { allowedNow, denyList, runArgs } = await import('../../src/main/daily-update/run-args.ts')
const { RUN_TIMEOUT_MS, runPrompt, writeDailyInput } = await import(
  '../../src/main/daily-update/run-input.ts'
)
const { checkDailyResult, extractResult, MAX_OUTPUT_BYTES } = await import(
  '../../src/main/daily-update/run-result.ts'
)
const { isInside } = await import('../../src/main/reviews/repo-paths.ts')
const { skillsSourceDir } = await import('../../src/main/skills/skills-folder.ts')
const { DEFAULT_TEMPLATE, toolPrefix } = await import('../../src/shared/daily-update.ts')

const MODEL = 'haiku'
// The name of the fake board in the MCP config. No real server has this name.
const SERVER = 'bifrost-fake-board'
const READ_TOOL = 'work_items_list'
const WRITE_TOOL = 'work_items_update'
// The user of fake-board.ts.
const USER_EMAIL = 'sam.rivera@example.com'
const TEMP_PREFIX = 'bifrost-daily-live-'
const HOUR_MS = 3_600_000
const DAY_MS = 24 * HOUR_MS

// One earlier update for the voice. The names are invented.
const EXAMPLE = [
  '**Daily update**',
  '**Done since my last update**',
  'Morning all! The new search filters are live, so support can find old orders much faster.',
  '**Next**',
  "I'll pair with the design team on the filter labels today.",
  '**Blocked or at risk**',
  'Nothing',
].join('\n')

const scriptRepo = resolve(import.meta.dirname, '..', '..')
const pluginDir = realpathSync(skillsSourceDir(scriptRepo))
const fakeBoard = join(scriptRepo, 'scripts', 'daily-update', 'fake-board.ts')

function fail(message: string): never {
  throw new Error(message)
}

// The args for /usr/bin/env that run claude as .m0-sandbox/cl.sh does: a clean login env, and
// cwd as the folder. The env has no variable of the parent session.
function envArgs(cwd: string, args: string[]): string[] {
  return [
    '-i',
    `HOME=${process.env.HOME ?? homedir()}`,
    `USER=${process.env.USER ?? userInfo().username}`,
    `LOGNAME=${process.env.LOGNAME ?? userInfo().username}`,
    'SHELL=/bin/zsh',
    'TERM=xterm-256color',
    `LANG=${process.env.LANG ?? 'en_GB.UTF-8'}`,
    `TMPDIR=${process.env.TMPDIR ?? '/tmp'}`,
    '/bin/zsh',
    '-lic',
    'cd "$0" && exec claude "$@"',
    cwd,
    ...args,
  ]
}

// execFile gives claude a closed stdin. The buffer is larger than the limit of the product, so
// extractResult applies that limit itself.
function claude(args: string[], cwd: string, timeoutMs: number): Promise<ExecResult> {
  return execFile('/usr/bin/env', envArgs(cwd, args), {
    maxBuffer: 2 * MAX_OUTPUT_BYTES,
    timeoutMs,
  })
}

// Read the MCP servers and their tools from the init event. The probe stops at that event,
// before a model call. --mcp-config takes more than one value, so a flag must follow it.
// PROBE_ARGS sets the model of the probe.
async function probe(cwd: string, mcpConfig: string): Promise<McpInventory> {
  const spawnLines = createSpawnLines(spawn, '/usr/bin/env', process.env)
  let found: McpInventory | null = null
  const args = ['--mcp-config', mcpConfig, ...PROBE_ARGS]
  await spawnLines(envArgs(cwd, args), {
    cwd,
    onLine: line => {
      found = parseInitEvent(line)
      return found !== null
    },
    timeoutMs: PROBE_TIMEOUT_MS,
  })
  if (found === null) fail('the probe gave no init event')
  return found
}

// The run folder must not be in a git repository or under ~/.bifrost.
async function checkRunFolder(dir: string): Promise<void> {
  const bifrostHome = join(homedir(), '.bifrost')
  const homes = existsSync(bifrostHome) ? [bifrostHome, realpathSync(bifrostHome)] : [bifrostHome]
  if (homes.some(home => isInside(home, dir))) fail('the run folder is under ~/.bifrost')
  const git = await execFile('git', ['rev-parse', '--show-toplevel'], {
    cwd: dir,
    env: { HOME: homedir(), PATH: '/usr/bin:/bin' },
  })
  if (git.code === 0 || !/not a git repository/i.test(git.stderr)) {
    fail('the run folder is in a git repository, or git failed')
  }
}

// The names of the tools that the fake board logged, in order.
async function boardCalls(log: string): Promise<string[]> {
  const text = await readFile(log, 'utf8').catch(() => '')
  return text
    .split('\n')
    .filter(line => line.trim() !== '')
    .map(line => {
      try {
        const call = JSON.parse(line) as { tool?: unknown }
        return typeof call.tool === 'string' ? call.tool : '?'
      } catch {
        return '?'
      }
    })
}

function makeInput(allowed: string[]): DailyInput {
  const now = Date.now()
  const since = new Date(now - DAY_MS).toISOString()
  return {
    areas: [
      {
        description: 'Work on billing: invoices, payment reminders and the billing emails.',
        id: 'billing',
        name: 'Billing',
        since,
        takesRest: false,
      },
      {
        description: 'Work on the iOS and Android apps.',
        id: 'mobile',
        name: 'Mobile app',
        since,
        takesRest: false,
      },
    ],
    format: { examples: [EXAMPLE], template: DEFAULT_TEMPLATE },
    now: new Date(now).toISOString(),
    prs: [
      {
        body: 'Part of INV-310. Sends the reminder email each morning at 08:00.',
        mergedAt: new Date(now - HOUR_MS).toISOString(),
        number: 87,
        repo: 'example-org/billing',
        title: 'Add the invoice reminder job (INV-310)',
        url: 'https://github.com/example-org/billing/pull/87',
      },
    ],
    source: { server: SERVER, tools: allowed },
    timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    version: 1,
    you: USER_EMAIL,
  }
}

// Print the result of the run. Give true when the result is valid.
function report(result: ExecResult, areaIds: string[]): boolean {
  if (isTrustError(result.stdout) || isTrustError(result.stderr)) {
    console.log('Claude Code asks for trust in the new run folder')
    return false
  }
  if (result.timedOut) {
    console.log('timeout')
    return false
  }
  if (result.overflow) {
    console.log('bad-result: the output is over the limit')
    return false
  }
  if (result.code !== 0) {
    console.log(`claude-failed: ${claudeFailure(result, 'claude -p')}`)
    return false
  }
  const extracted = extractResult(result.stdout)
  if (!extracted.ok) {
    console.log('bad-result: no result between the marker lines')
    return false
  }
  const checked = checkDailyResult(extracted.text, areaIds)
  if (!checked.ok) {
    console.log(checked.failure)
    return false
  }
  console.log('valid')
  for (const area of checked.areas) console.log(`${area.id} items: ${area.items.length}`)
  console.log(`unplaced items: ${checked.unplaced.length}`)
  return true
}

// The temporary folder of this run. The finally step deletes it.
let base: string | null = null

async function run(): Promise<void> {
  base = realpathSync(await mkdtemp(join(tmpdir(), TEMP_PREFIX)))
  await chmod(base, 0o700)
  const runDir = join(base, 'run')
  const boardDir = join(base, 'board')
  await mkdir(runDir, { mode: 0o700 })
  await mkdir(boardDir, { mode: 0o700 })
  await checkRunFolder(runDir)

  // The log and the config are outside the run folder, so the run cannot read them.
  const callLog = join(boardDir, 'calls.log')
  const mcpConfig = join(boardDir, 'mcp.json')
  const server = { args: [fakeBoard, callLog], command: process.execPath, type: 'stdio' }
  await writeFile(mcpConfig, `${JSON.stringify({ mcpServers: { [SERVER]: server } }, null, 2)}\n`)

  const inventory = await probe(runDir, mcpConfig)
  const board = inventory.servers.filter(s => s.name === SERVER)
  if (board.length !== 1) fail('the probe did not find the fake board one time')
  if (board[0]?.status !== 'connected') fail(`the fake board is ${board[0]?.status}`)
  const prefix = toolPrefix(SERVER)
  const allowed = allowedNow(inventory, SERVER, [`${prefix}${READ_TOOL}`])
  const deny = denyList(inventory, SERVER, allowed)
  if (allowed.length !== 1) fail('the fake board has no read tool')
  if (!deny.includes(`${prefix}${WRITE_TOOL}`)) fail('the deny list has no write tool')

  const input = makeInput(allowed)
  const inputFile = await writeDailyInput(runDir, input)
  const args = runArgs({
    allowed,
    deny,
    ioDir: runDir,
    model: MODEL,
    pluginDir,
    prompt: runPrompt(inputFile),
  })
  const result = await claude(['--mcp-config', mcpConfig, ...args], runDir, RUN_TIMEOUT_MS)
  const valid = report(
    result,
    input.areas.map(area => area.id),
  )

  const calls = await boardCalls(callLog)
  console.log(`board calls: ${calls.length === 0 ? 'none' : calls.join(', ')}`)
  if (calls.includes(WRITE_TOOL)) console.log(`FAIL: the run called ${WRITE_TOOL}`)
  if (!valid || calls.includes(WRITE_TOOL)) process.exitCode = 1
}

try {
  await run()
} catch (error) {
  console.error(`check-daily-skill failed: ${(error as Error).message}`)
  process.exitCode = 1
} finally {
  if (base !== null && isInside(realpathSync(tmpdir()), base)) {
    await rm(base, { force: true, recursive: true })
  }
}
