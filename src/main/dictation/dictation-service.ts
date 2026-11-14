// The dictation service (dictation design). It runs the speech helper (native/dictation) and gives
// its events to the chat view that dictates.
//
// The helper:
// - A warm call or a start starts the helper when none runs. The helper stops when 5 minutes pass
//   with no warm call or start. It never stops for this rule while it downloads the speech model
//   or while a view dictates.
// - The helper fails when it gives no ready in 10 s, stops by itself, gives more than 10 bad lines,
//   or gives no end in 5 s after a stop. A downloading line counts in place of ready, and each one
//   starts the 10 s again. The 5 s of a stop start only when the helper is ready, because the
//   helper does a stop only after its boot. The next warm or start then starts a new helper.
// - An error in place of ready also ends the helper. Then only a start starts a new helper, and a
//   warm does not. So each focus of a chat does not start a new model download.
// - When the build has no helper, for example a dev run with no helper build, a warm does
//   nothing, and a start gives the error no-helper at once.
//
// The dictations:
// - One dictation at a time. A start of another view stops the dictation of the first view.
// - The events go only to the view that started. After a start, the view gets ready (when the
//   helper is ready), downloading, level and text. A stop ends the level and text events. Then
//   the view gets one end: the end of the helper, or the text so far when no end comes in 2 s.
//   The helper gives its end in about 1.5 s, so the 2 s give a margin.
// - A start during a model download opens no session, and the helper answers with a downloading
//   line. That dictation gets the downloading events and its end, but no ready (ruling D6). At
//   the ready of the helper, it gets model-ready, so the view can tell the user to hold again.
//   The service never sends start again by itself. A new hold after ready opens the microphone.
//   When the download ends just before the helper does the start, the helper opens a session.
//   Then the view gets ready before the first level or text (ruling D6a).
// - An error of the helper ends the dictation with the error in place of the end, also when it
//   comes after the stop but before the end. A failed helper gives the error failed.
// - A dictation stops after 2 minutes.
// - After its end or its error, a view gets no more events of that dictation. A new start of the
//   same view before its end drops that end.
import type { ChildProcess } from 'node:child_process'
import {
  type DictationViewEvent,
  type HelperCommand,
  type HelperEvent,
  MAX_HELPER_LINE,
  parseHelperLine,
} from '../../shared/dictation-protocol'

export const IDLE_MS = 5 * 60_000
export const READY_LIMIT_MS = 10_000
export const STOP_WAIT_MS = 2_000
export const END_LIMIT_MS = 5_000
export const HOLD_LIMIT_MS = 2 * 60_000
export const MAX_BAD_LINES = 10

// A start for a chat view with no terminal. The typed text then has no target.
export const REFUSED_NO_TERMINAL = 'refused: the chat window has no terminal'

const NO_HELPER = "Bifrost can't find its speech helper."
const NO_START = "The speech helper couldn't start."
const NO_READY = "The speech helper didn't get ready in time."
const STOPPED = 'The speech helper stopped.'
const BAD_LINES = "Bifrost couldn't read the speech helper."
const NO_END = 'The speech helper stopped answering.'
const MODEL_READY: DictationViewEvent = { t: 'model-ready' }

type TimeoutTimer = ReturnType<typeof setTimeout>
type ReadyEvent = Extract<HelperEvent, { t: 'ready' }>

export interface DictationDeps {
  // Start the helper. Its stdin and stdout must be pipes.
  spawn(path: string): ChildProcess
  // The path of the helper, or null when no helper exists.
  path(): string | null
  now(): number
  setTimeout(fn: () => void, ms: number): TimeoutTimer
  clearTimeout(timer: TimeoutTimer): void
  // Give one event to a chat view.
  send(viewId: string, event: DictationViewEvent): void
}

export interface DictationService {
  // Keep the helper ready.
  warm(): void
  // Start the dictation of a chat view.
  start(viewId: string): void
  // Stop the dictation of the view. The view then gets its end.
  stop(viewId: string): void
  // Stop the helper at once. No view gets an event after it.
  stopAll(): void
}

// One dictation: from its start command to the end of its stop command.
interface Turn {
  viewId: string
  // True after the stop command.
  stopped: boolean
  // True when the view gets no more events of this turn.
  silent: boolean
  // True when the start got a downloading line. The helper then opened no session.
  downloadAnswer: boolean
  // The text so far: final and volatile of the last text event.
  text: string
  // Before the stop: the 2-minute limit. After the stop: the stop wait.
  timer: TimeoutTimer | null
  // The end limit of the stop. It runs only while the helper is ready.
  endTimer: TimeoutTimer | null
}

