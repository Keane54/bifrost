import {
  chmod,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  realpath,
  rm,
  stat,
  writeFile,
} from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ExecResult, RunClaude } from '../../../src/main/claude/cli'
import type { SpawnLines } from '../../../src/main/claude/spawn-lines'
import { runArgs } from '../../../src/main/daily-update/run-args'
import { RUN_TIMEOUT_MS, runPrompt } from '../../../src/main/daily-update/run-input'
import { RESULT_BEGIN, RESULT_END } from '../../../src/main/daily-update/run-result'
import {
  checkBoolean,
  checkDraftText,
  checkId,
  checkPageTrigger,
  createDailyUpdateService,
  dailyFolder,
  MAX_EDIT,
} from '../../../src/main/daily-update/service'
import {
  type DailyStateStore,
  dailyStateFile,
  openDailyStateStore,
} from '../../../src/main/daily-update/state-store'
import type { Gh } from '../../../src/main/reviews/gh'
import { areaSince, movedHeader } from '../../../src/renderer/src/daily-update/panel-model'
import type { DailySnapshot } from '../../../src/shared/daily-state'
import { type DailyUpdateSettings, DEFAULT_DAILY_UPDATE } from '../../../src/shared/daily-update'

const READY = 'Your daily update is ready to check.'
const SECOND = '10 minutes left to post your daily update.'
const FAILED = "Bifrost couldn't write your daily update. You can still write it yourself."
const MINUTE = 60_000
const DAY = 24 * 60 * MINUTE

// Wednesday 11 November 2026, local time.
const at = (h: number, m: number): number => new Date(2026, 10, 11, h, m).getTime()
// The start of Tuesday, the due day before.
const TUESDAY = new Date(2026, 10, 10).getTime()

function settings(): DailyUpdateSettings {
  const area = (id: string, name: string, on: boolean, takesRest: boolean) => ({
    channel: `#${id}`,
    description: `${name} work.`,
    id,
    name,
    on,
    takesRest,
  })
  return {
    ...structuredClone(DEFAULT_DAILY_UPDATE),
    areas: [
      area('a', 'Billing', true, false),
      area('b', 'Mobile', true, true),
      area('c', 'Old', false, false),
    ],
    source: { server: 'board', tools: ['mcp__board__items_list'] },
  }
}

// The init event of the probe. extra adds tools of the board.
function initLine(status = 'connected', extra: string[] = []): string {
  return JSON.stringify({
    mcp_servers: [
      { name: 'board', status },
      { name: 'other', status: 'connected' },
    ],
    subtype: 'init',
    tools: [
      'Read',
      'mcp__board__items_list',
      'mcp__board__items_update',
      'mcp__other__thing_get',
      ...extra,
    ],
    type: 'system',
  })
}

// The stdout of a good claude -p run with one draft for each area.
function draftResult(drafts: Record<string, string>, extra: Record<string, unknown> = {}) {
  const body = {
    areas: Object.entries(drafts).map(([id, draft]) => ({
      draft,
      id,
      items:
        id === 'a'
          ? [{ id: 'T-1', kind: 'ticket', title: 'Invoices', url: 'https://board.example/T-1' }]
          : [],
      moved: id === 'a',
    })),
    unplaced: [],
    version: 1,
  }
  const result = `Here it is.\n${RESULT_BEGIN}\n${JSON.stringify(body)}\n${RESULT_END}`
  const stdout = JSON.stringify({ is_error: false, result, type: 'result', ...extra })
  return { code: 0, stderr: '', stdout } satisfies ExecResult
}

interface Note {
  text: string
  sound: boolean
  onClick: () => void
}

let home: string
let plugin: string
beforeEach(async () => {
  home = await mkdtemp(join(tmpdir(), 'bifrost-daily-service-'))
  plugin = join(home, 'plugin')
  await mkdir(plugin)
})
afterEach(async () => {
  await rm(home, { force: true, recursive: true })
})

