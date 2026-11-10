import { EventEmitter } from 'node:events'
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { CHECK_DELAY_MS, CHECK_INTERVAL_MS } from '../../../src/main/updates/rules'
import {
  EMPTY_UPDATE_STATE,
  type UpdateStateData,
  type UpdateStateStore,
} from '../../../src/main/updates/state-store'
import {
  createUpdater,
  RESTART_LIMIT_MS,
  UPDATE_OWNER,
  UPDATE_REPO,
  type Updater,
  type UpdaterDeps,
  type UpdaterEngine,
} from '../../../src/main/updates/updater'
import {
  causeText,
  UPDATE_TEXTS,
  type UpdateState,
  type UpdatesSnapshot,
} from '../../../src/shared/updates'

const NOW = Date.parse('2026-11-10T10:00:00Z')
const APP = '/Applications/Bifrost.app'
// Two token-like texts. The updater uses no token, but an error can quote one.
const TOKEN = `gho_${'A1b2C3d4'.repeat(4)}`
const PAT = `ghp_${'Z9'.repeat(15)}`
// The record of a restart click on 1.0.0 that tried to install 1.1.0.
const ATTEMPT = { attemptedFrom: '1.0.0', attemptedVersion: '1.1.0' }
const INSTALL_FAILED: UpdateState = {
  at: NOW,
  cause: 'install',
  kind: 'failed',
  message: causeText('install', ''),
}

// The part of electron-updater that the service uses. The test sends the events.
class FakeEngine extends EventEmitter implements UpdaterEngine {
  autoDownload = false
  autoInstallOnAppQuit = false
  setFeedURL = vi.fn()
  // The default check finds no update.
  checkForUpdates = vi.fn(async (): Promise<unknown> => {
    this.emit('checking-for-update')
    this.emit('update-not-available', { version: '1.0.0' })
    return { isUpdateAvailable: false }
  })
  quitAndInstall = vi.fn()
}

// The check finds a version and starts the download. The test ends the download.
// It gives the cancellation token of the download.
function finds(engine: FakeEngine, version: string): { cancel: ReturnType<typeof vi.fn> } {
  const cancellationToken = { cancel: vi.fn() }
  engine.checkForUpdates.mockImplementation(async () => {
    engine.emit('checking-for-update')
    engine.emit('update-available', { version })
    return { cancellationToken, downloadPromise: new Promise(() => {}), isUpdateAvailable: true }
  })
  return cancellationToken
}

// The check fails as in electron-updater: first an error event, then a rejected promise.
function failsWith(engine: FakeEngine, error: Error): void {
  engine.checkForUpdates.mockImplementation(async () => {
    engine.emit('checking-for-update')
    engine.emit('error', error)
    throw error
  })
}

type MemoryStore = UpdateStateStore & { set: ReturnType<typeof vi.fn> }

function memoryStore(initial: Partial<UpdateStateData> = {}): MemoryStore {
  let value: UpdateStateData = { ...EMPTY_UPDATE_STATE, ...initial }
  return {
    get: () => value,
    set: vi.fn(async (patch: Partial<UpdateStateData>) => {
      value = { ...value, ...patch }
    }),
  }
}

interface Options {
  appPath?: string
  autoUpdate?: boolean
  canWrite?: () => Promise<boolean>
  engine?: FakeEngine
  store?: MemoryStore
  version?: string
}

function setup(options: Options = {}) {
  const engine = options.engine ?? new FakeEngine()
  const store = options.store ?? memoryStore()
  const env = { autoUpdate: options.autoUpdate ?? true, focused: false, notifications: true }
  const net = { online: true }
  const lines: string[] = []
  const emitted: UpdatesSnapshot[] = []
  const health = { poll: vi.fn(), stopped: vi.fn() }
  const notify = vi.fn()
  const showWindow = vi.fn()
  const canWrite = vi.fn(options.canWrite ?? (async () => true))
  const deps: UpdaterDeps = {
    appPath: options.appPath ?? APP,
    canWrite,
    clearInterval: timer => clearInterval(timer),
    clearTimeout: timer => clearTimeout(timer),
    emit: s => emitted.push(s),
    engine,
    focused: () => env.focused,
    health,
    log: {
      line: vi.fn(async (text: string) => {
        lines.push(text)
      }),
      path: '/logs/updater.log',
    },
    notify,
    now: () => Date.now(),
    online: () => net.online,
    setInterval: (fn, ms) => setInterval(fn, ms),
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    settings: () => ({ autoUpdate: env.autoUpdate, notifications: env.notifications }),
    showWindow,
    store,
    version: options.version ?? '1.0.0',
  }
  const updater: Updater = createUpdater(deps)
  const state = () => updater.snapshot().state
  return {
    canWrite,
    emitted,
    engine,
    env,
    health,
    lines,
    net,
    notify,
    showWindow,
    state,
    store,
    updater,
  }
}

// Let the promise callbacks of the service run.
async function settle(): Promise<void> {
  for (let i = 0; i < 20; i++) await Promise.resolve()
}

