// The terminal size of a session, as other clients set it (M3 Task 1, method P1).
// Bifrost only reads. It runs "ps" and "stty -f <device> size". It never writes to a TTY.
import type { TermSize } from '../../shared/types'
import type { ExecFn } from '../claude/cli'

const CHAT_PREFIX = 'chat:'

export function psTtyArgs(pid: number): string[] {
  return ['-o', 'tty=', '-p', String(pid)]
}

// The only stty form in the code. It reads the size.
export function sttyArgs(device: string): string[] {
  return ['-f', device, 'size']
}

// "ttys012" gives "/dev/ttys012". "??", an empty value and other text give null.
export function parsePsTty(stdout: string): string | null {
  const tty = stdout.trim()
  return /^ttys\d+$/.test(tty) ? `/dev/${tty}` : null
}

// stty prints "<rows> <cols>".
export function parseSttySize(stdout: string): TermSize | null {
  const m = /^(\d+) (\d+)$/.exec(stdout.trim())
  if (!m) return null
  const rows = Number(m[1])
  const cols = Number(m[2])
  return rows > 0 && cols > 0 ? { cols, rows } : null
}

export async function readSessionSize(exec: ExecFn, pid: number): Promise<TermSize | null> {
  const ps = await exec('/bin/ps', psTtyArgs(pid))
  if (ps.code !== 0) return null
  const device = parsePsTty(ps.stdout)
  if (!device) return null
  const stty = await exec('/bin/stty', sttyArgs(device))
  return stty.code === 0 ? parseSttySize(stty.stdout) : null
}

const DEFAULT_TTL_MS = 30_000

// A reader that keeps the TTY device of each pid for the TTL. The device of a pid does not
// change, so ps runs one time for many reads. The TTL limits the risk of a pid that a new process
// reuses. A failed stty drops the device, so the next read runs ps again.
export function createSessionSizeReader(
  exec: ExecFn,
  opts: { ttlMs?: number; now?: () => number } = {},
): (pid: number) => Promise<TermSize | null> {
  const ttlMs = opts.ttlMs ?? DEFAULT_TTL_MS
  const now = opts.now ?? (() => Date.now())
  const devices = new Map<number, { device: string; at: number }>()
  return async pid => {
    const kept = devices.get(pid)
    let device = kept && now() - kept.at < ttlMs ? kept.device : null
    if (device === null) {
      devices.delete(pid)
      const ps = await exec('/bin/ps', psTtyArgs(pid))
      device = ps.code === 0 ? parsePsTty(ps.stdout) : null
      if (device === null) return null
      devices.set(pid, { at: now(), device })
    }
    const stty = await exec('/bin/stty', sttyArgs(device))
    if (stty.code !== 0) {
      devices.delete(pid)
      return null
    }
    return parseSttySize(stty.stdout)
  }
}

// The session ID of a chat view ID, or null for another view.
export function chatSessionOf(viewId: string): string | null {
  return viewId.startsWith(CHAT_PREFIX) && viewId.length > CHAT_PREFIX.length
    ? viewId.slice(CHAT_PREFIX.length)
    : null
}

export interface SizeWatcherDeps {
  read(pid: number): Promise<TermSize | null>
  pidOf(viewId: string): number | undefined
  emit(viewId: string, size: TermSize): void
}

interface ViewState {
  timer: ReturnType<typeof setTimeout> | undefined
  running: boolean
  again: boolean
  last: TermSize | null
}

// Reads the size after a poke and emits it when it changed.
export class SessionSizeWatcher {
  private readonly views = new Map<string, ViewState>()

  constructor(
    private readonly deps: SizeWatcherDeps,
    private readonly debounceMs = 150,
  ) {}

  // Start one read, debounceMs after the last poke of this view.
  poke(viewId: string): void {
    const state = this.stateOf(viewId)
    clearTimeout(state.timer)
    state.timer = setTimeout(() => {
      state.timer = undefined
      void this.run(viewId, state)
    }, this.debounceMs)
  }

  forget(viewId: string): void {
    const state = this.views.get(viewId)
    if (!state) return
    clearTimeout(state.timer)
    this.views.delete(viewId)
  }

  private stateOf(viewId: string): ViewState {
    let state = this.views.get(viewId)
    if (!state) {
      state = { again: false, last: null, running: false, timer: undefined }
      this.views.set(viewId, state)
    }
    return state
  }

  private async run(viewId: string, state: ViewState): Promise<void> {
    // One read at a time. A poke during a read causes one more read after it.
    if (state.running) {
      state.again = true
      return
    }
    const pid = this.deps.pidOf(viewId)
    if (pid === undefined) return
    state.running = true
    try {
      const size = await this.deps.read(pid)
      // forget removes the state. Then the result is old.
      // A null read keeps the last size. The renderer keeps the old size after the session ends.
      if (this.views.get(viewId) !== state || !size) return
      const last = state.last
      if (last && last.cols === size.cols && last.rows === size.rows) return
      state.last = size
      this.deps.emit(viewId, size)
    } catch {
      // A failed read has no effect. The next poke reads again.
    } finally {
      state.running = false
      if (state.again && this.views.get(viewId) === state) {
        state.again = false
        this.poke(viewId)
      }
    }
  }
}