async function harness(opts: { now?: number; store?: DailyStateStore } = {}) {
  const h = {
    bounces: 0,
    clipboard: [] as string[],
    external: [] as string[],
    ghCalls: [] as string[][],
    ghResult: { code: 0, stderr: '', stdout: '[]' } as ExecResult,
    // True: each probe waits until its signal aborts.
    hangProbe: false,
    // One init line for each probe. The last line repeats.
    initLines: [initLine()],
    notes: [] as string[],
    notified: [] as Note[],
    now: opts.now ?? at(9, 0),
    panels: [] as (string | null)[],
    probeSignals: [] as (AbortSignal | undefined)[],
    probes: [] as string[],
    runResult: async (_signal?: AbortSignal): Promise<ExecResult> =>
      draftResult({ a: 'Draft A', b: 'Draft B' }),
    runs: [] as { args: string[]; cwd: string; timeoutMs?: number; signal?: AbortSignal }[],
    settings: settings(),
    updates: [] as DailySnapshot[],
  }
  const store = opts.store ?? (await openDailyStateStore(dailyStateFile(home), () => {}))
  const spawnLines: SpawnLines = async (_args, o) => {
    const line = h.initLines[Math.min(h.probes.length, h.initLines.length - 1)] ?? ''
    h.probes.push(o.cwd)
    h.probeSignals.push(o.signal)
    if (h.hangProbe) {
      await aborted(o.signal)
      return { aborted: true, code: null, stopped: false, timedOut: false }
    }
    o.onLine(line)
    return { code: null, stopped: true, timedOut: false }
  }
  const runClaude: RunClaude = async (args, o) => {
    h.runs.push({ args, cwd: o?.cwd ?? '', signal: o?.signal, timeoutMs: o?.timeoutMs })
    return h.runResult(o?.signal)
  }
  const gh: Gh = {
    run: async args => {
      h.ghCalls.push(args)
      return h.ghResult
    },
  }
  const service = createDailyUpdateService({
    bifrostHome: home,
    bounce: () => {
      h.bounces++
    },
    eventNotice: text => {
      h.notes.push(text)
    },
    gh,
    log: () => {},
    notify: (text, sound, onClick) => {
      h.notified.push({ onClick, sound, text })
    },
    now: () => h.now,
    openExternal: async url => {
      h.external.push(url)
    },
    openPanel: areaId => {
      h.panels.push(areaId)
    },
    pluginDir: plugin,
    runClaude: async () => runClaude,
    settings: () => h.settings,
    spawnLines: async () => spawnLines,
    store,
    writeClipboard: text => {
      h.clipboard.push(text)
    },
  })
  service.onUpdate(snap => h.updates.push(snap))
  return { h, service, store }
}

// Resolve when the signal aborts. A missing signal never aborts.
function aborted(signal: AbortSignal | undefined): Promise<void> {
  return new Promise(resolve => {
    if (signal?.aborted) resolve()
    signal?.addEventListener('abort', () => resolve())
  })
}

// A gate that a test opens, and a promise that resolves when the code reaches the gate.
function gate() {
  let open = (): void => {}
  let reached = (): void => {}
  const opened = new Promise<void>(resolve => {
    open = resolve
  })
  const atGate = new Promise<void>(resolve => {
    reached = resolve
  })
  return {
    atGate,
    open,
    wait: async () => {
      reached()
      await opened
    },
  }
}

const readInput = async (dir: string) => JSON.parse(await readFile(join(dir, 'input.json'), 'utf8'))
const mode = async (path: string) => (await stat(path)).mode & 0o777