// Bring the service to ready with the events of a download.
async function toReady(t: ReturnType<typeof setup>, version = '1.1.0'): Promise<void> {
  finds(t.engine, version)
  await t.updater.checkNow()
  t.engine.emit('update-downloaded', { version })
}

beforeEach(() => {
  vi.useFakeTimers({ now: NOW })
})
afterEach(() => {
  vi.useRealTimers()
})

describe('start', () => {
  test('sets autoDownload and autoInstallOnAppQuit, and emits the first snapshot', () => {
    const t = setup()
    t.updater.start()
    expect(t.engine.autoDownload).toBe(true)
    expect(t.engine.autoInstallOnAppQuit).toBe(true)
    expect(t.emitted).toEqual([
      { available: true, lastCheckAt: null, state: { kind: 'idle' }, version: '1.0.0' },
    ])
    expect(t.store.set).not.toHaveBeenCalled()
  })

  test('a record from the running version gives failed with cause install, at the next start only', () => {
    const store = memoryStore(ATTEMPT)
    const t = setup({ store })
    t.updater.start()
    expect(t.state()).toEqual(INSTALL_FAILED)
    expect(t.lines).toEqual(['error install: 1.1.0 did not install'])
    expect(t.store.set).toHaveBeenCalledWith({ attemptedFrom: null, attemptedVersion: null })
    t.updater.stop()
    const again = setup({ store })
    again.updater.start()
    expect(again.state()).toEqual({ kind: 'idle' })
    expect(again.lines).toEqual([])
  })

  test.each([
    ['N+2 installed at the quit after a failed N+1', '1.2.0'],
    ['the attempted version installed', '1.1.0'],
    ['a newer version installed from the DMG', '1.3.0'],
  ])('no failure when %s, and the record is cleared', (_, version) => {
    const t = setup({ store: memoryStore(ATTEMPT), version })
    t.updater.start()
    expect(t.state()).toEqual({ kind: 'idle' })
    expect(t.store.get()).toMatchObject({ attemptedFrom: null, attemptedVersion: null })
    expect(t.lines).toEqual([])
  })

  test('a record with no running version gives no failure, and is cleared', () => {
    const t = setup({ store: memoryStore({ attemptedVersion: '1.1.0' }) })
    t.updater.start()
    expect(t.state()).toEqual({ kind: 'idle' })
    expect(t.store.get().attemptedVersion).toBeNull()
  })

  test('with autoUpdate on, the first check runs after CHECK_DELAY_MS, then each CHECK_INTERVAL_MS', async () => {
    const t = setup()
    t.updater.start()
    await vi.advanceTimersByTimeAsync(CHECK_DELAY_MS - 1)
    expect(t.engine.checkForUpdates).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    await settle()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(CHECK_INTERVAL_MS - 1)
    await settle()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    await settle()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(CHECK_INTERVAL_MS)
    await settle()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(3)
  })

  test('with autoUpdate off, the state is off and no check runs', async () => {
    const t = setup({ autoUpdate: false })
    t.updater.start()
    expect(t.state()).toEqual({ kind: 'off' })
    await vi.advanceTimersByTimeAsync(CHECK_DELAY_MS + 3 * CHECK_INTERVAL_MS)
    expect(t.engine.checkForUpdates).not.toHaveBeenCalled()
  })
})

describe('the install failure during the first check', () => {
  test('stays through checking and no update, and the check is in the log', async () => {
    const t = setup({ store: memoryStore(ATTEMPT) })
    t.updater.start()
    await vi.advanceTimersByTimeAsync(CHECK_DELAY_MS)
    await settle()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(1)
    expect(t.state()).toEqual(INSTALL_FAILED)
    expect(t.emitted.some(s => s.state.kind === 'checking')).toBe(false)
    expect(t.updater.snapshot().lastCheckAt).toBe(NOW + CHECK_DELAY_MS)
    expect(t.lines).toEqual(['error install: 1.1.0 did not install', 'check', 'no update'])
  })

  test.each([
    ['an offline error', false, 'getaddrinfo ENOTFOUND api.github.com', 'offline'],
    ['a failed check', true, 'HttpError: 500 Internal Server Error', 'error github'],
  ])('stays after %s', async (_, online, message, prefix) => {
    const t = setup({ autoUpdate: false, store: memoryStore(ATTEMPT) })
    t.updater.start()
    t.net.online = online
    failsWith(t.engine, new Error(message))
    await t.updater.checkNow()
    expect(t.state()).toEqual(INSTALL_FAILED)
    expect(t.lines.at(-1)?.startsWith(prefix)).toBe(true)
  })

  test('goes when a download starts, and the update can get ready', async () => {
    const t = setup({ autoUpdate: false, store: memoryStore(ATTEMPT) })
    t.updater.start()
    finds(t.engine, '1.1.0')
    await t.updater.checkNow()
    expect(t.state()).toEqual({ kind: 'downloading', percent: 0, version: '1.1.0' })
    t.engine.emit('update-downloaded', { version: '1.1.0' })
    expect(t.state()).toEqual({ kind: 'ready', version: '1.1.0' })
  })

  test('a later check replaces it as usual', async () => {
    const t = setup({ autoUpdate: false, store: memoryStore(ATTEMPT) })
    t.updater.start()
    await t.updater.checkNow()
    expect(t.state()).toEqual(INSTALL_FAILED)
    await t.updater.checkNow()
    expect(t.state()).toEqual({ kind: 'idle' })
    expect(t.emitted.some(s => s.state.kind === 'checking')).toBe(true)
  })
})

