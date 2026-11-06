import type { EngineInterface, Register, SessionUsage } from 'claude-code'

// The Live details mod of Bifrost.
// The mod sends one line for each event to the Bifrost socket on this Mac.
// It never waits for a send before the engine continues.
// A missing socket fails in about 1 ms and shows nothing.
//
// Each line is one JSON object in one HTTP POST over the socket. Each line has v, kind, sid,
// at and seq, and the fields of its kind. The Bifrost parser (src/main/live/live-event.ts)
// has the table of the kinds. This file keeps its own copy and imports nothing from Bifrost.

const URL = 'http://bifrost/v1/event'
const SOCKET = '/.bifrost/live.sock'
const VERSION = 1
const ANSWER_MAX = 4000
const TEXT_MAX = 200
const TRANSCRIPT_PATH_MAX = 1024
const USAGE_DELAY_MS = 2500
const HEARTBEAT_MS = 30_000
const END_WAIT_MS = 200
// The longest wait for the Claude Code version. Then the usage line goes out without it.
const VERSION_WAIT_MS = 500
// The time from /clear to the usage line of the new session ID. The row of the new ID then gets
// its model and cost before its first prompt.
const CLEAR_USAGE_DELAY_MS = 1000
// The limit of sends that have not settled. A Bifrost that hangs never answers a send. The mod
// then drops new lines and does not open more connections. Bifrost gets the state again at the
// next line or the next heartbeat.
const MAX_IN_FLIGHT = 32

type Kind =
  | 'session.start'
  | 'session.end'
  | 'turn.start'
  | 'ask'
  | 'tool.done'
  | 'permission'
  | 'turn.complete'
  | 'stop.failure'
  | 'usage'

type Data = Record<string, unknown>
type Figures = Pick<SessionUsage, 'context' | 'cost' | 'rateLimits'>

// The values of the newest classic.Stop input of one session.
interface Details {
  effort?: string
  permissionMode?: string
  transcriptPath?: string
}

// The order number of each line. It increases for each send of this module load.
let seq = 0
// HOME, read one time for each module load.
let home: Promise<string | undefined> | undefined
// The number of sends that have not settled.
let inFlight = 0
// The Claude Code version, after the first answer of $.session.version().
let claudeVersion: string | undefined
// The version read that did not settle yet. The next usage line waits for it again.
let versionRead: Promise<void> | undefined
// The values of each session, by session ID. A session has no entry until its first
// classic.Stop. session.end removes the entry of its session. So after /clear, a line of the
// new session ID never has the values of the old session.
const details = new Map<string, Details>()

function cut(value: unknown, max = TEXT_MAX): string {
  return String(value).slice(0, max)
}

// Cut a value that is known. An unknown value stays undefined, so the line does not have it.
function cutKnown(value: string | undefined, max = TEXT_MAX): string | undefined {
  return value === undefined ? undefined : cut(value, max)
}

function readHome($: EngineInterface): Promise<string | undefined> {
  home ??= $.env.get('HOME').catch(() => undefined)
  return home
}

// Return the Claude Code version, or undefined. The promise never rejects.
// The mod waits at most VERSION_WAIT_MS for a read. A read that does not settle in that time
// stays open, and the next usage line waits for the same read again. So a read that never settles
// never stops a usage line. A rejection gives no version, and the next usage line reads again.
async function readVersion($: EngineInterface): Promise<string | undefined> {
  if (claudeVersion !== undefined) return claudeVersion
  versionRead ??= $.session
    .version()
    .then(result => {
      if (typeof result.version === 'string') claudeVersion = result.version
    })
    .catch(() => {})
    .finally(() => {
      versionRead = undefined
    })
  await Promise.race([versionRead, $.clock.sleep(VERSION_WAIT_MS).catch(() => {})])
  return claudeVersion
}

// Send one line. The promise never rejects.
// At MAX_IN_FLIGHT sends that have not settled, the mod drops the line and returns at once.
// When data is a function, send gives it the session ID of the line.
async function send(
  $: EngineInterface,
  kind: Kind,
  data: Data | ((sid: string) => Data) = {},
  sid?: string,
) {
  if (inFlight >= MAX_IN_FLIGHT) return
  inFlight++
  const at = Date.now()
  const order = ++seq
  try {
    const dir = await readHome($)
    if (!dir) return
    const id = sid ?? (await $.session.id())
    const fields = typeof data === 'function' ? data(id) : data
    await $.http.fetch(URL, {
      body: JSON.stringify({ at, kind, seq: order, sid: id, v: VERSION, ...fields }),
      headers: { 'content-type': 'application/json' },
      method: 'POST',
      socketPath: `${dir}${SOCKET}`,
    })
  } catch {
    // Bifrost is not open, or the socket does not answer. Show nothing.
  } finally {
    inFlight--
  }
}