describe('refresh', () => {
  it('one run at a time', async () => {
    const { h, service } = await harness()
    let open = (): void => {}
    const gate = new Promise<void>(resolve => {
      open = resolve
    })
    h.runResult = async () => {
      await gate
      return draftResult({ a: 'A', b: 'B' })
    }
    const first = service.refresh('button')
    expect(service.snapshot().running).toBe(true)
    expect(await service.refresh('button')).toBe(false)
    expect(await service.refresh('open')).toBe(false)
    expect(await service.redo('a')).toBe(false)
    open()
    expect(await first).toBe(true)
    expect(h.runs).toHaveLength(1)
    expect(service.snapshot().running).toBe(false)
  })

  it('a refresh on panel open within 5 minutes of the last run does nothing', async () => {
    const { h, service } = await harness()
    expect(await service.refresh('button')).toBe(true)
    h.now += 4 * MINUTE
    expect(await service.refresh('open')).toBe(false)
    h.now += 2 * MINUTE
    expect(await service.refresh('open')).toBe(true)
    expect(h.runs).toHaveLength(2)
  })

  it('the Refresh button always runs', async () => {
    const { h, service } = await harness()
    expect(await service.refresh('button')).toBe(true)
    expect(await service.refresh('button')).toBe(true)
    expect(h.runs).toHaveLength(2)
  })

  it('a refresh on panel open keeps a changed draft', async () => {
    const { h, service } = await harness()
    expect(await service.refresh('open')).toBe(true)
    await service.editDraft('a', 'My own words')
    h.now += 6 * MINUTE
    h.runResult = async () => draftResult({ a: 'New A', b: 'New B' })
    expect(await service.refresh('open')).toBe(true)
    const { areas } = service.snapshot().state
    expect(areas.a).toMatchObject({ draft: 'My own words', edited: true, pending: 'New A' })
    expect(areas.b).toMatchObject({ draft: 'New B', edited: false })
  })

  it('a redo replaces only its own area', async () => {
    const { h, service } = await harness()
    await service.refresh('button')
    await service.editDraft('a', 'Mine A')
    await service.editDraft('b', 'Mine B')
    h.runResult = async () => draftResult({ a: 'New A', b: 'New B' })
    expect(await service.redo('a')).toBe(true)
    const { areas } = service.snapshot().state
    expect(areas.a).toEqual(expect.objectContaining({ draft: 'New A', edited: false }))
    expect(areas.a?.pending).toBeUndefined()
    expect(areas.b).toMatchObject({ draft: 'Mine B', edited: true, pending: 'New B' })
    await expect(service.redo('c')).rejects.toThrow('refused')
  })

  it('a good run writes the drafts and the Event log line', async () => {
    const { h, service } = await harness()
    await service.refresh('button')
    const snap = service.snapshot()
    expect(snap.state.lastRun).toEqual({ at: h.now, ok: true })
    expect(snap.state.areas.a?.items[0]?.id).toBe('T-1')
    expect(h.notes).toContain('Daily update: the drafts are ready.')
    expect(h.updates.some(u => u.running)).toBe(true)
    expect(h.updates.at(-1)?.running).toBe(false)
  })

  it('a source server that is not connected fails the run without claude', async () => {
    const { h, service } = await harness()
    h.initLines = [initLine('needs-auth')]
    expect(await service.refresh('button')).toBe(true)
    expect(h.runs).toHaveLength(0)
    expect(h.ghCalls).toHaveLength(0)
    expect(service.snapshot().state.lastRun).toEqual({
      at: h.now,
      detail: 'needs-auth',
      failure: 'source-unavailable',
      ok: false,
    })
    expect(h.notes).toContain(
      "Daily update: Bifrost couldn't reach board (needs-auth). Check it in Claude Code with /mcp.",
    )
  })

  it('a source server that is gone at the second probe fails the run without claude', async () => {
    const { h, service } = await harness()
    h.initLines = [initLine(), initLine('failed')]
    await service.refresh('button')
    expect(h.probes).toHaveLength(2)
    expect(h.runs).toHaveLength(0)
    expect(service.snapshot().state.lastRun).toMatchObject({
      detail: 'failed',
      failure: 'source-unavailable',
    })
  })

  it('with no source and no merged PRs the run fails with nothing-to-read', async () => {
    const { h, service } = await harness()
    h.settings.source = { server: null, tools: [] }
    h.settings.mergedPrs = false
    await service.refresh('button')
    expect(h.probes).toHaveLength(0)
    expect(h.runs).toHaveLength(0)
    expect(service.snapshot().state.lastRun).toMatchObject({ failure: 'nothing-to-read' })
  })

  it('a gh failure goes on with no PRs', async () => {
    const { h, service } = await harness()
    h.ghResult = { code: 1, stderr: 'boom', stdout: '' }
    await service.refresh('button')
    const since = new Date(TUESDAY).toISOString().replace('.000Z', 'Z')
    expect(h.ghCalls[0]).toContain(`--merged-at=>=${since}`)
    expect(h.runs).toHaveLength(1)
    expect((await readInput(h.runs[0]?.cwd ?? '')).prs).toEqual([])
    expect(h.notes.some(n => n.includes('merged PRs') && n.includes('boom'))).toBe(true)
    expect(service.snapshot().state.lastRun?.ok).toBe(true)
  })

  it('gh gets the start time in whole seconds', async () => {
    const { h, service, store } = await harness()
    const sent = TUESDAY + 9 * 60 * MINUTE + 1234
    await store.change(s => ({ ...s, lastSent: { a: sent, b: sent } }))
    await service.refresh('button')
    const iso = new Date(sent - 234).toISOString().replace('.000Z', 'Z')
    expect(iso).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/)
    expect(h.ghCalls[0]).toContain(`--merged-at=>=${iso}`)
  })

  it('merged PRs off runs no gh', async () => {
    const { h, service } = await harness()
    h.settings.mergedPrs = false
    await service.refresh('button')
    expect(h.ghCalls).toHaveLength(0)
    expect(h.runs).toHaveLength(1)
  })

  it('the run uses the args of runArgs and the run folder as cwd', async () => {
    const { h, service } = await harness()
    // A tool that the board gets after the first probe must be in the deny list.
    h.initLines = [initLine(), initLine('connected', ['mcp__board__items_delete'])]
    await service.refresh('button')
    const run = h.runs[0]
    if (!run) throw new Error('no run')
    const runs = await realpath(join(home, 'daily-update', 'runs'))
    expect(run.cwd.startsWith(`${runs}/`)).toBe(true)
    expect(basename(run.cwd)).toMatch(/^\d{8}-\d{6}$/)
    expect(h.probes).toEqual([run.cwd, run.cwd])
    expect(run.timeoutMs).toBe(RUN_TIMEOUT_MS)
    expect(run.args).toEqual(
      runArgs({
        allowed: ['mcp__board__items_list'],
        deny: ['mcp__board__items_update', 'mcp__board__items_delete', 'mcp__other'],
        ioDir: run.cwd,
        model: '',
        pluginDir: await realpath(plugin),
        prompt: runPrompt(join(run.cwd, 'input.json')),
      }),
    )
    expect(await mode(run.cwd)).toBe(0o700)
    expect(await mode(join(home, 'daily-update'))).toBe(0o700)
    const input = await readInput(run.cwd)
    expect(input).toMatchObject({
      now: new Date(h.now).toISOString(),
      source: { server: 'board', tools: ['mcp__board__items_list'] },
      version: 1,
    })
    expect(input.areas).toEqual([
      {
        description: 'Billing work.',
        id: 'a',
        name: 'Billing',
        since: new Date(TUESDAY).toISOString(),
        takesRest: false,
      },
      {
        description: 'Mobile work.',
        id: 'b',
        name: 'Mobile',
        since: new Date(TUESDAY).toISOString(),
        takesRest: true,
      },
    ])
  })

  it('a ticked write tool is in the deny list and not in the allowed list', async () => {
    const { h, service } = await harness()
    h.settings.source.tools = ['mcp__board__items_list', 'mcp__board__items_update']
    await service.refresh('button')
    const run = h.runs[0]
    if (!run) throw new Error('no run')
    const allowedAt = run.args.indexOf('--allowedTools')
    const allowed = run.args.slice(allowedAt + 1, run.args.indexOf('Skill', allowedAt))
    expect(allowed).toEqual(['mcp__board__items_list'])
    const denyAt = run.args.indexOf('--disallowedTools')
    const deny = run.args.slice(denyAt + 1, run.args.indexOf('--settings'))
    expect(deny).toContain('mcp__board__items_update')
    expect((await readInput(run.cwd)).source.tools).toEqual(['mcp__board__items_list'])
  })

  it('a run on a new day replaces a draft that the user changed yesterday', async () => {
    const { h, service } = await harness()
    await service.refresh('button')
    await service.editDraft('a', 'Yesterday mine')
    h.runResult = async () => draftResult({ a: 'Later A', b: 'Later B' })
    await service.refresh('button')
    expect(service.snapshot().state.areas.a).toMatchObject({ edited: true, pending: 'Later A' })
    h.now += DAY
    const before = service.snapshot().state.areas.a
    expect(before).toMatchObject({ draft: 'Yesterday mine', edited: false })
    expect(before?.pending).toBeUndefined()
    h.runResult = async () => draftResult({ a: 'Today A', b: 'Today B' })
    await service.refresh('button')
    const after = service.snapshot().state.areas.a
    expect(after).toMatchObject({ draft: 'Today A', edited: false })
    expect(after?.pending).toBeUndefined()
    await service.copy('a')
    expect(h.clipboard).toEqual(['Today A'])
  })

  it('the run keeps the newest 10 run folders', async () => {
    const { h, service } = await harness()
    const runs = join(home, 'daily-update', 'runs')
    await mkdir(runs, { recursive: true })
    for (let day = 1; day <= 12; day++) {
      await mkdir(join(runs, `202611${String(day).padStart(2, '0')}-080000`))
    }
    await writeFile(join(runs, 'notes.txt'), 'keep')
    await service.refresh('button')
    const left = await readdir(runs)
    const folders = left.filter(name => name !== 'notes.txt')
    expect(left).toContain('notes.txt')
    expect(folders).toHaveLength(10)
    expect(folders).toContain(basename(h.runs[0]?.cwd ?? ''))
    for (const gone of ['20261101-080000', '20261102-080000', '20261103-080000']) {
      expect(folders).not.toContain(gone)
    }
  })

  it('a bad result fails with bad-result', async () => {
    const { h, service } = await harness()
    h.runResult = async () => ({
      code: 0,
      stderr: '',
      stdout: JSON.stringify({ is_error: false, result: 'No markers here.' }),
    })
    await service.refresh('button')
    expect(service.snapshot().state.lastRun).toMatchObject({ failure: 'bad-result', ok: false })
    expect(h.notes).toContain(
      "Daily update: Claude's answer didn't have the right shape, so Bifrost didn't use it. " +
        'Try Refresh.',
    )
  })

  it('a timeout fails with timeout', async () => {
    const { h, service } = await harness()
    h.runResult = async () => ({ code: 1, stderr: '', stdout: '', timedOut: true })
    await service.refresh('button')
    expect(service.snapshot().state.lastRun).toMatchObject({ failure: 'timeout', ok: false })
  })

  it('a failed claude gives the short reason', async () => {
    const { h, service } = await harness()
    h.runResult = async () => ({ code: 2, stderr: '', stdout: '{"is_error":true}' })
    await service.refresh('button')
    expect(service.snapshot().state.lastRun).toMatchObject({
      detail: 'claude -p failed with code 2',
      failure: 'claude-failed',
    })
  })

  it('a failed claude gives the reason of the JSON result on one line', async () => {
    const { h, service } = await harness()
    const reply = (result: string) => async () => ({
      code: 1,
      stderr: 'other text',
      stdout: JSON.stringify({ is_error: true, result, type: 'result' }),
    })
    h.runResult = reply('Invalid API key · Please run /login\nSecond line')
    await service.refresh('button')
    expect(service.snapshot().state.lastRun).toMatchObject({
      detail: 'Claude Code reported a problem: Invalid API key · Please run /login',
      failure: 'claude-failed',
    })
    h.runResult = reply(`  ${'x'.repeat(300)}`)
    await service.refresh('button')
    const detail = service.snapshot().state.lastRun?.detail ?? ''
    expect(detail).toBe(`Claude Code reported a problem: ${'x'.repeat(200)}`)
  })

  it('a claude that a signal stops gives a fixed text', async () => {
    const { h, service } = await harness()
    h.runResult = async () =>
      ({
        code: 1,
        signal: 'SIGTERM',
        stderr: 'Command failed: /x/claude -p --tools Read,Skill PROMPT',
        stdout: '',
      }) as ExecResult
    await service.refresh('button')
    expect(service.snapshot().state.lastRun).toMatchObject({
      detail: 'Something stopped it before it finished.',
      failure: 'claude-failed',
    })
    expect(h.notes.join('\n')).not.toContain('Command failed')
  })

  it('the Event log gets only the count of the refused tool calls', async () => {
    const { h, service } = await harness()
    const denials = [{ tool_name: 'mcp__board__items_update' }, { tool_name: 'Bash' }]
    h.runResult = async () => draftResult({ a: 'A', b: 'B' }, { permission_denials: denials })
    await service.refresh('button')
    expect(h.notes.some(n => n.startsWith('Daily update:') && n.includes('2 tool calls'))).toBe(
      true,
    )
    expect(h.notes.join('\n')).not.toContain('items_update')
    expect(h.notes.join('\n')).not.toContain('Bash')
  })
})