describe('a check', () => {
  test('sets the public GitHub feed, with no token, then checks', async () => {
    expect(UPDATE_OWNER).toBe('Keane54')
    expect(UPDATE_REPO).toBe('bifrost')
    const t = setup()
    t.updater.start()
    await t.updater.checkNow()
    expect(t.engine.setFeedURL).toHaveBeenCalledWith({
      owner: 'Keane54',
      provider: 'github',
      repo: 'bifrost',
    })
    const feedAt = t.engine.setFeedURL.mock.invocationCallOrder[0] ?? 0
    const checkAt = t.engine.checkForUpdates.mock.invocationCallOrder[0] ?? 0
    expect(feedAt).toBeLessThan(checkAt)
    expect(t.canWrite).toHaveBeenCalledWith('/Applications')
  })

  test('is skipped while a check runs', async () => {
    let answer: (ok: boolean) => void = () => {}
    const t = setup({
      canWrite: () =>
        new Promise<boolean>(r => {
          answer = r
        }),
    })
    t.updater.start()
    // The first check waits for the location test.
    const first = t.updater.checkNow()
    expect(t.state()).toEqual({ kind: 'checking' })
    await t.updater.checkNow()
    expect(t.canWrite).toHaveBeenCalledTimes(1)
    answer(true)
    await first
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(1)
    // The next check waits for the engine.
    t.canWrite.mockResolvedValue(true)
    t.engine.checkForUpdates.mockImplementation(() => {
      t.engine.emit('checking-for-update')
      return new Promise(() => {})
    })
    void t.updater.checkNow()
    await settle()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(2)
    expect(t.state()).toEqual({ kind: 'checking' })
    await t.updater.checkNow()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(2)
  })

  test('an hourly check or a second click during a download starts no second download (focus 2)', async () => {
    const t = setup()
    finds(t.engine, '1.1.0')
    t.updater.start()
    await vi.advanceTimersByTimeAsync(CHECK_DELAY_MS)
    await settle()
    t.engine.emit('download-progress', { percent: 40 })
    expect(t.state()).toEqual({ kind: 'downloading', percent: 40, version: '1.1.0' })
    await vi.advanceTimersByTimeAsync(CHECK_INTERVAL_MS)
    await settle()
    await t.updater.checkNow()
    expect(t.engine.setFeedURL).toHaveBeenCalledTimes(1)
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(1)
    expect(t.state()).toEqual({ kind: 'downloading', percent: 40, version: '1.1.0' })
  })

  test('while an update is ready, scheduled and manual checks do nothing', async () => {
    const t = setup()
    t.updater.start()
    await toReady(t)
    const count = t.emitted.length
    await vi.advanceTimersByTimeAsync(CHECK_DELAY_MS + CHECK_INTERVAL_MS)
    await settle()
    await t.updater.checkNow()
    expect(t.engine.setFeedURL).toHaveBeenCalledTimes(1)
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(1)
    expect(t.state()).toEqual({ kind: 'ready', version: '1.1.0' })
    expect(t.emitted).toHaveLength(count)
    expect(t.lines.slice(-3)).toEqual([
      'check skipped: update ready',
      'check skipped: update ready',
      'check skipped: update ready',
    ])
  })

  test.each([
    ['the DMG', '/Volumes/Bifrost/Bifrost.app', true],
    ['a translocated path', '/private/var/folders/ab/AppTranslocation/X1/d/Bifrost.app', true],
    ['a folder that Bifrost cannot write', APP, false],
  ])(
    'from %s gives failed with cause location and no download (focus 4)',
    async (_, appPath, writable) => {
      const t = setup({ appPath, canWrite: async () => writable })
      t.updater.start()
      await t.updater.checkNow()
      expect(t.state()).toEqual({
        at: NOW,
        cause: 'location',
        kind: 'failed',
        message: 'Move Bifrost to the Applications folder to get updates.',
      })
      expect(t.engine.setFeedURL).not.toHaveBeenCalled()
      expect(t.engine.checkForUpdates).not.toHaveBeenCalled()
      expect(t.health.poll).toHaveBeenCalledWith('updates', 'no-data')
    },
  )

  test('a canWrite that rejects counts as a folder that Bifrost cannot write', async () => {
    const t = setup({ canWrite: () => Promise.reject(new Error('EACCES')) })
    t.updater.start()
    await t.updater.checkNow()
    expect(t.state()).toMatchObject({ cause: 'location', kind: 'failed' })
  })
})

