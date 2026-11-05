import { childEnv } from '../child-env'

export interface PtyProcess {
  pid: number
  write(data: string): void
  resize(cols: number, rows: number): void
  kill(signal?: string): void
  onData(cb: (chunk: string) => void): void
  onExit(cb: (e: { exitCode: number; signal?: number }) => void): void
}

export type SpawnFn = (
  file: string,
  args: string[],
  opts: { cwd: string; cols: number; rows: number; env: Record<string, string> },
) => PtyProcess

const CLOSE_SIGNALS = ['SIGHUP', 'SIGTERM']

// PtyManager starts and controls one PTY for each view.
// It runs only the one program that the caller gives to the constructor.
// Each PTY gets the clean child env, made from baseEnv (the login-shell env).
export class PtyManager {
  private readonly ptys = new Map<string, PtyProcess>()
  private dataCb: (viewId: string, chunk: string) => void = () => {}
  private exitCb: (viewId: string, exitCode: number, signal?: number) => void = () => {}
  private closeCb: (viewId: string) => void = () => {}

  constructor(
    private readonly spawn: SpawnFn,
    private readonly file: string,
    private readonly baseEnv: NodeJS.ProcessEnv,
  ) {}

  open(viewId: string, args: string[], opts: { cwd: string; cols: number; rows: number }): number {
    // A view ID has one PTY only. Close the old PTY first.
    this.close(viewId)
    const env = childEnv(this.baseEnv, { pty: true })
    const proc = this.spawn(this.file, args, { ...opts, env })
    this.ptys.set(viewId, proc)
    proc.onData(chunk => {
      // Ignore data from a PTY that this view no longer uses.
      if (this.ptys.get(viewId) === proc) this.dataCb(viewId, chunk)
    })
    proc.onExit(e => {
      // An old PTY must not remove the new PTY of the same view.
      if (this.ptys.get(viewId) !== proc) return
      this.ptys.delete(viewId)
      this.exitCb(viewId, e.exitCode, e.signal)
    })
    return proc.pid
  }

  // True when the view has a PTY. A close and an exit remove the PTY of the view.
  has(viewId: string): boolean {
    return this.ptys.has(viewId)
  }

  write(viewId: string, data: string): boolean {
    const proc = this.ptys.get(viewId)
    if (!proc) return false
    proc.write(data)
    return true
  }

  resize(viewId: string, cols: number, rows: number): void {
    const proc = this.ptys.get(viewId)
    if (!proc || cols < 1 || rows < 1) return
    proc.resize(cols, rows)
  }

  // Remove the PTY of the view, then kill it.
  // close accepts only SIGHUP and SIGTERM. Any other value gives SIGHUP.
  // For an unknown signal name, node-pty ignores the error and the PTY stays alive.
  close(viewId: string, signal?: string): void {
    const proc = this.ptys.get(viewId)
    if (!proc) return
    this.ptys.delete(viewId)
    // The exit callback does not run after a close. So this callback tells that the PTY ended.
    // It also runs for closeAll and for an open that replaces a PTY.
    this.closeCb(viewId)
    const sig = signal !== undefined && CLOSE_SIGNALS.includes(signal) ? signal : 'SIGHUP'
    try {
      proc.kill(sig)
    } catch {
      // The process can be gone already. closeAll must go on to the next PTY.
    }
  }

  closeAll(): void {
    for (const viewId of [...this.ptys.keys()]) this.close(viewId)
  }

  onData(cb: (viewId: string, chunk: string) => void): void {
    this.dataCb = cb
  }

  onExit(cb: (viewId: string, exitCode: number, signal?: number) => void): void {
    this.exitCb = cb
  }

  // Runs each time close removes a PTY, before the kill.
  onClose(cb: (viewId: string) => void): void {
    this.closeCb = cb
  }
}