// Send the model, the context, the cost and the rate limits. The promise never rejects.
// Without figures, the mod reads them from $.session.usage().
// The line also has the Claude Code version and the values of the newest classic.Stop input of
// its session, when the mod knows them. The values come from the session ID of the line.
async function sendUsage($: EngineInterface, figures?: Figures) {
  // The line would be dropped. So do not read the usage.
  if (inFlight >= MAX_IN_FLIGHT) return
  try {
    const [model, usage, version] = await Promise.all([
      $.session.model().catch(() => undefined),
      figures ?? $.session.usage(),
      readVersion($),
    ])
    const { percent, tokens, window } = usage.context
    const rateLimits = usage.rateLimits.map(limit => ({
      kind: cut(limit.kind),
      percentUsed: limit.percentUsed,
      resetsAt: cutKnown(limit.resetsAt),
    }))
    await send($, 'usage', sid => {
      const kept = details.get(sid) ?? {}
      return {
        context: { percent, tokens, window },
        costUsd: usage.cost?.usd,
        effort: cutKnown(kept.effort),
        model: cutKnown(model),
        permissionMode: cutKnown(kept.permissionMode),
        rateLimits,
        transcriptPath: cutKnown(kept.transcriptPath, TRANSCRIPT_PATH_MAX),
        version: cutKnown(version),
      }
    })
  } catch {
    // The engine gave no usage. Send nothing.
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    void send($, 'session.start')
    void sendUsage($)
    $.clock.every(HEARTBEAT_MS, () => void sendUsage($))
    return result
  }).catch((_, e, next) => next(e))

  // This is the only hook that waits for its send. It waits for at most END_WAIT_MS.
  on('session.end', async ($, e, next) => {
    // The values of the ending session go away before any other step.
    details.delete(e.sessionId)
    const result = await next(e)
    await Promise.race([
      send($, 'session.end', { reason: cut(e.reason) }, e.sessionId),
      $.clock.sleep(END_WAIT_MS).catch(() => {}),
    ])
    // After /clear, the same process runs the new session. No session.start comes for it.
    if (e.reason === 'clear') $.clock.after(CLEAR_USAGE_DELAY_MS, () => void sendUsage($))
    return result
  }).catch((_, e, next) => next(e))

  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined) void send($, 'turn.start')
    return next(e)
  }).catch((_, e, next) => next(e))

  on('turn.complete', ($, e, next) => {
    if (e.agentId === undefined) {
      void send($, 'turn.complete', { answer: cut(e.answer, ANSWER_MAX), reason: cut(e.reason) })
      $.clock.after(USAGE_DELAY_MS, () => void sendUsage($))
    }
    return next(e)
  }).catch((_, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    if (e.tool === 'AskUserQuestion') void send($, 'ask')
    const result = await next(e)
    void send($, 'tool.done', { tool: cut(e.tool) })
    return result
  }).catch((_, e, next) => next(e))

  on('session.measure', ($, e, next) => {
    void sendUsage($, e)
    return next(e)
  }).catch((_, e, next) => next(e))

  on('classic.PermissionRequest', ($, e, next) => {
    void send($, 'permission', { tool: cut(e.tool_name) })
    return next(e)
  }).catch((_, e, next) => next(e))

  on('classic.StopFailure', ($, e, next) => {
    void send($, 'stop.failure', { error: cut(e.error) })
    return next(e)
  }).catch((_, e, next) => next(e))

  // Keep the effort, the permission mode and the transcript path for the next usage line of the
  // same session. This hook sends nothing and waits for nothing.
  on('classic.Stop', (_, e, next) => {
    if (typeof e.session_id === 'string') {
      const kept = details.get(e.session_id) ?? {}
      if (typeof e.effort?.level === 'string') kept.effort = e.effort.level
      if (typeof e.permission_mode === 'string') kept.permissionMode = e.permission_mode
      if (typeof e.transcript_path === 'string') kept.transcriptPath = e.transcript_path
      details.set(e.session_id, kept)
    }
    return next(e)
  }).catch((_, e, next) => next(e))
}