describe('events', () => {
  test('checking-for-update gives checking', () => {
    const t = setup()
    t.updater.start()
    t.engine.emit('checking-for-update')
    expect(t.state()).toEqual({ kind: 'checking' })
    expect(t.lines).toEqual(['check'])
  })

  test('update-not-available gives idle, the last check time and health ok', () => {
    const t = setup({ autoUpdate: false })
    t.updater.start()
    t.engine.emit('checking-for-update')
    vi.setSystemTime(NOW + 5_000)
    t.engine.emit('update-not-available', { version: '1.0.0' })
    expect(t.state()).toEqual({ kind: 'idle' })
    expect(t.updater.snapshot().lastCheckAt).toBe(NOW + 5_000)
    expect(t.health.poll).toHaveBeenCalledWith('updates', 'ok')
  })

  test('update-available and download-progress give downloading, with the percent rounded down', () => {
    const t = setup()
    t.updater.start()
    t.engine.emit('update-available', { version: '1.1.0' })
    expect(t.state()).toEqual({ kind: 'downloading', percent: 0, version: '1.1.0' })
    t.engine.emit('download-progress', { percent: 42.9 })
    expect(t.state()).toEqual({ kind: 'downloading', percent: 42, version: '1.1.0' })
    t.engine.emit('download-progress', { percent: 99.99 })
    expect(t.state()).toEqual({ kind: 'downloading', percent: 99, version: '1.1.0' })
  })

  test('update-downloaded gives ready, the last check time and health ok', () => {
    const t = setup()
    t.updater.start()
    t.engine.emit('update-available', { version: '1.1.0' })
    vi.setSystemTime(NOW + 60_000)
    t.engine.emit('update-downloaded', { version: '1.1.0' })
    expect(t.state()).toEqual({ kind: 'ready', version: '1.1.0' })
    expect(t.updater.snapshot().lastCheckAt).toBe(NOW + 60_000)
    expect(t.health.poll).toHaveBeenCalledWith('updates', 'ok')
  })

  test('engine events for the same version keep the ready state', async () => {
    const t = setup()
    t.updater.start()
    await toReady(t)
    const count = t.emitted.length
    t.engine.emit('checking-for-update')
    t.engine.emit('update-available', { version: '1.1.0' })
    t.engine.emit('download-progress', { percent: 50 })
    t.engine.emit('update-downloaded', { version: '1.1.0' })
    const later = t.emitted.slice(count).map(s => s.state)
    expect(later).toEqual([{ kind: 'ready', version: '1.1.0' }])
  })
})

describe('the notification', () => {
  test('shows one time for each version when notifications are on and the window has no focus', async () => {
    const t = setup()
    t.updater.start()
    await toReady(t)
    expect(t.notify).toHaveBeenCalledTimes(1)
    expect(t.notify).toHaveBeenCalledWith(
      'Bifrost update ready',
      'Bifrost 1.1.0 is available, click to update.',
      expect.any(Function),
    )
    expect(UPDATE_TEXTS.notifyTitle).toBe('Bifrost update ready')
    expect(t.store.get().notifiedVersion).toBe('1.1.0')
    // The engine sends the same version again.
    t.engine.emit('update-downloaded', { version: '1.1.0' })
    expect(t.notify).toHaveBeenCalledTimes(1)
    // A new version gets its own notification.
    t.engine.emit('update-available', { version: '1.2.0' })
    t.engine.emit('update-downloaded', { version: '1.2.0' })
    expect(t.notify).toHaveBeenCalledTimes(2)
    expect(t.store.get().notifiedVersion).toBe('1.2.0')
  })

  test('held back while notifications are off, and not sent later', async () => {
    const t = setup()
    t.env.notifications = false
    t.updater.start()
    await toReady(t)
    expect(t.notify).not.toHaveBeenCalled()
    expect(t.store.get().notifiedVersion).toBe('1.1.0')
    t.env.notifications = true
    t.engine.emit('update-downloaded', { version: '1.1.0' })
    expect(t.notify).not.toHaveBeenCalled()
  })

  test('held back while the window has the focus, and not sent later', async () => {
    const t = setup()
    t.env.focused = true
    t.updater.start()
    await toReady(t)
    expect(t.notify).not.toHaveBeenCalled()
    t.env.focused = false
    t.engine.emit('update-downloaded', { version: '1.1.0' })
    expect(t.notify).not.toHaveBeenCalled()
  })

  test('shows at most one time for a version across restarts (focus 5)', async () => {
    const store = memoryStore()
    const first = setup({ store })
    first.updater.start()
    await toReady(first)
    expect(first.notify).toHaveBeenCalledTimes(1)
    first.updater.stop()
    const second = setup({ store })
    second.updater.start()
    await toReady(second)
    expect(second.notify).not.toHaveBeenCalled()
  })

  test('a click while the window is closed shows the window, then installs (focus 5)', async () => {
    const t = setup()
    t.updater.start()
    await toReady(t)
    const onClick = t.notify.mock.calls[0]?.[2] as () => void
    onClick()
    await settle()
    expect(t.showWindow).toHaveBeenCalledTimes(1)
    expect(t.engine.quitAndInstall).toHaveBeenCalledTimes(1)
    const shownAt = t.showWindow.mock.invocationCallOrder[0] ?? 0
    const installAt = t.engine.quitAndInstall.mock.invocationCallOrder[0] ?? 0
    expect(shownAt).toBeLessThan(installAt)
    expect(t.store.get()).toMatchObject(ATTEMPT)
  })
})

