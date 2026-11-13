// The Daily update service. It runs the drafts on a schedule, when the panel opens and on a
// button. It keeps the day state and shows the reminders. ipc.ts gives it the parts of Electron.

import { chmod, mkdir, readdir, realpath, rm } from 'node:fs/promises'
import { join } from 'node:path'
import {
  allDone,
  isDueDay,
  localDate,
  nextAction,
  type Reminder,
  type ScheduleAction,
  showMarker,
  sinceTime,
} from '../../shared/daily-schedule'
import {
  applyResult,
  type DailyAreaResult,
  type DailyItem,
  type DailySnapshot,
  type DailyState,
  editDraft as editDraftOf,
  type FailureCode,
  failRun,
  failureText,
  keepMine as keepMineOf,
  markSent as markSentOf,
  redoArea,
  rollDay,
  setFirstShown,
  setSecondShown,
  setSkipped as setSkippedOf,
  usePending as takePending,
  undoSent as undoSentOf,
} from '../../shared/daily-state'
import type { DailyUpdateSettings, McpInventory, WorkArea } from '../../shared/daily-update'
import { isRecord } from '../../shared/plain-object'
import { claudeFailure } from '../actions/claude-output'
import type { ExecResult, RunClaude } from '../claude/cli'
import type { SpawnLines } from '../claude/spawn-lines'
import type { Gh } from '../reviews/gh'
import { probeInventory } from './mcp-inventory'
import { type DailyPr, fetchMergedPrs } from './merged-prs'
import { allowedNow, denyList, runArgs } from './run-args'
import { type DailyInput, RUN_TIMEOUT_MS, runPrompt, writeDailyInput } from './run-input'
import { checkDailyResult, extractResult, MAX_ID, MAX_OUTPUT_BYTES } from './run-result'
import type { DailyStateStore } from './state-store'

// The title of each reminder. ipc.ts adds it.
export const DAILY_TITLE = 'Daily update'
export const READY_TEXT = 'Your daily update is ready to check.'
export const SECOND_TEXT = '10 minutes left to post your daily update.'
export const FAILED_TEXT =
  "Bifrost couldn't write your daily update. You can still write it yourself."
// A panel open starts no run within this time after the end of the last run.
export const OPEN_GUARD_MS = 5 * 60_000
// The number of run folders to keep.
export const KEEP_RUNS = 10

const STARTED_LINE = 'Daily update: Bifrost is writing the drafts.'
const READY_LINE = 'Daily update: the drafts are ready.'
const NO_CLAUDE = "Bifrost couldn't find Claude Code."
const PROBE_FAILED = "Bifrost couldn't read your MCP servers."
const RUN_BROKEN = "Bifrost couldn't prepare the run."
// The reason when a signal stopped claude. Node's own text holds the full command line.
const STOPPED = 'Something stopped it before it finished.'
const INVENTORY_FAILED = "Bifrost couldn't read your MCP servers. Please try again."
const REFUSED_AREA = 'refused: unknown work area'
const REFUSED_DRAFT = 'refused: the work area has no draft'
const REFUSED_LINK = 'refused: the item has no link to open'
const REFUSED_INPUT = 'refused: bad input'
const SAVE_FAILED_LINE =
  "Bifrost couldn't save the daily update state, so it skipped this reminder."
// The longest server status that goes into a failure text.
const MAX_STATUS = 60
// The longest reason from the JSON output of a failed claude.
const MAX_REASON = 200
const RUN_NAME = /^\d{8}-\d{6}(-\d+)?$/
const MAX_NAME_TRIES = 100

export type RefreshTrigger = 'open' | 'button' | 'schedule'

// The checks of the values that the page sends. Each bad value is refused.
// A draft that the user changed can be longer than a draft of Claude.
export const MAX_EDIT = 20_000

export function checkId(value: unknown): string {
  if (typeof value !== 'string' || value.length > MAX_ID) throw new Error(REFUSED_INPUT)
  return value
}

export function checkDraftText(value: unknown): string {
  if (typeof value !== 'string') throw new Error(REFUSED_INPUT)
  if (value.length > MAX_EDIT) throw new Error('refused: the draft is too long')
  return value
}