describe('reminders', () => {
  it('the 09:30 tick runs and then shows the first reminder with sound', async () => {
    const { h, service, store } = await harness({ now: at(9, 30) })
    let shownAtRun = -1
    let firstShownAtRun = false
    h.runResult = async () => {
      shownAtRun = h.notified.length
      firstShownAtRun = store.get().marks.firstShown
      return draftResult({ a: 'A', b: 'B' })
    }
    await service.tick()
    expect(h.runs).toHaveLength(1)
    expect(shownAtRun).toBe(0)
    expect(firstShownAtRun).toBe(true)
    expect(h.notified.map(n => [n.text, n.sound])).toEqual([[READY, true]])
    expect(h.bounces).toBe(0)
    await service.tick()
    expect(h.runs).toHaveLength(1)
    expect(h.notified).toHaveLength(1)
  })

  it('the 09:50 tick shows the second reminder with sound and bounces once', async () => {
    const { h, service } = await harness({ now: at(9, 30) })
    await service.tick()
    h.now = at(9, 50)
    await service.tick()
    await service.tick()
    expect(h.runs).toHaveLength(1)
    expect(h.notified.map(n => [n.text, n.sound])).toEqual([
      [READY, true],
      [SECOND, true],
    ])
    expect(h.bounces).toBe(1)
  })

  it('two ticks at the same time show one reminder', async () => {
    const { h, service } = await harness({ now: at(9, 30) })
    await Promise.all([service.tick(), service.tick()])
    expect(h.runs).toHaveLength(1)
    expect(h.notified).toHaveLength(1)
  })

  it('a 09:50 tick during a run of 09:45 shows only the reminder of the run', async () => {
    const { h, service, store } = await harness({ now: at(9, 45) })
    const run = gate()
    h.runResult = async () => {
      await run.wait()
      return draftResult({ a: 'A', b: 'B' })
    }
    const first = service.tick()
    await run.atGate
    h.now = at(9, 50)
    let secondDone = false
    const second = service.tick().then(() => {
      secondDone = true
    })
    await new Promise(resolve => setTimeout(resolve, 20))
    expect(h.notified).toHaveLength(0)
    expect(secondDone).toBe(false)
    expect(store.get().marks.secondShown).toBe(true)
    run.open()
    await Promise.all([first, second])
    expect(h.notified.map(n => [n.text, n.sound])).toEqual([[READY, true]])
    expect(h.bounces).toBe(0)
    h.now = at(9, 55)
    await service.tick()
    expect(h.notified).toHaveLength(1)
    expect(h.runs).toHaveLength(1)
  })

  it('a failed save in a tick skips the reminder and says so in the Event log', async () => {
    const real = await openDailyStateStore(dailyStateFile(home), () => {})
    const store: DailyStateStore = {
      change: async () => {
        throw new Error('disk full')
      },
      get: () => real.get(),
    }
    const { h, service } = await harness({ now: at(9, 30), store })
    await service.tick()
    await service.tick()
    expect(h.runs).toHaveLength(0)
    expect(h.notified).toHaveLength(0)
    expect(
      h.notes.filter(
        n => n === "Bifrost couldn't save the daily update state, so it skipped this reminder.",
      ),
    ).toHaveLength(1)
  })

  it('a restart after the first reminder does not show it again', async () => {
    const first = await harness({ now: at(9, 30) })
    await first.service.tick()
    expect(first.h.notified).toHaveLength(1)
    const store = await openDailyStateStore(dailyStateFile(home), () => {})
    const again = await harness({ now: at(9, 40), store })
    await again.service.tick()
    expect(again.h.notified).toHaveLength(0)
    expect(again.h.runs).toHaveLength(0)
    again.h.now = at(9, 50)
    await again.service.tick()
    expect(again.h.notified.map(n => n.text)).toEqual([SECOND])
  })

  it('a start after the deadline runs and shows one reminder with no sound', async () => {
    const { h, service } = await harness({ now: at(10, 5) })
    await service.tick()
    await service.tick()
    expect(h.runs).toHaveLength(1)
    expect(h.notified.map(n => [n.text, n.sound])).toEqual([[READY, false]])
    expect(h.bounces).toBe(0)
  })

  it('a failed scheduled run shows the failure reminder', async () => {
    const { h, service } = await harness({ now: at(9, 30) })
    h.initLines = [initLine('failed')]
    await service.tick()
    expect(h.runs).toHaveLength(0)
    expect(h.notified.map(n => [n.text, n.sound])).toEqual([[FAILED, true]])
  })

  it('a failed late run shows the failure reminder with no sound', async () => {
    const { h, service } = await harness({ now: at(10, 5) })
    h.runResult = async () => ({ code: 1, stderr: '', stdout: '', timedOut: true })
    await service.tick()
    expect(h.notified.map(n => [n.text, n.sound])).toEqual([[FAILED, false]])
  })

  it('Mark as sent on each area stops the reminders', async () => {
    const { h, service } = await harness({ now: at(9, 0) })
    await service.markSent('a')
    h.now = at(9, 30)
    await service.tick()
    expect(h.notified).toHaveLength(1)
    await service.markSent('b')
    expect(service.snapshot().marker).toBe(false)
    for (const time of [at(9, 50), at(10, 5), at(16, 0)]) {
      h.now = time
      await service.tick()
    }
    expect(h.notified).toHaveLength(1)
    expect(h.bounces).toBe(0)
  })

  it('a run that ends after Mark as sent on each area shows no reminder', async () => {
    const { h, service } = await harness({ now: at(9, 30) })
    h.runResult = async () => {
      await service.markSent('a')
      await service.markSent('b')
      return draftResult({ a: 'A', b: 'B' })
    }
    await service.tick()
    expect(h.runs).toHaveLength(1)
    expect(h.notified).toHaveLength(0)
  })

  it('Skip today stops the reminders', async () => {
    const { h, service } = await harness({ now: at(9, 30) })
    await service.tick()
    await service.setSkipped(true)
    expect(service.snapshot().marker).toBe(false)
    h.now = at(9, 50)
    await service.tick()
    expect(h.notified).toHaveLength(1)
    expect(h.bounces).toBe(0)
  })

  it('Copy does not stop the reminders', async () => {
    const { h, service } = await harness({ now: at(9, 30) })
    await service.tick()
    await service.copy('a')
    await service.copy('b')
    h.now = at(9, 50)
    await service.tick()
    expect(h.notified.map(n => n.text)).toEqual([READY, SECOND])
  })

  it('a click on a reminder opens the panel at the first area that is not sent', async () => {
    const { h, service } = await harness({ now: at(9, 30) })
    await service.tick()
    await service.markSent('a')
    h.notified[0]?.onClick()
    expect(h.panels).toEqual(['b'])
  })

  it('a new day starts with fresh marks', async () => {
    const { h, service } = await harness({ now: at(9, 30) })
    await service.tick()
    await service.setSkipped(true)
    h.now = at(9, 30) + DAY
    await service.tick()
    expect(h.notified).toHaveLength(2)
    expect(service.snapshot().state.marks.skipped).toBe(false)
  })
})