describe('errors', () => {
  test('offline keeps the last state, with health no-data and no triangle', async () => {
    const t = setup()
    t.updater.start()
    t.net.online = false
    failsWith(t.engine, new Error('anything'))
    await t.updater.checkNow()
    expect(t.state()).toEqual({ kind: 'idle' })
    expect(t.health.poll.mock.calls).toEqual([['updates', 'no-data']])
    expect(t.updater.snapshot().lastCheckAt).toBeNull()
    expect(t.emitted.some(s => s.state.kind === 'failed')).toBe(false)
    expect(t.lines).toEqual(['check', 'offline: anything'])
  })

  test('a network error while online also counts as offline', async () => {
    const t = setup({ autoUpdate: false })
    t.updater.start()
    failsWith(t.engine, new Error('net::ERR_INTERNET_DISCONNECTED'))
    await t.updater.checkNow()
    expect(t.state()).toEqual({ kind: 'off' })
    expect(t.health.poll).toHaveBeenCalledWith('updates', 'no-data')
  })

  test('offline keeps an earlier failure as it is', async () => {
    const t = setup()
    t.updater.start()
    failsWith(t.engine, new Error('HttpError: 500 Internal Server Error'))
    await t.updater.checkNow()
    const failed = t.state()
    expect(failed.kind).toBe('failed')
    failsWith(t.engine, new Error('getaddrinfo ENOTFOUND api.github.com'))
    await t.updater.checkNow()
    expect(t.state()).toEqual(failed)
  })

  test('offline during a download goes back to the state before the check', async () => {
    const t = setup()
    t.updater.start()
    finds(t.engine, '1.1.0')
    await t.updater.checkNow()
    t.engine.emit('download-progress', { percent: 30 })
    t.engine.emit('error', new Error('read ECONNRESET'))
    expect(t.state()).toEqual({ kind: 'idle' })
    // The next check can start a new download.
    await t.updater.checkNow()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(2)
  })

  test('a GitHub error gives failed with the cause text, and health failed', async () => {
    const t = setup()
    t.updater.start()
    failsWith(t.engine, new Error('HttpError: 500 Internal Server Error\n  at stack line'))
    await t.updater.checkNow()
    expect(t.state()).toEqual({
      at: NOW,
      cause: 'github',
      kind: 'failed',
      message: causeText('github', 'HttpError: 500 Internal Server Error'),
    })
    expect(t.health.poll.mock.calls).toEqual([['updates', 'failed']])
    expect(t.lines).toEqual(['check', 'error github: HttpError: 500 Internal Server Error'])
  })

  test.each([401, 403, 404])(
    'a %i from GitHub gives cause github and health failed',
    async code => {
      const t = setup()
      t.updater.start()
      failsWith(t.engine, new Error(`HttpError: ${code} Not Found`))
      await t.updater.checkNow()
      expect(t.state()).toMatchObject({ cause: 'github', kind: 'failed' })
      expect(t.health.poll.mock.calls).toEqual([['updates', 'failed']])
    },
  )

  test('a download error gives failed with cause download', async () => {
    const t = setup()
    t.updater.start()
    finds(t.engine, '1.1.0')
    await t.updater.checkNow()
    t.engine.emit('error', new Error('sha512 checksum mismatch'))
    expect(t.state()).toEqual({
      at: NOW,
      cause: 'download',
      kind: 'failed',
      message: causeText('download', 'sha512 checksum mismatch'),
    })
    expect(t.health.poll).toHaveBeenLastCalledWith('updates', 'failed')
  })

  test('a failed engine check while ready keeps ready, logs, and counts as failed in health', async () => {
    const t = setup()
    t.updater.start()
    await toReady(t)
    const count = t.emitted.length
    t.health.poll.mockClear()
    t.engine.emit('checking-for-update')
    t.engine.emit('error', new Error('HttpError: 500 Internal Server Error'))
    expect(t.state()).toEqual({ kind: 'ready', version: '1.1.0' })
    expect(t.emitted).toHaveLength(count)
    expect(t.health.poll.mock.calls).toEqual([['updates', 'failed']])
    expect(t.lines.at(-1)).toBe('error github: HttpError: 500 Internal Server Error')
  })

  test('while ready, an error of the macOS install engine after the download gives failed', async () => {
    const t = setup()
    t.updater.start()
    // The last check found no update, so the step is check. The ready event changes it.
    await t.updater.checkNow()
    t.engine.emit('update-downloaded', { version: '1.1.0' })
    t.engine.emit('error', new Error('Code signature at URL did not pass validation'))
    expect(t.state()).toMatchObject({ cause: 'download', kind: 'failed' })
  })

  test('the same error object two times gives one result', async () => {
    const t = setup()
    t.updater.start()
    await toReady(t)
    const count = t.emitted.length
    t.health.poll.mockClear()
    // Squirrel.Mac sends its error, and the rejected download sends the same object again.
    const error = new Error('Code signature at URL did not pass validation')
    t.engine.emit('error', error)
    t.engine.emit('error', error)
    expect(t.health.poll).toHaveBeenCalledTimes(1)
    expect(t.emitted).toHaveLength(count + 1)
    expect(t.lines.filter(l => l.startsWith('error'))).toHaveLength(1)
    // A new error object is a new result.
    t.engine.emit('error', new Error('Code signature at URL did not pass validation'))
    expect(t.health.poll).toHaveBeenCalledTimes(2)
  })

  test('the error event and the rejected check give one result, not two', async () => {
    const t = setup()
    t.updater.start()
    failsWith(t.engine, new Error('HttpError: 500 Internal Server Error'))
    await t.updater.checkNow()
    expect(t.health.poll).toHaveBeenCalledTimes(1)
    expect(t.lines.filter(l => l.startsWith('error'))).toHaveLength(1)
  })

  test('a check that rejects with no error event still fails', async () => {
    const t = setup()
    t.updater.start()
    t.engine.checkForUpdates.mockRejectedValue(new Error('HttpError: 502 Bad Gateway'))
    await t.updater.checkNow()
    expect(t.state()).toMatchObject({ cause: 'github', kind: 'failed' })
  })

  test('a check that ends with no event goes back to the state before the check', async () => {
    const t = setup()
    t.updater.start()
    t.engine.checkForUpdates.mockResolvedValue(null)
    await t.updater.checkNow()
    expect(t.state()).toEqual({ kind: 'idle' })
    await t.updater.checkNow()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(2)
  })

  test('a failed download does not give an unhandled rejection', async () => {
    const t = setup()
    t.updater.start()
    const error = new Error('sha512 checksum mismatch')
    t.engine.checkForUpdates.mockImplementation(async () => {
      t.engine.emit('checking-for-update')
      t.engine.emit('update-available', { version: '1.1.0' })
      const downloadPromise = new Promise((_, reject) =>
        setTimeout(() => {
          t.engine.emit('error', error)
          reject(error)
        }, 1_000),
      )
      return { downloadPromise, isUpdateAvailable: true }
    })
    await t.updater.checkNow()
    await vi.advanceTimersByTimeAsync(1_000)
    await settle()
    expect(t.state()).toMatchObject({ cause: 'download', kind: 'failed' })
  })
})

