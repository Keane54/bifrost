// The updater service (updater design sections 4 and 5). It checks the GitHub releases for a new
// version. electron-updater then downloads the version, and the service installs it when the
// user clicks. The service keeps the update state, writes the update log, reports each check to
// the health log, and sends each new snapshot to the page.
// This file has no Electron import. ipc.ts gives it the real autoUpdater and the other deps.
import { dirname } from 'node:path'
import {
  causeText,
  UPDATE_TEXTS,
  type UpdateCause,
  type UpdateState,
  type UpdatesSnapshot,
} from '../../shared/updates'
import type { HealthEvents, PollResult } from '../performance/health-log'
import {
  CHECK_DELAY_MS,
  CHECK_INTERVAL_MS,
  classifyError,
  locationProblem,
  maskToken,
} from './rules'
import type { UpdateStateStore } from './state-store'
import type { UpdateLog } from './update-log'

// The releases are in a public repo. So a check needs no login and no token.
export const UPDATE_OWNER = 'Keane54'
export const UPDATE_REPO = 'bifrost'

// The limit of the detail in an offline log line. classifyError uses the same limit.
const DETAIL_MAX = 200
// The download steps that get a log line.
const LOG_STEP = 25
const LOG_STEP_MAX = 75

export type UpdaterEvent =
  | 'checking-for-update'
  | 'update-available'
  | 'update-not-available'
  | 'download-progress'
  | 'update-downloaded'
  | 'error'

// The part of electron-updater's autoUpdater that the service uses.
export interface UpdaterEngine {
  autoDownload: boolean
  autoInstallOnAppQuit: boolean
  setFeedURL(options: { provider: 'github'; owner: string; repo: string }): void
  checkForUpdates(): Promise<unknown>
  quitAndInstall(): void
  on(event: UpdaterEvent, listener: (arg?: unknown) => void): void
}

type TimeoutTimer = ReturnType<typeof setTimeout>
type IntervalTimer = ReturnType<typeof setInterval>

export interface UpdaterDeps {
  engine: UpdaterEngine
  // The version of the running app.
  version: string
  // The .app folder of the running app.
  appPath: string
  // True when the app can write to the folder.
  canWrite(path: string): Promise<boolean>
  online(): boolean
  // Milliseconds since the epoch (Date.now in the app).
  now(): number
  setTimeout(fn: () => void, ms: number): TimeoutTimer
  clearTimeout(timer: TimeoutTimer): void
  setInterval(fn: () => void, ms: number): IntervalTimer
  clearInterval(timer: IntervalTimer): void
  // The service reads the settings at each use, so a change applies at once.
  settings(): { autoUpdate: boolean; notifications: boolean }
  // True when the Bifrost window has the focus.
  focused(): boolean
  notify(title: string, body: string, onClick: () => void): void
  showWindow(): void
  log: UpdateLog
  health: Pick<HealthEvents, 'poll' | 'stopped'>
  store: UpdateStateStore
  emit(s: UpdatesSnapshot): void
}

export interface Updater {
  // Set the engine options and the first state. With autoUpdate on, start the check timers.
  start(): void
  // Stop the timers. The service then ignores the engine events.
  stop(): void
  // Check one time, also when autoUpdate is off. No second check starts during a check or a
  // download.
  checkNow(): Promise<void>
  // Install the ready update and restart. Only when an update is ready.
  restart(): void
  // The switch "Check for updates automatically" changed.
  setAuto(on: boolean): void
  snapshot(): UpdatesSnapshot
}

// The step of an update when an error comes. classifyError uses it to find the cause.
type Phase = 'check' | 'download' | 'install'

const IDLE: UpdateState = { kind: 'idle' }
const OFF: UpdateState = { kind: 'off' }
const CHECKING: UpdateState = { kind: 'checking' }

function messageOf(err: unknown): string {
  if (err instanceof Error) return err.message
  if (typeof err === 'string') return err
  if (typeof err === 'object' && err !== null && 'message' in err) {
    return typeof err.message === 'string' ? err.message : ''
  }
  return ''
}

function firstLine(text: string): string {
  return (text.trim().split('\n')[0] ?? '').slice(0, DETAIL_MAX)
}

// The version of an engine event, or an empty text.
function versionOf(info: unknown): string {
  if (typeof info !== 'object' || info === null || !('version' in info)) return ''
  return typeof info.version === 'string' ? info.version : ''
}

// The download percent of a download-progress event, rounded down, from 0 to 100.
function percentOf(progress: unknown): number {
  if (typeof progress !== 'object' || progress === null || !('percent' in progress)) return 0
  const { percent } = progress
  if (typeof percent !== 'number' || Number.isNaN(percent)) return 0
  return Math.min(100, Math.max(0, Math.floor(percent)))
}