describe('actions', () => {
  it('copy writes the draft as plain text only, as it is', async () => {
    const { h, service } = await harness()
    const draft = '**Daily update**\n**Done since my last update**\n- Fixed *one* bug'
    h.runResult = async () => draftResult({ a: draft, b: 'B' })
    await service.refresh('button')
    await service.copy('a')
    expect(h.clipboard).toEqual([draft])
    await expect(service.copy('c')).rejects.toThrow('refused')
  })

  it('openItem opens an https URL and refuses any other', async () => {
    const { h, service, store } = await harness()
    await service.refresh('button')
    await store.change(s => {
      const a = s.areas.a
      if (!a) throw new Error('no area')
      const bad = (id: string, url: string) => ({ id, kind: 'ticket' as const, title: id, url })
      return {
        ...s,
        areas: {
          ...s.areas,
          a: {
            ...a,
            items: [
              ...a.items,
              bad('T-2', 'javascript:alert(1)'),
              bad('T-3', 'http://board.example/T-3'),
              { id: 'T-4', kind: 'ticket', title: 'No link' },
            ],
          },
        },
        unplaced: [bad('T-9', 'https://board.example/T-9')],
      }
    })
    await service.openItem('a', 'T-1')
    await service.openItem('', 'T-9')
    for (const id of ['T-2', 'T-3', 'T-4', 'T-404']) {
      await expect(service.openItem('a', id)).rejects.toThrow('refused')
    }
    await expect(service.openItem('b', 'T-1')).rejects.toThrow('refused')
    expect(h.external).toEqual(['https://board.example/T-1', 'https://board.example/T-9'])
  })

  it('undoSent does nothing when the area has no mark today', async () => {
    const { h, service, store } = await harness()
    const older = h.now - DAY
    await store.change(s => ({ ...s, lastSent: { a: older } }))
    await service.undoSent('a')
    expect(store.get().lastSent).toEqual({ a: older })
    await service.markSent('a')
    expect(service.snapshot().since.a).toBe(h.now)
    await service.undoSent('a')
    expect(store.get().lastSent).toEqual({ a: older })
    expect(service.snapshot().since.a).toBe(older)
  })

  it('a second Mark as sent keeps the first mark', async () => {
    const { h, service, store } = await harness()
    const older = h.now - DAY
    await store.change(s => ({ ...s, lastSent: { a: older } }))
    await service.markSent('a')
    const first = h.now
    h.now += MINUTE
    await service.markSent('a')
    expect(store.get().marks.sent.a).toBe(first)
    expect(store.get().lastSent.a).toBe(first)
    expect(store.get().prevSent.a).toBe(older)
    await service.undoSent('a')
    expect(store.get().lastSent).toEqual({ a: older })
  })

  it('Mark as sent keeps the start time of the run in the header', async () => {
    const { h, service } = await harness()
    await service.refresh('button')
    await service.markSent('a')
    const snap = service.snapshot()
    expect(snap.since.a).toBe(h.now)
    expect(snap.state.areas.a?.since).toBe(TUESDAY)
    expect(areaSince(snap, 'a')).toBe(TUESDAY)
    expect(movedHeader(areaSince(snap, 'a'), h.now)).toBe(
      'Moved since your last update (Tue 00:00)',
    )
  })

  it('refuses an area that is not on', async () => {
    const { service } = await harness()
    await expect(service.markSent('c')).rejects.toThrow('refused')
    await expect(service.editDraft('zzz', 'x')).rejects.toThrow('refused')
  })
})