describe('restart', () => {
  test('does nothing when no update is ready', async () => {
    const t = setup()
    t.updater.start()
    t.updater.restart()
    await settle()
    expect(t.store.set).not.toHaveBeenCalled()
    expect(t.engine.quitAndInstall).not.toHaveBeenCalled()
  })

  test('stores the running and the attempted version, logs install, then quits and installs', async () => {
    const t = setup()
    t.updater.start()
    await toReady(t)
    t.updater.restart()
    t.updater.restart()
    await settle()
    expect(t.store.set).toHaveBeenCalledWith(ATTEMPT)
    expect(t.lines.at(-1)).toBe('install 1.1.0')
    expect(t.engine.quitAndInstall).toHaveBeenCalledTimes(1)
    const storedAt = t.store.set.mock.invocationCallOrder.at(-1) ?? 0
    const installAt = t.engine.quitAndInstall.mock.invocationCallOrder[0] ?? 0
    expect(storedAt).toBeLessThan(installAt)
  })

  test('an install error gives failed with cause install, and the user can try again', async () => {
    const t = setup()
    t.updater.start()
    await toReady(t)
    t.updater.restart()
    await settle()
    t.engine.emit('error', new Error('Could not install the update'))
    expect(t.state()).toMatchObject({ cause: 'install', kind: 'failed' })
    await t.updater.checkNow()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(2)
  })

  test('with no quit after 60 s, the guard clears, the log says so, and the state is failed', async () => {
    // With the switch off, no timer check runs in the 60 s.
    const t = setup({ autoUpdate: false })
    t.updater.start()
    await toReady(t)
    t.updater.restart()
    await settle()
    expect(RESTART_LIMIT_MS).toBe(60_000)
    await vi.advanceTimersByTimeAsync(RESTART_LIMIT_MS - 1)
    expect(t.state()).toEqual({ kind: 'ready', version: '1.1.0' })
    await vi.advanceTimersByTimeAsync(1)
    expect(t.state()).toEqual({ ...INSTALL_FAILED, at: NOW + RESTART_LIMIT_MS })
    expect(t.lines.at(-1)).toBe('install 1.1.0: no quit after 60 s')
    // The guard is clear, so a check can run.
    finds(t.engine, '1.1.0')
    await t.updater.checkNow()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(2)
  })

  test('an install error or stop ends the 60 s limit', async () => {
    // With the switch off, no timer check runs in the 60 s.
    const t = setup({ autoUpdate: false })
    t.updater.start()
    await toReady(t)
    t.updater.restart()
    await settle()
    t.engine.emit('error', new Error('Could not install the update'))
    const count = t.emitted.length
    await vi.advanceTimersByTimeAsync(RESTART_LIMIT_MS)
    expect(t.emitted).toHaveLength(count)
    expect(t.lines.some(l => l.includes('no quit'))).toBe(false)
    const other = setup({ autoUpdate: false })
    other.updater.start()
    await toReady(other)
    other.updater.restart()
    await settle()
    other.updater.stop()
    await vi.advanceTimersByTimeAsync(RESTART_LIMIT_MS)
    expect(other.lines.some(l => l.includes('no quit'))).toBe(false)
  })
})

