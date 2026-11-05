// Read and signal processes, and read a directory, for the session actions.
// The kill, exec and stat functions are parameters, so the tests send no signal.
import type { DirInfo } from '../../shared/new-session'
import type { ExecFn } from '../claude/cli'

// The time limit of each ps, git and stat read.
export const PROBE_TIMEOUT_MS = 2000

export type KillFn = (pid: number, signal: string | number) => void
export type StatFn = (path: string) => Promise<{ isDirectory(): boolean }>

// A PID that Bifrost can signal. The PID 0 signals the process group of Bifrost.
// The PID -1 signals all processes of the user. The PID 1 is launchd.
export function isSafePid(pid: number): boolean {
  return Number.isInteger(pid) && pid > 1
}

// Send the signal to the PID. This throws for a PID that is not safe.
export function sendSignal(kill: KillFn, pid: number, signal: 'SIGTERM'): void {
  if (!isSafePid(pid)) throw new Error('refused: bad process ID')
  kill(pid, signal)
}

// True when the process exists. Signal 0 sends no signal. It only checks the process.
// EPERM: the process exists and belongs to another user. Another error also gives true,
// and a PID that is not safe gives true. Then Take control starts no copy of the session.
export function isAlive(kill: KillFn, pid: number): boolean {
  if (!isSafePid(pid)) return true
  try {
    kill(pid, 0)
    return true
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== 'ESRCH'
  }
}

// The executable path of a process, or null when ps cannot read it.
export async function processName(exec: ExecFn, pid: number): Promise<string | null> {
  if (!isSafePid(pid)) return null
  const result = await exec('/bin/ps', ['-o', 'comm=', '-p', String(pid)], {
    timeoutMs: PROBE_TIMEOUT_MS,
  })
  const name = result.stdout.trim()
  return result.code === 0 && name !== '' ? name : null
}

// Resolve with the value of the promise, or with the fallback after ms.
function within<T>(promise: Promise<T>, ms: number, fallback: T): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const limit = new Promise<T>(resolve => {
    timer = setTimeout(() => resolve(fallback), ms)
  })
  return Promise.race([promise, limit]).finally(() => clearTimeout(timer))
}

// What is at the path, and for a directory, whether it is in a git repository.
// A stat that does not end in time gives "missing", for example on an offline network volume.
export async function dirInfo(exec: ExecFn, stat: StatFn, dir: string): Promise<DirInfo> {
  const read = stat(dir).then(
    (s): DirInfo['kind'] => (s.isDirectory() ? 'dir' : 'other'),
    (): DirInfo['kind'] => 'missing',
  )
  const kind = await within(read, PROBE_TIMEOUT_MS, 'missing')
  if (kind !== 'dir') return { git: false, kind }
  const result = await exec('git', ['-C', dir, 'rev-parse', '--show-toplevel'], {
    timeoutMs: PROBE_TIMEOUT_MS,
  })
  return { git: result.code === 0, kind }
}