// One run of the helper.
interface Helper {
  child: ChildProcess
  ready: ReadyEvent | null
  downloading: boolean
  badLines: number
  // The part of a line that has no newline yet.
  buffer: string
  // True while the service drops the rest of a line over the limit.
  skipping: boolean
  readyTimer: TimeoutTimer | null
  idleTimer: TimeoutTimer | null
  // The turns with no end yet, in the order of their start commands. The helper does the commands
  // in order, so its text lines belong to the first turn.
  turns: Turn[]
}

const failed = (message: string): HelperEvent => ({ code: 'failed', message, t: 'error' })

export function createDictationService(deps: DictationDeps): DictationService {
  let helper: Helper | null = null
  // True after an error in place of ready. Then a warm starts no new helper.
  let bootFailed = false
  // The time of the last warm call or start.
  let lastUse = 0

  const clear = (timer: TimeoutTimer | null): null => {
    if (timer !== null) deps.clearTimeout(timer)
    return null
  }

  // The turn that dictates now: the last turn, before its stop.
  function owner(h: Helper): Turn | null {
    const last = h.turns.at(-1)
    return last !== undefined && !last.stopped ? last : null
  }

  function give(turn: Turn, event: DictationViewEvent): void {
    if (!turn.silent) deps.send(turn.viewId, event)
  }

  // Give the last event of a turn.
  function finish(turn: Turn, event: HelperEvent): void {
    give(turn, event)
    turn.silent = true
  }

  function write(h: Helper, command: HelperCommand): void {
    h.child.stdin?.write(`${command}\n`)
  }

  // Start the helper when none runs. Give null when no helper can start.
  function ensure(): Helper | null {
    if (helper !== null) return helper
    const path = deps.path()
    if (path === null) return null
    let child: ChildProcess
    try {
      child = deps.spawn(path)
    } catch {
      return null
    }
    const h: Helper = {
      badLines: 0,
      buffer: '',
      child,
      downloading: false,
      idleTimer: null,
      ready: null,
      readyTimer: null,
      skipping: false,
      turns: [],
    }
    helper = h
    bootFailed = false
    // A write to a helper that stopped fails. The exit event tells the service.
    child.stdin?.on('error', () => {})
    child.stdout?.on('error', () => {})
    child.stdout?.setEncoding('utf8')
    child.stdout?.on('data', (chunk: string) => read(h, chunk))
    child.on('error', () => {
      if (helper === h) fail(h, failed(NO_START))
    })
    child.on('exit', () => {
      if (helper === h) fail(h, failed(STOPPED))
    })
    armReady(h)
    armIdle(h, IDLE_MS)
    return h
  }

  function armReady(h: Helper): void {
    h.readyTimer = clear(h.readyTimer)
    h.readyTimer = deps.setTimeout(() => {
      h.readyTimer = null
      if (helper === h) fail(h, failed(NO_READY))
    }, READY_LIMIT_MS)
  }

  function armIdle(h: Helper, ms: number): void {
    h.idleTimer = deps.setTimeout(() => {
      h.idleTimer = null
      if (helper !== h) return
      const idle = deps.now() - lastUse
      if (h.downloading || h.turns.length > 0) armIdle(h, IDLE_MS)
      else if (idle >= IDLE_MS) retire(h)
      else armIdle(h, IDLE_MS - idle)
    }, ms)
  }

  // Stop the helper process and its timers. Its later lines and its exit do nothing.
  function retire(h: Helper): void {
    if (helper === h) helper = null
    h.readyTimer = clear(h.readyTimer)
    h.idleTimer = clear(h.idleTimer)
    for (const turn of h.turns) {
      turn.timer = clear(turn.timer)
      turn.endTimer = clear(turn.endTimer)
    }
    h.child.stdin?.end()
    h.child.kill('SIGTERM')
  }

  // End the helper. The view that dictates gets the error. A view that waits for its end gets
  // the text so far.
  function fail(h: Helper, error: HelperEvent): void {
    const turns = h.turns
    retire(h)
    h.turns = []
    for (const turn of turns) finish(turn, turn.stopped ? { final: turn.text, t: 'end' } : error)
  }

  // Split the output into lines. A line over the limit counts as one bad line.
  function read(h: Helper, chunk: string): void {
    let rest = chunk
    while (helper === h) {
      const index = rest.indexOf('\n')
      if (index === -1) {
        if (h.skipping) return
        h.buffer += rest
        if (h.buffer.length > MAX_HELPER_LINE) {
          h.buffer = ''
          h.skipping = true
          badLine(h)
        }
        return
      }
      const line = h.buffer + rest.slice(0, index)
      rest = rest.slice(index + 1)
      h.buffer = ''
      if (h.skipping) h.skipping = false
      else handle(h, line)
    }
  }

  function badLine(h: Helper): void {
    h.badLines += 1
    if (h.badLines > MAX_BAD_LINES) fail(h, failed(BAD_LINES))
  }

  function handle(h: Helper, line: string): void {
    const event = parseHelperLine(line)
    if (event === null) {
      badLine(h)
      return
    }
    const head = h.turns[0]
    const current = owner(h)
    switch (event.t) {
      case 'downloading':
        if (h.ready === null) {
          h.downloading = true
          armReady(h)
        }
        if (current !== null) {
          current.downloadAnswer = true
          give(current, event)
        }
        return
      case 'ready':
        h.ready = event
        h.downloading = false
        h.readyTimer = clear(h.readyTimer)
        // A start that got a downloading line opened no session (ruling D6).
        if (current !== null) give(current, current.downloadAnswer ? MODEL_READY : event)
        for (const turn of h.turns) if (turn.stopped) armEndLimit(h, turn)
        return
      case 'level':
      case 'text':
        if (head === undefined) return
        if (event.t === 'text') head.text = event.final + event.volatile
        if (head.stopped) return
        // The download ended just before the helper did the start, so a session opened. Give
        // ready first, so the view shows that the microphone is open (ruling D6a).
        if (head.downloadAnswer && h.ready !== null) {
          head.downloadAnswer = false
          give(head, h.ready)
        }
        give(head, event)
        return
      case 'end':
        // Each stop gives one end. An end with no stop is not for a turn.
        if (head === undefined || !head.stopped) return
        h.turns.shift()
        head.timer = clear(head.timer)
        head.endTimer = clear(head.endTimer)
        finish(head, event)
        return
      case 'error':
        if (h.ready === null) {
          fail(h, event)
          bootFailed = true
          return
        }
        if (head === undefined || head.silent) return
        finish(head, event)
        // The helper ends a failed session by itself. A stop also ends it, and gives the end.
        if (!head.stopped) stopTurn(h, head)
        return
    }
  }

  function stopTurn(h: Helper, turn: Turn): void {
    turn.stopped = true
    turn.timer = clear(turn.timer)
    write(h, 'stop')
    turn.timer = deps.setTimeout(() => {
      turn.timer = null
      finish(turn, { final: turn.text, t: 'end' })
    }, STOP_WAIT_MS)
    // Before ready, the ready limit runs. The ready event starts the end limit.
    if (h.ready !== null) armEndLimit(h, turn)
  }

  // A helper that gives no end in 5 s after a stop has failed.
  function armEndLimit(h: Helper, turn: Turn): void {
    if (turn.endTimer !== null) return
    turn.endTimer = deps.setTimeout(() => {
      turn.endTimer = null
      if (helper === h && h.turns.includes(turn)) fail(h, failed(NO_END))
    }, END_LIMIT_MS)
  }

  return {
    start(viewId) {
      lastUse = deps.now()
      if (helper !== null && owner(helper)?.viewId === viewId) return
      const h = ensure()
      if (h === null) {
        deps.send(viewId, { code: 'no-helper', message: NO_HELPER, t: 'error' })
        return
      }
      const first = owner(h)
      if (first !== null) stopTurn(h, first)
      // The new turn owns the events of the view. An old turn of the view gets no more events.
      for (const old of h.turns) if (old.viewId === viewId) old.silent = true
      const turn: Turn = {
        downloadAnswer: false,
        endTimer: null,
        silent: false,
        stopped: false,
        text: '',
        timer: null,
        viewId,
      }
      h.turns.push(turn)
      write(h, 'start')
      turn.timer = deps.setTimeout(() => {
        turn.timer = null
        if (helper === h && owner(h) === turn) stopTurn(h, turn)
      }, HOLD_LIMIT_MS)
      if (h.ready !== null) give(turn, h.ready)
    },
    stop(viewId) {
      if (helper === null) return
      const turn = owner(helper)
      if (turn?.viewId === viewId) stopTurn(helper, turn)
    },
    stopAll() {
      const h = helper
      if (h === null) return
      for (const turn of h.turns) turn.silent = true
      retire(h)
      h.turns = []
    },
    warm() {
      lastUse = deps.now()
      if (helper === null && bootFailed) return
      ensure()
    },
  }
}