describe('setAuto', () => {
  test('false stops the timers, clears a failed state to off, and reports the stop', async () => {
    const t = setup()
    failsWith(t.engine, new Error('HttpError: 500 Internal Server Error'))
    t.updater.start()
    await vi.advanceTimersByTimeAsync(CHECK_DELAY_MS)
    await settle()
    expect(t.state().kind).toBe('failed')
    t.updater.setAuto(false)
    expect(t.state()).toEqual({ kind: 'off' })
    expect(t.health.stopped).toHaveBeenCalledWith('updates')
    await vi.advanceTimersByTimeAsync(3 * CHECK_INTERVAL_MS)
    await settle()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(1)
  })

  test('false while an update is ready keeps it ready, stops checks and still installs at quit (focus 3)', async () => {
    const t = setup()
    finds(t.engine, '1.1.0')
    t.updater.start()
    await vi.advanceTimersByTimeAsync(CHECK_DELAY_MS)
    await settle()
    t.engine.emit('update-downloaded', { version: '1.1.0' })
    t.updater.setAuto(false)
    expect(t.state()).toEqual({ kind: 'ready', version: '1.1.0' })
    expect(t.engine.autoInstallOnAppQuit).toBe(true)
    await vi.advanceTimersByTimeAsync(3 * CHECK_INTERVAL_MS)
    await settle()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(1)
  })

  test('false during a download cancels it, with no failure, and the state is off', async () => {
    const t = setup()
    t.updater.start()
    const token = finds(t.engine, '1.1.0')
    await t.updater.checkNow()
    t.engine.emit('download-progress', { percent: 30 })
    t.health.poll.mockClear()
    t.updater.setAuto(false)
    expect(token.cancel).toHaveBeenCalledTimes(1)
    expect(t.state()).toEqual({ kind: 'off' })
    // Late events of the stopped download change nothing.
    const count = t.emitted.length
    t.engine.emit('download-progress', { percent: 40 })
    t.engine.emit('error', new Error('sha512 checksum mismatch'))
    expect(t.state()).toEqual({ kind: 'off' })
    expect(t.emitted).toHaveLength(count)
    expect(t.health.poll).not.toHaveBeenCalled()
    // A manual check after that runs as usual.
    await t.updater.checkNow()
    expect(t.state()).toEqual({ kind: 'downloading', percent: 0, version: '1.1.0' })
  })

  test('false during the engine check cancels the download that the check starts', async () => {
    const t = setup()
    t.updater.start()
    const token = { cancel: vi.fn() }
    let finish: (result: unknown) => void = () => {}
    t.engine.checkForUpdates.mockImplementation(() => {
      t.engine.emit('checking-for-update')
      return new Promise(r => {
        finish = r
      })
    })
    const running = t.updater.checkNow()
    await settle()
    t.updater.setAuto(false)
    expect(t.state()).toEqual({ kind: 'off' })
    t.engine.emit('update-available', { version: '1.1.0' })
    finish({ cancellationToken: token, downloadPromise: new Promise(() => {}) })
    await running
    expect(token.cancel).toHaveBeenCalledTimes(1)
    expect(t.state()).toEqual({ kind: 'off' })
  })

  test('false during the location test starts no engine check', async () => {
    let answer: (ok: boolean) => void = () => {}
    const t = setup({
      canWrite: () =>
        new Promise<boolean>(r => {
          answer = r
        }),
    })
    t.updater.start()
    const running = t.updater.checkNow()
    t.updater.setAuto(false)
    answer(true)
    await running
    expect(t.engine.setFeedURL).not.toHaveBeenCalled()
    expect(t.engine.checkForUpdates).not.toHaveBeenCalled()
    expect(t.state()).toEqual({ kind: 'off' })
  })

  test('true starts the timers and checks after CHECK_DELAY_MS', async () => {
    const t = setup({ autoUpdate: false })
    t.updater.start()
    t.updater.setAuto(true)
    expect(t.state()).toEqual({ kind: 'idle' })
    await vi.advanceTimersByTimeAsync(CHECK_DELAY_MS - 1)
    expect(t.engine.checkForUpdates).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    await settle()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(CHECK_INTERVAL_MS)
    await settle()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(2)
  })
})

