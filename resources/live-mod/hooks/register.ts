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
const USAGE_DELAY_MS = 2500
const HEARTBEAT_MS = 30_000
const END_WAIT_MS = 200

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

// The order number of each line. It increases for each send of this module load.
let seq = 0
// HOME, read one time for each module load.
let home: Promise<string | undefined> | undefined

function cut(value: unknown, max = TEXT_MAX): string {
  return String(value).slice(0, max)
}

function readHome($: EngineInterface): Promise<string | undefined> {
  home ??= $.env.get('HOME').catch(() => undefined)
  return home
}

// Send one line. The promise never rejects.
async function send($: EngineInterface, kind: Kind, data: Data = {}, sid?: string) {
  const at = Date.now()
  const order = ++seq
  try {
    const dir = await readHome($)
    if (!dir) return
    const id = sid ?? (await $.session.id())
    await $.http.fetch(URL, {
      body: JSON.stringify({ at, kind, seq: order, sid: id, v: VERSION, ...data }),
      headers: { 'content-type': 'application/json' },
      method: 'POST',
      socketPath: `${dir}${SOCKET}`,
    })
  } catch {
    // Bifrost is not open, or the socket does not answer. Show nothing.
  }
}

// Send the model, the context, the cost and the rate limits. The promise never rejects.
// Without figures, the mod reads them from $.session.usage().
async function sendUsage($: EngineInterface, figures?: Figures) {
  try {
    const [model, usage] = await Promise.all([
      $.session.model().catch(() => undefined),
      figures ?? $.session.usage(),
    ])
    const { percent, tokens, window } = usage.context
    await send($, 'usage', {
      context: { percent, tokens, window },
      costUsd: usage.cost?.usd,
      model: model === undefined ? undefined : cut(model),
      rateLimits: usage.rateLimits.map(limit => ({
        kind: cut(limit.kind),
        percentUsed: limit.percentUsed,
        resetsAt: limit.resetsAt === undefined ? undefined : cut(limit.resetsAt),
      })),
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
    const result = await next(e)
    await Promise.race([
      send($, 'session.end', { reason: cut(e.reason) }, e.sessionId),
      $.clock.sleep(END_WAIT_MS).catch(() => {}),
    ])
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
}