export function checkPageTrigger(value: unknown): 'open' | 'button' {
  if (value !== 'open' && value !== 'button') throw new Error(REFUSED_INPUT)
  return value
}

export function checkBoolean(value: unknown): boolean {
  if (typeof value !== 'boolean') throw new Error(REFUSED_INPUT)
  return value
}

export interface DailyUpdateDeps {
  now(): number
  settings(): DailyUpdateSettings
  store: DailyStateStore
  gh: Gh
  // null when Bifrost cannot find claude.
  runClaude(): Promise<RunClaude | null>
  spawnLines(): Promise<SpawnLines | null>
  notify(text: string, sound: boolean, onClick: () => void): void
  // Bounce the Dock icon one time.
  bounce(): void
  // Add a line to the Event log.
  eventNotice(text: string): void
  writeClipboard(text: string): void
  openExternal(url: string): Promise<void>
  // Show the window and open the panel at the area, or at the first tab for null.
  openPanel(areaId: string | null): void
  // The skills plugin folder of the review sessions.
  pluginDir: string
  bifrostHome: string
  // A line for the console. It is not for the user.
  log(message: string): void
}

export interface DailyUpdateService {
  snapshot(): DailySnapshot
  // The returned function removes only this listener.
  onUpdate(cb: (snapshot: DailySnapshot) => void): () => void
  // Check the schedule. Run and remind when it is time.
  tick(): Promise<void>
  // Run the drafts. Give false when the guard skips the run.
  refresh(trigger: RefreshTrigger): Promise<boolean>
  // Run the drafts and replace the draft of the area, also a changed one.
  redo(areaId: string): Promise<boolean>
  editDraft(areaId: string, text: string): Promise<void>
  usePending(areaId: string): Promise<void>
  keepMine(areaId: string): Promise<void>
  markSent(areaId: string): Promise<void>
  undoSent(areaId: string): Promise<void>
  setSkipped(skipped: boolean): Promise<void>
  copy(areaId: string): Promise<void>
  // The area ID '' is the list of the items that fit no area.
  openItem(areaId: string, itemId: string): Promise<void>
  inventory(): Promise<McpInventory>
  // Stop the run and the probes that run now. After this, no run starts and no reminder shows.
  stop(): void
}

// since: area id to the start of the run for that area, in ms.
type Drafts =
  | { ok: true; areas: DailyAreaResult[]; unplaced: DailyItem[]; since: Record<string, number> }
  | { ok: false; failure: FailureCode; detail?: string }

function fail(failure: FailureCode, detail?: string): Drafts {
  return detail === undefined ? { failure, ok: false } : { detail, failure, ok: false }
}

function own<T>(record: Record<string, T>, id: string): T | undefined {
  return Object.hasOwn(record, id) ? record[id] : undefined
}

const pad = (n: number): string => String(n).padStart(2, '0')

// The name of a run folder is the UTC start time. So the names sort in the order of time.
function runName(at: Date): string {
  const day = `${at.getUTCFullYear()}${pad(at.getUTCMonth() + 1)}${pad(at.getUTCDate())}`
  return `${day}-${pad(at.getUTCHours())}${pad(at.getUTCMinutes())}${pad(at.getUTCSeconds())}`
}

// Make <bifrostHome>/daily-update with mode 700 and give its path. A folder from before also
// gets mode 700. Call it before each write in the folder.
export async function dailyFolder(bifrostHome: string): Promise<string> {
  const dir = join(bifrostHome, 'daily-update')
  await mkdir(dir, { mode: 0o700, recursive: true })
  await chmod(dir, 0o700)
  return dir
}

// Make a new folder in runs. A name that exists gets a number.
async function newRunFolder(runs: string, base: string): Promise<string> {
  for (let n = 1; n <= MAX_NAME_TRIES; n++) {
    const name = n === 1 ? base : `${base}-${n}`
    try {
      await mkdir(join(runs, name), { mode: 0o700 })
      return name
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
    }
  }
  throw new Error('Bifrost found no free name for the run folder.')
}

// Keep the newest run folders. Remove only names of run folders, and never the current one.
async function pruneRuns(runs: string, current: string): Promise<void> {
  const names = (await readdir(runs)).filter(n => RUN_NAME.test(n) && n !== current).sort()
  const old = names.slice(0, Math.max(0, names.length - (KEEP_RUNS - 1)))
  await Promise.all(old.map(n => rm(join(runs, n), { force: true, recursive: true })))
}