describe('checkNow', () => {
  test('runs one check while autoUpdate is off, and its result replaces off', async () => {
    const t = setup({ autoUpdate: false })
    t.updater.start()
    await t.updater.checkNow()
    expect(t.engine.checkForUpdates).toHaveBeenCalledTimes(1)
    expect(t.state()).toEqual({ kind: 'idle' })
  })
})

describe('stop', () => {
  test('stops the timers and ignores later events', async () => {
    const t = setup()
    t.updater.start()
    t.updater.stop()
    await vi.advanceTimersByTimeAsync(CHECK_DELAY_MS + CHECK_INTERVAL_MS)
    expect(t.engine.checkForUpdates).not.toHaveBeenCalled()
    const count = t.emitted.length
    t.engine.emit('update-available', { version: '1.1.0' })
    expect(t.emitted).toHaveLength(count)
  })
})

describe('the log and the snapshots', () => {
  test('each state change emits a snapshot and writes one log line', async () => {
    const t = setup()
    t.updater.start()
    finds(t.engine, '1.1.0')
    await t.updater.checkNow()
    for (const percent of [10, 30, 55, 80, 100]) t.engine.emit('download-progress', { percent })
    t.engine.emit('update-downloaded', { version: '1.1.0' })
    t.updater.restart()
    await settle()
    expect(t.lines).toEqual([
      'check',
      'found 1.1.0',
      'download 25%',
      'download 50%',
      'download 75%',
      'ready 1.1.0',
      'install 1.1.0',
    ])
    expect(t.emitted.map(s => s.state)).toEqual([
      { kind: 'idle' },
      { kind: 'checking' },
      { kind: 'downloading', percent: 0, version: '1.1.0' },
      { kind: 'downloading', percent: 10, version: '1.1.0' },
      { kind: 'downloading', percent: 30, version: '1.1.0' },
      { kind: 'downloading', percent: 55, version: '1.1.0' },
      { kind: 'downloading', percent: 80, version: '1.1.0' },
      { kind: 'downloading', percent: 100, version: '1.1.0' },
      { kind: 'ready', version: '1.1.0' },
    ])
    for (const s of t.emitted) {
      expect(s.available).toBe(true)
      expect(s.version).toBe('1.0.0')
    }
  })

  test('a no-update check, setAuto(false) and setAuto(true) each write one line', async () => {
    const t = setup()
    t.updater.start()
    await t.updater.checkNow()
    t.updater.setAuto(false)
    t.updater.setAuto(true)
    expect(t.lines).toEqual(['check', 'no update', 'auto off', 'auto on'])
  })
})

describe('token masking (focus 1)', () => {
  const leaks = (text: string) =>
    [TOKEN, PAT, TOKEN.slice(0, 8), PAT.slice(0, 8)].some(part => text.includes(part))

  test('a token in a check error is never in the state, a snapshot or a log line', async () => {
    const t = setup()
    t.updater.start()
    failsWith(t.engine, new Error(`HttpError: 500 for ${TOKEN} and ${PAT}`))
    await t.updater.checkNow()
    const state = t.state()
    expect(state.kind).toBe('failed')
    expect(state.kind === 'failed' && state.message.includes('***')).toBe(true)
    expect(t.emitted.some(s => leaks(JSON.stringify(s)))).toBe(false)
    expect(t.lines.some(leaks)).toBe(false)
  })

  test('a token at the 200 character limit of the detail is masked in full', async () => {
    const t = setup()
    t.updater.start()
    // The first 200 characters end 10 characters into the token.
    failsWith(t.engine, new Error(`HttpError: 500 ${'x'.repeat(174)} ${TOKEN}`))
    await t.updater.checkNow()
    expect(leaks(JSON.stringify(t.updater.snapshot()))).toBe(false)
    expect(t.lines.some(leaks)).toBe(false)
  })

  test('a token in a download error, an offline error or a 404 error is masked', async () => {
    const t = setup()
    t.updater.start()
    finds(t.engine, '1.1.0')
    await t.updater.checkNow()
    t.engine.emit('error', new Error(`sha512 checksum mismatch ${TOKEN}`))
    t.net.online = false
    failsWith(t.engine, new Error(`offline ${PAT}`))
    await t.updater.checkNow()
    t.net.online = true
    failsWith(t.engine, new Error(`HttpError: 404 ${TOKEN}`))
    await t.updater.checkNow()
    expect(t.lines.filter(l => l.startsWith('error') || l.startsWith('offline'))).toHaveLength(3)
    expect(t.emitted.some(s => leaks(JSON.stringify(s)))).toBe(false)
    expect(t.lines.some(leaks)).toBe(false)
  })
})