describe('snapshot', () => {
  it('gives the areas that are on, the start of each and the marker', async () => {
    const { h, service } = await harness()
    let snap = service.snapshot()
    expect(snap.areas.map(a => a.id)).toEqual(['a', 'b'])
    expect(snap).toMatchObject({
      configured: true,
      deadline: '10:00',
      due: true,
      marker: false,
      running: false,
      since: { a: TUESDAY, b: TUESDAY },
    })
    h.now = at(9, 30)
    snap = service.snapshot()
    expect(snap.marker).toBe(true)
    h.settings.areas = []
    expect(service.snapshot()).toMatchObject({ configured: false, marker: false })
  })

  it('a tick sends a new snapshot when the marker turns on', async () => {
    const { h, service } = await harness({ now: at(9, 29) })
    await service.tick()
    const before = h.updates.length
    h.now = at(9, 30)
    h.runResult = async () => draftResult({ a: 'A', b: 'B' })
    await service.tick()
    expect(h.updates.slice(before).some(u => u.marker)).toBe(true)
  })
})

describe('folders', () => {
  it('the daily-update folder gets mode 700', async () => {
    const dir = join(home, 'daily-update')
    await mkdir(dir, { mode: 0o755 })
    await chmod(dir, 0o755)
    expect(await dailyFolder(home)).toBe(dir)
    expect(await mode(dir)).toBe(0o700)
  })

  it('inventory probes in the daily-update folder', async () => {
    const { h, service } = await harness()
    const inv = await service.inventory()
    expect(h.probes).toEqual([join(home, 'daily-update')])
    expect(inv.servers.map(s => [s.name, s.status])).toEqual([
      ['board', 'connected'],
      ['other', 'connected'],
    ])
    expect(await mode(join(home, 'daily-update'))).toBe(0o700)
  })
})