// The reason why the ticket source cannot work, or null when it is connected or not set.
function sourceDown(inv: McpInventory, server: string | null): string | null {
  if (server === null) return null
  const info = inv.servers.find(s => s.name === server)
  if (!info) return 'not found'
  if (info.status === 'connected') return null
  return info.status.slice(0, MAX_STATUS) || 'unknown'
}

// The JSON output of claude -p, or null.
function replyOf(stdout: string): Record<string, unknown> | null {
  if (Buffer.byteLength(stdout, 'utf8') > MAX_OUTPUT_BYTES) return null
  try {
    const data: unknown = JSON.parse(stdout)
    return isRecord(data) ? data : null
  } catch {
    return null
  }
}

// The reason of an error reply: the first line of its result text, cut to MAX_REASON. Else null.
function errorLine(reply: Record<string, unknown> | null): string | null {
  if (reply?.is_error !== true || typeof reply.result !== 'string') return null
  const line = reply.result
    .split(/\r?\n/)
    .map(text => text.trim())
    .find(text => text !== '')
  return line === undefined ? null : line.slice(0, MAX_REASON)
}

// The short reason of a failed claude. A stop by a signal gives a fixed text. Then the reason of an
// error reply comes first. Other JSON output is not a reason for the user, so the reason does not
// use it.
function failedReason(result: ExecResult, reply: Record<string, unknown> | null): string {
  if (result.signal !== undefined) return STOPPED
  const line = errorLine(reply)
  if (line !== null) return claudeFailure({ ...result, stderr: '', stdout: line }, 'claude -p')
  return claudeFailure({ ...result, stdout: reply === null ? result.stdout : '' }, 'claude -p')
}

// The number of tool calls that the run did not get. The tool names stay out of the log.
function denialCount(reply: Record<string, unknown> | null): number {
  const denials = reply?.permission_denials
  return Array.isArray(denials) ? denials.length : 0
}

function denialLine(count: number): string {
  const calls = count === 1 ? '1 tool call' : `${count} tool calls`
  return `Daily update: Claude tried ${calls} that the run isn't allowed to make.`
}

// The UTC time with no milliseconds, for example 2026-11-11T09:30:00Z. gh takes this form.
// The cut goes down to the second, so the search does not miss a PR of that second.
export function isoSeconds(ms: number): string {
  return new Date(Math.floor(ms / 1000) * 1000).toISOString().replace('.000Z', 'Z')
}

function isHttps(url: string): boolean {
  return url.startsWith('https://') && URL.canParse(url)
}