// A state with no check and no download in it.
function settled(state: UpdateState): UpdateState {
  return state.kind === 'checking' || state.kind === 'downloading' ? IDLE : state
}

// electron-updater gives the download promise in the check result. A failed download also
// sends an error event. So the service catches the promise, or Node reports an unhandled
// rejection.
function quietDownload(result: unknown): void {
  if (typeof result !== 'object' || result === null || !('downloadPromise' in result)) return
  Promise.resolve(result.downloadPromise).catch(() => {})
}

export function createUpdater(deps: UpdaterDeps): Updater {
  let state: UpdateState = IDLE
  // The time of the last good check.
  let lastCheckAt: number | null = null
  // The state before the newest check. An offline error goes back to it.
  let before: UpdateState = IDLE
  let phase: Phase = 'check'
  // The version of the newest update-available event.
  let pending = ''
  // The highest download step in the log for the current download.
  let loggedStep = 0
  // True from the start of a check until the engine check ends.
  let busy = false
  // True from a restart click until the quit, or until an error.
  let restarting = false
  let started = false
  let stopped = false
  // The count of the errors that the service handled. A check uses it to see if the engine
  // sent an error event for its own failure.
  let errors = 0
  let delayTimer: TimeoutTimer | null = null
  let intervalTimer: IntervalTimer | null = null

  // The updater uses no token. But an error can quote a URL or a header with a token. So each
  // text goes through maskToken before it goes to the state, a snapshot or the log.
  const mask = (text: string): string => maskToken(text, null)

  function snapshot(): UpdatesSnapshot {
    return { available: true, lastCheckAt, state, version: deps.version }
  }

  // The log never rejects.
  function line(text: string): void {
    void deps.log.line(mask(text))
  }

  // Set the state, send the snapshot, and write one log line.
  function change(next: UpdateState, text: string | null): void {
    state = next
    deps.emit(snapshot())
    if (text !== null) line(text)
  }

  function fail(cause: UpdateCause, detail: string, result: PollResult): void {
    const masked = mask(detail)
    const text = `error ${cause}: ${masked}`
    deps.health.poll('updates', result)
    // While an update is ready, a failed check does not hide the ready button.
    if (state.kind === 'ready' && phase === 'check') {
      line(text)
      return
    }
    change({ at: deps.now(), cause, kind: 'failed', message: causeText(cause, masked) }, text)
  }

  function onError(err: unknown): void {
    if (stopped) return
    errors += 1
    restarting = false
    // Mask the full text before classifyError cuts it, so no part of a token stays.
    const text = mask(messageOf(err))
    const found = classifyError(text, phase, deps.online())
    if (found.kind === 'failed') {
      fail(found.cause, found.detail, found.cause === 'no-access' ? 'no-data' : 'failed')
      return
    }
    // No network is not a failure. The next check tries again.
    deps.health.poll('updates', 'no-data')
    const note = `offline: ${firstLine(text)}`
    if (state.kind === 'checking' || state.kind === 'downloading') change(before, note)
    else line(note)
  }

  // One notification for each version. A notification that the rules hold back is not sent
  // later, because the version is recorded also then.
  function notifyOnce(version: string): void {
    if (deps.store.get().notifiedVersion === version) return
    const { notifications } = deps.settings()
    if (notifications && !deps.focused()) {
      deps.notify(UPDATE_TEXTS.notifyTitle, UPDATE_TEXTS.ready(version), () => {
        deps.showWindow()
        restart()
      })
    }
    void deps.store.set({ notifiedVersion: version })
  }

  deps.engine.on('checking-for-update', () => {
    if (stopped) return
    phase = 'check'
    if (state.kind === 'checking' || state.kind === 'ready') return
    before = settled(state)
    change(CHECKING, 'check')
  })

  deps.engine.on('update-not-available', () => {
    if (stopped) return
    lastCheckAt = deps.now()
    deps.health.poll('updates', 'ok')
    change(state.kind === 'ready' ? state : IDLE, 'no update')
  })

  deps.engine.on('update-available', info => {
    if (stopped) return
    const version = versionOf(info)
    pending = version
    phase = 'download'
    loggedStep = 0
    // The same version again: electron-updater uses the file that it has. The update stays ready.
    if (state.kind === 'ready' && state.version === version) {
      line(`found ${version}`)
      return
    }
    change({ kind: 'downloading', percent: 0, version }, `found ${version}`)
  })

  deps.engine.on('download-progress', progress => {
    if (stopped || state.kind === 'ready') return
    const percent = percentOf(progress)
    const step = Math.min(LOG_STEP_MAX, Math.floor(percent / LOG_STEP) * LOG_STEP)
    const logStep = step > loggedStep
    if (logStep) loggedStep = step
    if (!logStep && state.kind === 'downloading' && state.percent === percent) return
    change({ kind: 'downloading', percent, version: pending }, logStep ? `download ${step}%` : null)
  })

  deps.engine.on('update-downloaded', info => {
    if (stopped) return
    const version = versionOf(info) || pending
    // The macOS install engine still checks the update after this event. Its error is a
    // download error, and it must clear the ready state.
    phase = 'download'
    lastCheckAt = deps.now()
    deps.health.poll('updates', 'ok')
    change({ kind: 'ready', version }, `ready ${version}`)
    notifyOnce(version)
  })

  deps.engine.on('error', onError)

  // A check with no result event must not stay at checking, or no later check can start.
  function endCheck(): void {
    busy = false
    if (!stopped && state.kind === 'checking') change(before, 'check ended with no result')
  }

  async function check(): Promise<void> {
    if (stopped || busy || restarting) return
    if (state.kind === 'checking' || state.kind === 'downloading') return
    busy = true
    phase = 'check'
    before = state
    // While an update is ready, the ready button stays during the check.
    if (state.kind === 'ready') line('check')
    else change(CHECKING, 'check')
    const handled = errors
    try {
      const writable = await deps.canWrite(dirname(deps.appPath)).catch(() => false)
      if (stopped) return
      if (locationProblem(deps.appPath, writable)) {
        // The user must move the app. This is not a failure of the check itself.
        fail('location', deps.appPath, 'no-data')
        return
      }
      deps.engine.setFeedURL({ owner: UPDATE_OWNER, provider: 'github', repo: UPDATE_REPO })
      quietDownload(await deps.engine.checkForUpdates())
    } catch (error) {
      // electron-updater sends an error event before the promise rejects. This covers an engine
      // that does not.
      if (errors === handled) onError(error)
    } finally {
      endCheck()
    }
  }

  function clearTimers(): void {
    if (delayTimer !== null) deps.clearTimeout(delayTimer)
    if (intervalTimer !== null) deps.clearInterval(intervalTimer)
    delayTimer = null
    intervalTimer = null
  }

  // The first check comes CHECK_DELAY_MS after this call. Then a check comes at each
  // CHECK_INTERVAL_MS.
  function schedule(): void {
    clearTimers()
    delayTimer = deps.setTimeout(() => {
      delayTimer = null
      intervalTimer = deps.setInterval(() => void check(), CHECK_INTERVAL_MS)
      void check()
    }, CHECK_DELAY_MS)
  }

  // Record the attempt and the log line before the quit. The next start compares the versions.
  async function install(version: string): Promise<void> {
    await deps.store.set({ attemptedVersion: version }).catch(() => {})
    await deps.log.line(mask(`install ${version}`))
    try {
      deps.engine.quitAndInstall()
    } catch (error) {
      onError(error)
    }
  }

  function restart(): void {
    if (stopped || restarting || state.kind !== 'ready') return
    restarting = true
    phase = 'install'
    void install(state.version)
  }

  return {
    checkNow: check,
    restart,
    setAuto(on) {
      if (stopped) return
      if (on) {
        if (state.kind === 'off') change(IDLE, 'auto on')
        else line('auto on')
        schedule()
        return
      }
      clearTimers()
      deps.health.stopped('updates')
      // The switch clears the triangle. A ready update stays, and it installs at the quit.
      if (state.kind === 'failed' || state.kind === 'idle') change(OFF, 'auto off')
      else line('auto off')
    },
    snapshot,
    start() {
      if (started || stopped) return
      started = true
      deps.engine.autoDownload = true
      deps.engine.autoInstallOnAppQuit = true
      const { attemptedVersion } = deps.store.get()
      const { autoUpdate } = deps.settings()
      if (attemptedVersion !== null && attemptedVersion !== deps.version) {
        const failed: UpdateState = {
          at: deps.now(),
          cause: 'install',
          kind: 'failed',
          message: causeText('install', ''),
        }
        change(failed, `error install: ${attemptedVersion} did not install`)
      } else {
        // The app runs the version that it tried to install. So the install worked.
        if (attemptedVersion !== null) void deps.store.set({ attemptedVersion: null })
        change(autoUpdate ? IDLE : OFF, null)
      }
      if (autoUpdate) schedule()
    },
    stop() {
      stopped = true
      clearTimers()
    },
  }
}