describe('page values', () => {
  it('refuses a bad value from the page', () => {
    expect(checkId('a')).toBe('a')
    expect(() => checkId(7)).toThrow('refused')
    expect(() => checkId('x'.repeat(101))).toThrow('refused')
    expect(checkDraftText('**Daily update**')).toBe('**Daily update**')
    expect(() => checkDraftText('x'.repeat(MAX_EDIT + 1))).toThrow('refused')
    expect(checkPageTrigger('open')).toBe('open')
    expect(() => checkPageTrigger('schedule')).toThrow('refused')
    expect(checkBoolean(false)).toBe(false)
    expect(() => checkBoolean('yes')).toThrow('refused')
  })

  it('a failed inventory gives a friendly text', async () => {
    const { h, service } = await harness()
    h.initLines = ['not json']
    await expect(service.inventory()).rejects.toThrow(
      "Bifrost couldn't read your MCP servers. Please try again.",
    )
  })
})

describe('stop', () => {
  it('stop aborts the run and no reminder follows', async () => {
    const { h, service } = await harness({ now: at(9, 30) })
    const run = gate()
    h.runResult = async signal => {
      run.wait()
      await aborted(signal)
      return { aborted: true, code: 1, stderr: 'aborted', stdout: '' }
    }
    const ticked = service.tick()
    await run.atGate
    service.stop()
    await ticked
    expect(h.runs[0]?.signal?.aborted).toBe(true)
    expect(h.notified).toHaveLength(0)
    expect(service.snapshot().state.lastRun).toBeNull()
    expect(h.notes.some(n => n.includes("couldn't"))).toBe(false)
    expect(service.snapshot().running).toBe(false)
    expect(await service.refresh('button')).toBe(false)
    h.now = at(9, 50)
    await service.tick()
    expect(h.runs).toHaveLength(1)
    expect(h.notified).toHaveLength(0)
  })

  it('stop aborts a probe and starts no claude', async () => {
    const { h, service } = await harness()
    h.hangProbe = true
    const refreshed = service.refresh('button')
    while (h.probes.length === 0) await new Promise(resolve => setTimeout(resolve, 1))
    service.stop()
    expect(await refreshed).toBe(true)
    expect(h.probeSignals[0]?.aborted).toBe(true)
    expect(h.runs).toHaveLength(0)
    expect(service.snapshot().state.lastRun).toBeNull()
    await expect(service.inventory()).rejects.toThrow()
  })
})