export function createDailyUpdateService(deps: DailyUpdateDeps): DailyUpdateService {
  const listeners = new Set<(snapshot: DailySnapshot) => void>()
  // stop() aborts it. The runs and the probes get its signal.
  const halt = new AbortController()
  // The run that runs now, or null. Its value is true for a good run.
  let current: Promise<boolean> | null = null
  // A scheduled run and its reminder, while they run.
  let scheduled: Promise<void> | null = null
  // The reminders that a failed save skipped, as date|reminder. Each one gets one log line.
  const skipped = new Set<string>()
  // The date and the marker of the last snapshot that Bifrost sent.
  let sent = ''

  function snapshotAt(now: Date): DailySnapshot {
    const s = deps.settings()
    const state = rollDay(deps.store.get(), localDate(now))
    const areas = s.areas.filter(a => a.on)
    const since = Object.fromEntries(
      areas.map(a => [a.id, sinceTime(now, s.days, own(state.lastSent, a.id))]),
    )
    return {
      areas,
      configured: areas.length > 0,
      deadline: s.deadline,
      due: isDueDay(now, s.days),
      marker: showMarker(now, s, state.marks),
      running: current !== null,
      since,
      state,
    }
  }

  const markerKey = (now: Date, snap: DailySnapshot): string => `${localDate(now)}|${snap.marker}`

  function emit(): void {
    const now = new Date(deps.now())
    const snap = snapshotAt(now)
    sent = markerKey(now, snap)
    for (const cb of listeners) {
      try {
        cb(snap)
      } catch (error) {
        deps.log(`A Daily update listener failed. ${String(error)}`)
      }
    }
  }

  function onArea(areaId: string): WorkArea {
    const area = deps.settings().areas.find(a => a.on && a.id === areaId)
    if (!area) throw new Error(REFUSED_AREA)
    return area
  }

  // Change the state of today. Then send the new snapshot.
  async function change(fn: (s: DailyState, at: number) => DailyState): Promise<void> {
    const at = deps.now()
    const today = localDate(new Date(at))
    await deps.store.change(s => fn(rollDay(s, today), at))
    emit()
  }

  async function probe(spawnLines: SpawnLines, cwd: string): Promise<McpInventory | null> {
    try {
      return await probeInventory(spawnLines, cwd, halt.signal)
    } catch {
      return null
    }
  }

  // Give the merged PRs. A failure goes to the Event log, and the run goes on with no PRs.
  async function readPrs(sinceMs: number): Promise<DailyPr[]> {
    let reason: string
    try {
      const got = await fetchMergedPrs(deps.gh, isoSeconds(sinceMs))
      if (got.ok) return got.prs
      reason = got.reason
    } catch {
      reason = "GitHub CLI (gh) couldn't run."
    }
    const line =
      "Daily update: Bifrost couldn't read your merged PRs, so the drafts leave them out."
    deps.eventNotice(`${line} ${reason}`)
    return []
  }

  async function makeRunFolder(at: Date): Promise<string> {
    const runs = join(await dailyFolder(deps.bifrostHome), 'runs')
    await mkdir(runs, { mode: 0o700, recursive: true })
    await chmod(runs, 0o700)
    const name = await newRunFolder(runs, runName(at))
    const dir = join(runs, name)
    await chmod(dir, 0o700)
    try {
      await pruneRuns(runs, name)
    } catch (error) {
      deps.log(`Bifrost cannot remove old Daily update run folders. ${String(error)}`)
    }
    return realpath(dir)
  }

  function readRun(result: ExecResult, ids: string[], since: Record<string, number>): Drafts {
    const reply = replyOf(result.stdout)
    const denied = denialCount(reply)
    if (denied > 0) deps.eventNotice(denialLine(denied))
    if (result.timedOut) return fail('timeout')
    if (result.overflow) return fail('bad-result')
    if (result.code !== 0 || errorLine(reply) !== null) {
      return fail('claude-failed', failedReason(result, reply))
    }
    const extracted = extractResult(result.stdout)
    if (!extracted.ok) return fail('bad-result')
    const checked = checkDailyResult(extracted.text, ids)
    if (!checked.ok) return fail(checked.failure)
    return { areas: checked.areas, ok: true, since, unplaced: checked.unplaced }
  }

  // The steps of one run, in order. The source check comes before any claude -p run.
  async function draft(s: DailyUpdateSettings, areas: WorkArea[], at: number): Promise<Drafts> {
    const server = s.source.server
    if (server === null && !s.mergedPrs) return fail('nothing-to-read')
    const [spawnLines, runClaude] = await Promise.all([deps.spawnLines(), deps.runClaude()])
    if (!spawnLines || !runClaude) return fail('claude-failed', NO_CLAUDE)
    const now = new Date(at)
    const ioDir = await makeRunFolder(now)
    const pluginDir = await realpath(deps.pluginDir)
    const first = await probe(spawnLines, ioDir)
    if (!first) return fail('claude-failed', PROBE_FAILED)
    const down = sourceDown(first, server)
    if (down !== null) return fail('source-unavailable', down)
    const state = rollDay(deps.store.get(), localDate(now))
    const since = areas.map(a => sinceTime(now, s.days, own(state.lastSent, a.id)))
    const prs = s.mergedPrs ? await readPrs(Math.min(...since)) : []
    const input: DailyInput = {
      areas: areas.map((a, i) => ({
        description: a.description,
        id: a.id,
        name: a.name,
        since: new Date(since[i] ?? at).toISOString(),
        takesRest: a.takesRest,
      })),
      format: s.format,
      now: now.toISOString(),
      prs,
      source: { server, tools: allowedNow(first, server, s.source.tools) },
      timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      version: 1,
      you: s.you,
    }
    const inputFile = await writeDailyInput(ioDir, input)
    // Probe again, so a tool that the server got after the first probe is in the deny list.
    const inv = await probe(spawnLines, ioDir)
    if (!inv) return fail('claude-failed', PROBE_FAILED)
    const downNow = sourceDown(inv, server)
    if (downNow !== null) return fail('source-unavailable', downNow)
    const allowed = allowedNow(inv, server, s.source.tools)
    const args = runArgs({
      allowed,
      deny: denyList(inv, server, allowed),
      ioDir,
      model: s.model,
      pluginDir,
      prompt: runPrompt(inputFile),
    })
    if (halt.signal.aborted) return fail('claude-failed')
    const result = await runClaude(args, {
      cwd: ioDir,
      signal: halt.signal,
      timeoutMs: RUN_TIMEOUT_MS,
    })
    return readRun(
      result,
      areas.map(a => a.id),
      Object.fromEntries(areas.map((a, i) => [a.id, since[i] ?? at])),
    )
  }

  // Run, keep the result and write the Event log. Give true for a good run.
  async function runAll(redoId: string | null): Promise<boolean> {
    const startedAt = deps.now()
    const s = deps.settings()
    const areas = s.areas.filter(a => a.on)
    deps.eventNotice(STARTED_LINE)
    let drafts: Drafts
    try {
      drafts = await draft(s, areas, startedAt)
    } catch (error) {
      deps.log(`The Daily update run failed. ${String(error)}`)
      drafts = fail('claude-failed', RUN_BROKEN)
    }
    // A stopped run is not a result. It changes no state and writes no line.
    if (halt.signal.aborted) return false
    const at = deps.now()
    const today = localDate(new Date(at))
    try {
      if (drafts.ok) {
        const { areas: results, since, unplaced } = drafts
        await deps.store.change(x => {
          const next = applyResult(rollDay(x, today), results, unplaced, at, since)
          const mine = results.find(r => r.id === redoId)
          return mine ? redoArea(next, mine, own(since, mine.id)) : next
        })
        deps.eventNotice(READY_LINE)
      } else {
        const { detail, failure } = drafts
        await deps.store.change(x => failRun(rollDay(x, today), at, failure, detail))
        deps.eventNotice(`Daily update: ${failureText(failure, detail, s.source.server)}`)
      }
    } catch (error) {
      deps.log(`Bifrost cannot save the Daily update state. ${String(error)}`)
    }
    return drafts.ok
  }

  function start(redoId: string | null): Promise<boolean> {
    const run = runAll(redoId).finally(() => {
      current = null
      emit()
    })
    current = run
    emit()
    return run
  }

  // True within OPEN_GUARD_MS after the end of the last run.
  function recentRun(): boolean {
    const last = deps.store.get().lastRun
    if (last === null) return false
    const gap = deps.now() - last.at
    return gap >= 0 && gap < OPEN_GUARD_MS
  }

  function firstUnsent(): string | null {
    const marks = rollDay(deps.store.get(), localDate(new Date(deps.now()))).marks
    return deps.settings().areas.find(a => a.on && !Object.hasOwn(marks.sent, a.id))?.id ?? null
  }

  // Show a reminder. A run can end after Mark as sent or Skip today, so check the marks again.
  // A failed run replaces the text and keeps the sound rule of its reminder.
  function remind(reminder: Reminder, ok: boolean): void {
    if (halt.signal.aborted) return
    const now = new Date(deps.now())
    const marks = rollDay(deps.store.get(), localDate(now)).marks
    if (allDone(marks, deps.settings().areas)) return
    let text = FAILED_TEXT
    if (ok) text = reminder === 'second' ? SECOND_TEXT : READY_TEXT
    deps.notify(text, reminder !== 'late', () => deps.openPanel(firstUnsent()))
    if (reminder === 'second') deps.bounce()
  }

  return {
    async copy(areaId) {
      onArea(areaId)
      const view = own(deps.store.get().areas, areaId)
      if (!view) throw new Error(REFUSED_DRAFT)
      deps.writeClipboard(view.draft)
    },
    async editDraft(areaId, text) {
      onArea(areaId)
      await change(s => editDraftOf(s, areaId, text))
    },
    // Each failure gives a friendly text with no path, so the page can show it.
    async inventory() {
      const spawnLines = await deps.spawnLines()
      if (!spawnLines) throw new Error(NO_CLAUDE)
      try {
        return await probeInventory(spawnLines, await dailyFolder(deps.bifrostHome), halt.signal)
      } catch {
        throw new Error(INVENTORY_FAILED)
      }
    },
    async keepMine(areaId) {
      onArea(areaId)
      await change(s => keepMineOf(s, areaId))
    },
    async markSent(areaId) {
      onArea(areaId)
      // A mark today stays as it is. So a double click does not move it into prevSent.
      await change((s, at) => (Object.hasOwn(s.marks.sent, areaId) ? s : markSentOf(s, areaId, at)))
    },
    onUpdate(cb) {
      listeners.add(cb)
      return () => {
        listeners.delete(cb)
      }
    },
    async openItem(areaId, itemId) {
      const state = deps.store.get()
      let items: DailyItem[] = state.unplaced
      if (areaId !== '') {
        onArea(areaId)
        items = own(state.areas, areaId)?.items ?? []
      }
      const url = items.find(item => item.id === itemId)?.url
      if (url === undefined || !isHttps(url)) throw new Error(REFUSED_LINK)
      await deps.openExternal(url)
    },
    async redo(areaId) {
      onArea(areaId)
      if (current !== null || halt.signal.aborted) return false
      await start(areaId)
      return true
    },
    async refresh(trigger) {
      if (current !== null || halt.signal.aborted) return false
      if (!deps.settings().areas.some(a => a.on)) return false
      if (trigger === 'open' && recentRun()) return false
      await start(null)
      return true
    },
    async setSkipped(skipped) {
      await change(s => setSkippedOf(s, skipped))
    },
    snapshot: () => snapshotAt(new Date(deps.now())),
    stop() {
      halt.abort()
    },
    async tick() {
      if (halt.signal.aborted) return
      const now = new Date(deps.now())
      const s = deps.settings()
      if (markerKey(now, snapshotAt(now)) !== sent) emit()
      const due = nextAction(now, s, deps.store.get().marks)
      if (due.kind === 'none') return
      // Decide and set the shown marks in one step of the store queue, BEFORE the run. So two
      // ticks never show one reminder twice, and a restart during the run shows no reminder
      // again.
      const claim: { action: ScheduleAction } = { action: { kind: 'none' } }
      try {
        await deps.store.change(x => {
          const day = rollDay(x, localDate(now))
          const action = nextAction(now, s, day.marks)
          claim.action = action
          if (action.kind === 'none') return day
          if (action.kind === 'notify') return setSecondShown(day)
          const shown = setFirstShown(day)
          return action.reminder === 'first' ? shown : setSecondShown(shown)
        })
      } catch (error) {
        // With no saved marks, a reminder can show again after a restart. So skip it.
        deps.log(`Bifrost cannot save the Daily update marks. ${String(error)}`)
        const key = `${localDate(now)}|${due.kind === 'run' ? due.reminder : 'second'}`
        if (!skipped.has(key)) deps.eventNotice(SAVE_FAILED_LINE)
        skipped.add(key)
        return
      }
      emit()
      const { action } = claim
      if (action.kind === 'none') return
      if (action.kind === 'notify') {
        // A scheduled run of this window still runs. Its own reminder is the only reminder, so
        // two reminders never show together.
        if (scheduled !== null) {
          await scheduled
          return
        }
        remind('second', true)
        return
      }
      // A run that runs now gives the result for this reminder.
      const job = (async () => {
        const ok = await (current ?? start(null))
        remind(action.reminder, ok)
      })()
      scheduled = job
      try {
        await job
      } finally {
        if (scheduled === job) scheduled = null
      }
    },
    async undoSent(areaId) {
      onArea(areaId)
      // With no mark today, an older last send stays as it is.
      await change(s => (Object.hasOwn(s.marks.sent, areaId) ? undoSentOf(s, areaId) : s))
    },
    async usePending(areaId) {
      onArea(areaId)
      await change(s => takePending(s, areaId))
    },
  }
}
