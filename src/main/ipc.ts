import { randomUUID } from 'node:crypto'
import { constants, existsSync } from 'node:fs'
import {
  access,
  appendFile,
  mkdir,
  readFile,
  rename,
  rm,
  stat,
  statfs,
  writeFile,
} from 'node:fs/promises'
import { cpus, homedir, hostname } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { monitorEventLoopDelay } from 'node:perf_hooks'
import {
  app,
  type BrowserWindow,
  clipboard,
  dialog,
  type IpcMainInvokeEvent,
  ipcMain,
  nativeImage,
  autoUpdater as nativeUpdater,
  net,
  type OpenDialogOptions,
  powerMonitor,
  shell,
  type WebContents,
} from 'electron'
import electronUpdater from 'electron-updater'
import { checkAliasRequest } from '../shared/alias'
import { LIVE_MIN_CLAUDE_VERSION } from '../shared/live'
import { isPriority } from '../shared/priority'
import { REPO_KEY } from '../shared/reviews'
import { DEFAULT_SETTINGS, type Settings, type SettingsPatch } from '../shared/settings'
import { SKILLS_MARKETPLACE, SKILLS_PLUGIN_ID, type SkillsStatus } from '../shared/skills'
import type { ClaudeVersion, DisplayMode, LiveStatus, WatchColour } from '../shared/types'
import { EMPTY_UPDATES, type UpdatesSnapshot } from '../shared/updates'
import { CHAT_VIEW } from '../shared/view-id'
import { isWatchColour } from '../shared/watch'
import { type AccountUsagePoller, createAccountUsagePoller } from './account-usage/poller'
import { readAccessToken } from './account-usage/token'
import { createActions } from './actions/actions'
import { appIcon } from './actions/app-icon'
import { dirInfo, isAlive, processName, sendSignal } from './actions/process-info'
import { findProjectApps, findTerminalApps } from './actions/project-apps'
import { createSessionActions } from './actions/session-actions'
import { hasLeftKey, SessionInput } from './actions/session-input'
import { createTerminalLauncher } from './actions/terminal-launch'
import { findTranscript, hasMessages, readTail, TRANSCRIPT_TAIL_MAX } from './actions/transcript'
import { checkWorktreeHead, createWorktreeActions, trackedChanges } from './actions/worktree-check'
import { AFPLAY, createAlertMonitor, SOUND_FILE } from './alerts/alert-monitor'
import { showNotification } from './alerts/notifier'
import { PendingOpen } from './alerts/pending-open'
import { childEnv } from './child-env'
import { type AgentList, listAgents } from './claude/agents'
import {
  createRunClaude,
  defaultIsExecutable,
  execFile,
  type RunClaude,
  resolveClaudePath,
} from './claude/cli'
import { checkClaudeVersion, MIN_CLAUDE_VERSION } from './claude/version'
import { loadLoginEnv, stringValues } from './env/login-env'
import { createBatcher, EventLog, NOTIFICATION_REFUSED } from './events/event-log'
import { createHandOver } from './handover/hand-over'
import { noteFileName } from './handover/naming'
import { writeNoteFile } from './handover/note-file'
import { handOverRulesPath } from './handover/prompt'
import { createPrLookup, prUrlToOpen } from './info/pr-info'
import {
  defaultPaths,
  keepOldScripts,
  oldInstallStatus,
  removeOldHookData,
  uninstall,
} from './integration/integration'
import { createSerialRunner } from './integration/serial'
import { createLiveControl, type LiveControl } from './live/live-control'
import { createLiveServer } from './live/live-server'
import { modSourceDir } from './live/mod-folder'
import { createPluginCli } from './live/plugin-cli'
import { createRotatingLog } from './log/rotating-log'
import {
  checkFps,
  checkView,
  createLoopDelay,
  type LoopDelay,
  probeUrl,
  readGhRateLimit,
} from './performance/bindings'
import { createHealthLog, type HealthLog } from './performance/health-log'
import { createPerformanceMonitor, type PerformanceMonitor } from './performance/monitor'
import { checkChatOpen, REFUSED_NOT_CHAT } from './pty/can-attach'
import { nodePtySpawn } from './pty/node-pty-spawn'
import { openLink } from './pty/open-link'
import { PageScope } from './pty/page-scope'
import { PtyManager } from './pty/pty-manager'
import { chatSessionOf, readSessionSize, SessionSizeWatcher } from './pty/session-size'
import { readBranch } from './registry/git-branch'
import { SessionRegistry } from './registry/registry'
import { RegistryService, SERVICE_TIMING, type ServiceDeps } from './registry/service'
import { openStore } from './registry/store-file'
import { readProcessTable } from './registry/terminal-app'
import { createReleaseNotesSource, fileFetch } from './release-notes/source'
import { openReleaseNotesStore, releaseNotesFile } from './release-notes/state-store'
import { createWhatsNew } from './release-notes/whats-new'
import { friendlyFailure } from './reviews/friendly-failure'
import { createGh, type Gh } from './reviews/gh'
import { createRepoGit } from './reviews/repo-git'
import { createRepoStore, remoteBase } from './reviews/repo-store'
import { createReviewSessions } from './reviews/review-session'
import { createReviewRunner, REFUSED_UNKNOWN_REPO, type ReviewRunner } from './reviews/rounds'
import { openReviewsStateStore, reviewsStateFile } from './reviews/state-store'
import { createTrustWindow, TRUST_VIEW, type TrustWindow, trustedDirs } from './reviews/trust'
import {
  checkPrKey,
  createReviewsWatcher,
  type RequestNotice,
  type ReviewsWatcher,
  toReviewKey,
  urlToOpen,
  whileOn,
} from './reviews/watcher'
import { createServiceMonitor, type ServiceMonitor, serviceList } from './service-status/monitor'
import { checkService, createFetchJson, SERVICES } from './service-status/statuspage'
import { loginItemPatch, type SettingsEffect, settingsEffects } from './settings/effects'
import { createKeyRecording, resetOnPageEnd } from './settings/key-recording'
import { createSkillsControl } from './skills/skills-control'
import { skillsSourceDir } from './skills/skills-folder'
import { openSettingsStore, type SettingsStore } from './store/settings-store'
import { openUiStore } from './store/ui-store'
import { findOnPath, pluginEnv, type TestHome } from './test-home'
import { appBundlePath } from './updates/rules'
import { openUpdateStateStore } from './updates/state-store'
import { createUpdateLog, type UpdateLog } from './updates/update-log'
import { createUpdater, type Updater } from './updates/updater'
import { claudeJsonFile, readExtraUsageFlag } from './usage-alerts/claude-json'
import { createUsageAlertMonitor, type UsageAlertMonitor } from './usage-alerts/monitor'
import { openUsageAlertStore, usageAlertsFile } from './usage-alerts/state-store'
import type { ModeController } from './window/display-mode'
import { isDisplayMode } from './window/window-state'

// The terminal sends this after a resize: clear the screen, then draw it again.
const FULL_REDRAW = '\x1b[2J'

let registered = false
let currentWindow: BrowserWindow | null = null
let managerPromise: Promise<PtyManager | null> | null = null
// The main process sets liveManager when managerPromise resolves.
// A PTY cannot exist before this time.
let liveManager: PtyManager | null = null
// All PTYs belong to the page that the current window shows.
// The end of a page closes the trust terminal first. closeAll runs no exit callback.
const page = new PageScope(() => {
  trustWindow?.close()
  liveManager?.closeAll()
})

// The PID of the owned row that a chat view shows, or undefined.
function pidOfView(viewId: string): number | undefined {
  const sessionId = chatSessionOf(viewId)
  if (sessionId === null) return undefined
  return pidOfSession(sessionId)
}

function pidOfSession(sessionId: string): number | undefined {
  const row = liveService?.rows().find(r => r.sessionId === sessionId)
  return row && row.kind === 'owned' && row.state !== 'parked' ? row.pid : undefined
}

// Reads the session size after a redraw. It sends the size to the page when it changes.
const sizeWatcher = new SessionSizeWatcher({
  emit: (viewId, size) => send('pty:size', viewId, size),
  pidOf: pidOfView,
  read: pid => readSessionSize(execFile, pid),
})
// The main process sets liveService and liveRegistry when the store loads.
let liveService: RegistryService | null = null
let liveRegistry: SessionRegistry | null = null
// registerIpc opens the settings store one time. It is null until the store opens.
let settingsStore: SettingsStore | null = null
// index.ts gives the function that builds the app menu again.
let menuRebuild: (() => void) | null = null
let showWindowFn: (() => void) | null = null
let serviceStopped = false
// Live details. registerIpc sets it. stopRegistry stops its server.
let liveControl: LiveControl | null = null
// The test home of BIFROST_TEST_HOME (D12). registerIpc sets it. It is null for the real home.
let testHome: TestHome | null = null
// A click on a notification while no page is loaded waits for the next page (D13).
const pendingOpen = new PendingOpen()
// The Event log (spec 8.7). It lives as long as the main process, so a reload of the page keeps
// the entries. The batcher sends new entries to the page at most 4 times each second.
const eventLog = new EventLog()
const eventBatcher = createBatcher(entries => send('events:append', entries))

// The service status monitor (spec 8.11). It starts with the IPC handlers. A test home starts none.
let serviceMonitor: ServiceMonitor | null = null

// The health log of the Performance panel (P5). registerIpc makes it before it starts a module.
// Each module gives its poll results, save results and start errors to it.
let healthLog: HealthLog | null = null

// The health log, or null before registerIpc. index.ts and the Performance monitor read it.
export function getHealthLog(): HealthLog | null {
  return healthLog
}

// The account usage poller (spec 8.8). It runs only while the setting accountUsage is on. A test
// home creates none, so a test never reads the Keychain.
let accountUsage: AccountUsagePoller | null = null

// The Reviews watcher (Reviews design). registerIpc makes it after the Reviews state opens. It also
// runs in a test home (R1-4). It polls only while Watch GitHub is on.
let reviewsWatcher: ReviewsWatcher | null = null
// The review runner and the trust terminal. startReviews makes them. They start and stop with the
// watcher. stopRegistry stops them.
let reviewRunner: ReviewRunner | null = null
let trustWindow: TrustWindow | null = null
// The most bytes of text that the page may write to the trust terminal in one call.
const MAX_TRUST_WRITE = 64 * 1024
const REFUSED_BAD_TERMINAL = 'refused: bad terminal value'
const REVIEW_FAILED = "Bifrost couldn't do that. Please try again."
const REMOVE_CLONES_FAILED = "Bifrost couldn't delete the clones. Please try again."
const NO_RUNNER = "Bifrost couldn't start the review rounds. Please restart Bifrost."
const TRUST_OPEN_FAILED = 'Bifrost could not open the terminal. Please try again.'
// The Performance monitor (Performance design). registerIpc starts it. It samples on a timer, also
// in a test home, and sends a snapshot after each tick. stopRegistry stops it.
let perfMonitor: PerformanceMonitor | null = null
// The main process delay. registerIpc enables its histogram. stopRegistry clears its timer and
// disables it.
let loopDelay: LoopDelay | null = null
// The updater and its log (updater design). registerIpc makes them only in a release build, after
// the settings store opens. stopRegistry stops the updater.
let updater: Updater | null = null
let updateLog: UpdateLog | null = null

// A click on a review request notification while no page is loaded waits for the next page, as
// pendingOpen does for a session. PendingOpen keeps one ID. The Reviews open needs no ID, so it
// keeps this fixed one.
const pendingReviewsOpen = new PendingOpen()
const REVIEWS_OPEN = 'reviews'

// The usage notification (spec 8.8). registerIpc makes it. It gets each new account value and
// each new session value. A click that comes while no page is loaded waits for the next page, as
// for the Reviews open.
let usageAlerts: UsageAlertMonitor | null = null
const pendingUsageOpen = new PendingOpen()
const USAGE_OPEN = 'usage'

const fetchJson = createFetchJson((url, init) => net.fetch(url, init))

// Bifrost sets the login item only in the packaged app, and never in a test home (D2, D12).
// A dev Electron binary must not become a login item.
function canSetLoginItem(): boolean {
  return app.isPackaged && testHome === null
}

// Return true if the sender is the page of the current window and that page did not end.
// The check compares the webContents IDs, not the objects.
function isLivePage(sender: WebContents, token: number): boolean {
  if (!page.isCurrent(token) || sender.isDestroyed()) return false
  if (currentWindow === null || currentWindow.isDestroyed()) return false
  return sender.id === currentWindow.webContents.id
}

// Run a call only when the sender is the page that the current window shows now.
// Another webContents must not read or change the integration of the user.
function fromPage<T>(e: IpcMainInvokeEvent, fn: () => Promise<T>): Promise<T> {
  if (!isLivePage(e.sender, page.token())) {
    return Promise.reject(new Error('refused: not the Bifrost page'))
  }
  return fn()
}

const reviewLog = (m: string): void => console.error(m)

// True for an integer column or row count that the trust terminal accepts.
function isTerminalSize(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 2 && value <= 500
}

// The mode controller of the current window. index.ts sets it.
let modeController: ModeController | null = null

export function setModeController(controller: ModeController | null): void {
  modeController = controller
}

// Send an event to the current window. Do nothing if no window is open.
export function send(channel: string, ...args: unknown[]): void {
  if (currentWindow && !currentWindow.isDestroyed())
    currentWindow.webContents.send(channel, ...args)
}

// Set the function that shows and focuses the window. A click on a notification calls it.
export function setWindowShower(fn: (() => void) | null): void {
  showWindowFn = fn
}

// Set the function that builds the app menu again. A change of a menu key calls it.
export function setMenuRebuild(fn: (() => void) | null): void {
  menuRebuild = fn
}

// The key recorder of Settings > Keys. While it records, the menu gives its keys to the page.
// A change of the state builds the menu again.
const keyRecording = createKeyRecording(() => menuRebuild?.())

// True while the key recorder records. The menu builder reads it.
export function isKeyRecording(): boolean {
  return keyRecording.get()
}

// The current settings. Before the store opens, this gives the defaults.
export function getSettings(): Settings {
  return settingsStore?.get() ?? DEFAULT_SETTINGS
}

// Apply a change from the main process, for example a Zoom item of the View menu. fn gets the
// newest settings in the update queue, so two quick changes do not use the same old value.
// Do nothing before the store opens. A refused patch or a write error goes to the console.
export function changeSettings(fn: (settings: Settings) => SettingsPatch): void {
  settingsStore?.change(fn).catch(err => console.error('Bifrost cannot change the settings.', err))
}

// Zoom the page of the current window (Interface scale, ruling C1).
function setZoom(factor: number): void {
  if (currentWindow && !currentWindow.isDestroyed()) currentWindow.webContents.setZoomFactor(factor)
}

// Apply the Interface scale of the settings. Do nothing before the store opens.
function applyZoom(): void {
  if (settingsStore) setZoom(settingsStore.get().interfaceScale / 100)
}

// Run one effect of a settings change (D2).
function runSettingsEffect(effect: SettingsEffect): void {
  switch (effect.kind) {
    case 'escalation':
      liveRegistry?.setEscalationMs(effect.ms)
      return
    case 'poll':
      liveService?.setActiveInterval(effect.ms)
      return
    case 'login-item':
      if (canSetLoginItem()) app.setLoginItemSettings({ openAtLogin: effect.on })
      return
    case 'menu':
      menuRebuild?.()
      return
    case 'zoom':
      setZoom(effect.factor)
      return
    case 'account-usage':
      if (effect.on) accountUsage?.start()
      else accountUsage?.stop()
      return
    case 'reviews':
      if (effect.on) {
        reviewRunner?.start()
        reviewsWatcher?.start()
      } else {
        reviewRunner?.stop()
        reviewsWatcher?.stop()
        trustWindow?.close()
      }
      return
    case 'reviews-view':
      // A change of Show team requests or of the ignore list needs no gh call.
      reviewsWatcher?.rebuild()
      return
    case 'reviews-poll':
      reviewsWatcher?.reschedule()
      return
    case 'updates':
      updater?.setAuto(effect.on)
      return
  }
}

// Open the settings store. In the packaged app, the real login item state wins over the file
// (D2). A test home does not read the login item. Then send each change to the window and run
// its effects.
async function openSettings(file: string, health: HealthLog): Promise<SettingsStore> {
  const store = await openSettingsStore(file, console.error, health)
  if (canSetLoginItem()) {
    // A failure here must not stop the start.
    try {
      const patch = loginItemPatch(store.get(), app.getLoginItemSettings().openAtLogin)
      if (patch) await store.update(patch)
    } catch (err) {
      console.error('Bifrost cannot read or save the login item state.', err)
    }
  }
  store.onChange((next, prev) => {
    send('settings:changed', next)
    for (const effect of settingsEffects(prev, next)) {
      // A failed effect must not stop the other effects.
      try {
        runSettingsEffect(effect)
      } catch (err) {
        console.error(`Bifrost cannot apply the ${effect.kind} setting.`, err)
      }
    }
  })
  settingsStore = store
  if (store.get().accountUsage) accountUsage?.start()
  applyZoom()
  // Build the menu again with the keys of the file. Before this, it has the default
  // keys.
  menuRebuild?.()
  return store
}

// Show a refused notification one time in the Event log, as a plain line.
function logRefusedNotification(): void {
  const line = eventLog.notice(NOTIFICATION_REFUSED, Date.now())
  if (line) eventBatcher.push([line])
}

// A notification for new direct review requests (R1-5): one request, or a summary of more. It
// shows only when the setting is on and the window is not focused, as for a box. A click shows
// the window and opens the Reviews panel.
function notifyReviewRequest(notice: RequestNotice): void {
  if (!getSettings().notifications || (currentWindow?.isFocused() ?? false)) return
  showNotification(
    { ...notice, label: 'review requests', sessionId: null },
    () => {
      showWindowFn?.()
      // With no loaded page, the open waits for the did-finish-load of the next page.
      if (pendingReviewsOpen.click(REVIEWS_OPEN) !== null) send('reviews:open')
    },
    logRefusedNotification,
  )
}

// The usage notification (spec 8.8). The monitor shows it only when the setting is on. Unlike a
// box, it also shows when the window has focus (user decision, 2026-11-10). A click shows the
// window and opens the Usage HUD.
function notifyUsageLimit(text: { title: string; body: string }): void {
  showNotification(
    { ...text, label: 'usage limit', sessionId: null },
    () => {
      showWindowFn?.()
      // With no loaded page, the open waits for the did-finish-load of the next page.
      if (pendingUsageOpen.click(USAGE_OPEN) !== null) send('usage:open')
    },
    logRefusedNotification,
  )
}

// Make the monitor of the usage notification. It checks nothing until its state file and the
// settings store open. The state file is in the data folder. ~/.claude.json is in the same home
// folder as ~/.claude, so a test home uses its own file.
function startUsageAlerts(
  home: TestHome | null,
  settingsReady: Promise<SettingsStore>,
): UsageAlertMonitor {
  const store = Promise.all([
    openUsageAlertStore(usageAlertsFile(app.getPath('userData'))),
    settingsReady,
  ]).then(([opened]) => opened)
  return createUsageAlertMonitor({
    enabled: () => getSettings().notifications,
    notify: notifyUsageLimit,
    now: () => Date.now(),
    readExtraUsage: () => readExtraUsageFlag(claudeJsonFile(home?.home ?? homedir())),
    store,
  })
}

// What startReviews needs besides the state: the runner of the review rounds works with the
// registry service, claude and the PTYs.
interface ReviewsParts {
  home: TestHome | null
  skillsDir: string
  loginEnv: Promise<Record<string, string>>
  run: Promise<RunClaude | null>
  service: Promise<RegistryService>
  pty(): Promise<PtyManager | null>
}

// Open the Reviews state and make the watcher, the runner and the trust terminal. Then start them
// when Watch GitHub is on. After this, the reviews effect starts and stops them. The state goes to
// bifrostHome, so a test home uses its own state (R1-4). The watcher and the Performance monitor
// use the same gh runner (P11). The runner and the watcher need each other, so each reads the
// other when it is called, not when it is made.
async function startReviews(
  bifrostHome: string,
  gh: Gh,
  settingsReady: Promise<SettingsStore>,
  health: HealthLog,
  parts: ReviewsParts,
): Promise<ReviewsWatcher> {
  const [store, settings, service] = await Promise.all([
    openReviewsStateStore(reviewsStateFile(bifrostHome), console.error, health),
    settingsReady,
    // With no registry service, the panel still works. It has no review rounds then.
    parts.service.catch((): null => {
      console.error('Bifrost cannot start the review rounds.')
      return null
    }),
  ])
  const { home } = parts
  const watcher = createReviewsWatcher({
    emit: snapshot => send('reviews:update', snapshot),
    gh,
    health,
    log: message => console.error(message),
    notify: notifyReviewRequest,
    now: () => Date.now(),
    reviews: {
      afterPoll: poll => reviewRunner?.afterPoll(poll),
      session: key => reviewRunner?.session(key) ?? null,
      sessionOf: key => reviewRunner?.sessionOf(key) ?? null,
      trust: () => reviewRunner?.trust() ?? [],
    },
    settings: () => settings.get(),
    store,
  })
  reviewsWatcher = watcher
  if (service === null) {
    if (!serviceStopped && settings.get().reviewsWatch) watcher.start()
    return watcher
  }
  const claudeJson = claudeJsonFile(home?.home ?? homedir())
  const repoGit = createRepoGit({
    env: async () => ({
      ...childEnv(await parts.loginEnv, { pty: false }),
      ...(home === null ? {} : { GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' }),
    }),
    exec: execFile,
  })
  const repos = createRepoStore({
    bifrostHome,
    git: repoGit,
    remoteBase: remoteBase(home?.home ?? null),
  })
  const sessions = createReviewSessions({
    expectPrSession: name => service.expectPrSession(name),
    forget: id => service.forget(id),
    log: message => console.error(message),
    markStarted: id => service.markStarted(id),
    releasePrSession: name => service.releasePrSession(name),
    run: () => parts.run,
    waitForRow: (match, timeoutMs) => service.waitForRow(match, timeoutMs),
  })
  const runner = createReviewRunner({
    bifrostHome,
    changed: () => watcher.rebuild(),
    claudeJson,
    gh,
    log: message => console.error(message),
    notify: notifyReviewRequest,
    now: () => Date.now(),
    repos,
    requestPoll: () => watcher.requestPoll(),
    rows: () => service.rows(),
    sessions,
    settings: () => settings.get(),
    skillsDir: parts.skillsDir,
    store,
    testHome: home !== null,
    toReviewPr: key => watcher.toReviewPr(key),
    viewer: () => watcher.viewer(),
  })
  reviewRunner = runner
  service.onUpdate(rows => {
    try {
      runner.onRows(rows)
    } catch {
      console.error('The review runner failed on a session update.')
    }
  })
  trustWindow = createTrustWindow({
    isTrusted: async dir => (await trustedDirs(claudeJson, [dir])).has(dir),
    onEnd: end => {
      try {
        send('reviews:trust-end', end)
        runner.trustChanged(end.repo)
        watcher.rebuild()
      } catch {
        console.error('Bifrost could not finish the trust step.')
      }
    },
    pty: parts.pty,
  })
  // The app can quit before the state opens. Then do not start the watcher.
  if (!serviceStopped && settings.get().reviewsWatch) {
    runner.start()
    watcher.start()
  }
  return watcher
}

// True when Bifrost can write to the folder. An error gives false.
function canWriteFolder(folder: string): Promise<boolean> {
  return access(folder, constants.W_OK).then(
    () => true,
    () => false,
  )
}

// Send a new update state to the page. The updater sends from engine events and timers. So a
// failed send must not throw, for example while the window closes.
function sendUpdates(snapshot: UpdatesSnapshot): void {
  try {
    send('updates:update', snapshot)
  } catch (err) {
    console.error('Bifrost cannot send the update state to the window.', err)
  }
}

// Make the updater and start it (updater design sections 4 and 5). Only a release build calls
// this function. The updater starts after the settings store and its state file open. Its check
// timers start only when "Check for updates automatically" is on.
async function startUpdater(
  settingsReady: Promise<SettingsStore>,
  health: HealthLog,
): Promise<void> {
  const log = createUpdateLog(app.getPath('logs'), {
    appendFile,
    mkdir,
    now: () => Date.now(),
    rename,
    stat,
  })
  const [store, settings] = await Promise.all([
    openUpdateStateStore(join(app.getPath('userData'), 'updates.json')),
    settingsReady,
  ])
  // The app can quit before the files open. Then make no updater.
  if (serviceStopped) return
  // electron-updater is CommonJS, so it has only a default import. The read of autoUpdater makes
  // the Squirrel.Mac updater. So only this function reads it.
  const { autoUpdater } = electronUpdater
  // The updater writes its own log. electron-updater must not write to the console.
  autoUpdater.logger = null
  const service = createUpdater({
    appPath: appBundlePath(app.getPath('exe')),
    canWrite: canWriteFolder,
    clearInterval,
    clearTimeout,
    emit: sendUpdates,
    engine: autoUpdater,
    focused: () =>
      currentWindow !== null && !currentWindow.isDestroyed() && currentWindow.isFocused(),
    health,
    log,
    notify: (title, body, onClick) =>
      showNotification(
        { body, label: 'update', sessionId: null, title },
        () => onClick(),
        logRefusedNotification,
      ),
    now: () => Date.now(),
    online: () => net.isOnline(),
    // Squirrel.Mac sends update-downloaded on the autoUpdater of Electron when it has staged the
    // update. electron-updater added its own listener first, when this function read its
    // autoUpdater. So electron-updater knows the staged update before the service does.
    onStaged: listener => {
      nativeUpdater.on('update-downloaded', () => listener())
    },
    setInterval,
    setTimeout,
    settings: () => settings.get(),
    showWindow: () => showWindowFn?.(),
    store,
    version: app.getVersion(),
  })
  updater = service
  updateLog = log
  service.start()
}

// The thermal state of macOS, or null when Electron cannot read it.
function thermalState(): string | null {
  const state = powerMonitor.getCurrentThermalState()
  return state === 'unknown' ? null : state
}

// The free space of the volume of the folder, or null.
async function freeDiskBytes(folder: string): Promise<number | null> {
  try {
    const s = await statfs(folder)
    return s.bavail * s.bsize
  } catch {
    return null
  }
}

// Make and start the Performance monitor, and register its handlers. It reads the PTYs and the
// rows from the module values, so it can start before the PTY manager and the registry load. A
// test home makes no network request and no gh call. The page sends booleans, chat panel IDs and
// a frame rate only.
function startPerformance(
  home: TestHome | null,
  bifrostHome: string,
  gh: Gh,
  health: HealthLog,
): void {
  const delay = createLoopDelay(monitorEventLoopDelay)
  loopDelay = delay
  const homeFolder = home?.home ?? homedir()
  const monitor = createPerformanceMonitor({
    appMetrics: () => app.getAppMetrics(),
    clonesPath: join(bifrostHome, 'reviews', 'repos'),
    cpus: () => cpus(),
    delayMs: () => delay.longestMs(),
    emit: snapshot => send('performance:update', snapshot),
    exec: execFile,
    exists: path =>
      access(path).then(
        () => true,
        () => false,
      ),
    freeDiskBytes: () => freeDiskBytes(homeFolder),
    ghRateLimit: () => readGhRateLimit(gh),
    health,
    network: home === null,
    now: () => Date.now(),
    online: () => net.isOnline(),
    probe: url =>
      probeUrl(
        (u, init) => net.fetch(u, init),
        url,
        () => performance.now(),
      ),
    ptys: () => liveManager?.list() ?? [],
    rateLimit: () => reviewsWatcher?.rateLimit() ?? null,
    rows: () => liveService?.rows() ?? [],
    thermal: thermalState,
  })
  perfMonitor = monitor
  monitor.start()
  ipcMain.handle('performance:snapshot', e => fromPage(e, async () => monitor.current()))
  ipcMain.handle('performance:view', (e, v: unknown) =>
    fromPage(e, async () => monitor.view(checkView(v))),
  )
  ipcMain.handle('performance:fps', (e, value: unknown) =>
    fromPage(e, async () => monitor.fps(checkFps(value))),
  )
  // Clear the past events, then send a new snapshot at once. The live measurements stay.
  ipcMain.handle('performance:clear', e =>
    fromPage(e, async () => {
      health.clear()
      monitor.refresh()
    }),
  )
}

// Load the store and start the registry service.
// The service sends each update of the rows to the current window.
// If the store cannot be read, the service runs with an empty store and does not save.
// The escalation time and the poll interval come from the settings.
async function startService(
  run: Promise<RunClaude | null>,
  settingsReady: Promise<SettingsStore>,
  health: HealthLog,
): Promise<RegistryService> {
  const [opened, settings] = await Promise.all([
    openStore(join(app.getPath('userData'), 'registry.json')),
    settingsReady,
  ])
  const list = async (all: boolean): Promise<AgentList> => {
    const runClaude = await run
    if (!runClaude) return { entries: [], error: 'claude not found' }
    return listAgents(runClaude, { all })
  }
  const now = (): number => Date.now()
  const deps: ServiceDeps = {
    health,
    listActive: () => list(false),
    listAll: () => list(true),
    now,
    readBranch: cwd => readBranch(execFile, cwd),
    readProcessTable: () => readProcessTable(execFile),
    saveStore: store => opened.save(store),
  }
  // Read the settings after the waits. So a change during the waits is in the values.
  const current = settings.get()
  const registry = new SessionRegistry({
    escalationMs: current.escalationMinutes * 60_000,
    store: opened.store,
  })
  const service = new RegistryService(registry, deps, {
    ...SERVICE_TIMING,
    activeMs: current.pollSeconds * 1000,
  })
  // The monitor reads the settings from the store at each update.
  const alerts = createAlertMonitor({
    focused: () => currentWindow?.isFocused() ?? false,
    notify: n =>
      showNotification(
        n,
        sessionId => {
          showWindowFn?.()
          if (sessionId === null) return
          // With no loaded page, the session waits for the did-finish-load of the next page.
          const now = pendingOpen.click(sessionId)
          if (now !== null) send('alerts:open', now)
        },
        logRefusedNotification,
      ),
    now,
    playSound: () => {
      // Do not wait for the sound. A failed sound is not an error for the user.
      execFile(AFPLAY, [SOUND_FILE], { timeoutMs: 5000 }).catch(err =>
        console.error('Bifrost cannot play the alert sound.', err),
      )
    },
    settings: () => settings.get(),
  })
  service.onUpdate((rows, error) => {
    send('registry:update', rows, error)
    alerts.update(rows)
  })
  service.onUsage(usage => {
    send('usage:update', usage)
    usageAlerts?.session(usage)
  })
  service.onEvents(events => eventBatcher.push(eventLog.append(events)))
  liveRegistry = registry
  liveService = service
  // The app can quit before the store loads. Then do not start the service.
  if (!serviceStopped) service.start()
  return service
}

// Register all IPC handlers one time for the app process.
// Call it before any window loads a page. A second call does nothing.
// The main process finds the claude path one time. The renderer cannot set it.
// With a test home (D12), Bifrost uses the paths of the test home, the first claude on the PATH
// and the env of the process. It does not read the env of a login shell.
export function registerIpc(home: TestHome | null = null): void {
  if (registered) return
  registered = true
  testHome = home
  // The health log also writes health.log in the logs folder. Clear does not touch that file.
  const healthFile = createRotatingLog(app.getPath('logs'), 'health.log', {
    appendFile,
    mkdir,
    now: () => Date.now(),
    rename,
    stat,
  })
  // While the Mac is offline, a failed network poll counts as no data (design section 6).
  const health = createHealthLog(
    () => Date.now(),
    () => net.isOnline(),
    line => void healthFile.line(line),
  )
  healthLog = health
  if (home === null) {
    serviceMonitor = createServiceMonitor({
      check: def => checkService(def, fetchJson, Date.now()),
      emit: list => send('service:update', list),
      health,
      now: () => Date.now(),
    })
    serviceMonitor.start()
    accountUsage = createAccountUsagePoller({
      emit: value => {
        send('usage:account-update', value)
        usageAlerts?.account(value)
      },
      fetch: (url, init) => net.fetch(url, init),
      health,
      now: () => Date.now(),
      readToken: () => readAccessToken(execFile, Date.now()),
    })
  }

  const claudePath = home
    ? Promise.resolve(findOnPath('claude', process.env.PATH, defaultIsExecutable))
    : resolveClaudePath(execFile)
  // Start the login-shell env one time. Every claude run and every PTY uses it.
  // process.execPath runs as Node when ELECTRON_RUN_AS_NODE is 1.
  const loginEnv = home
    ? Promise.resolve(stringValues(process.env))
    : loadLoginEnv(execFile, { execPath: process.execPath, fallback: process.env })
  const run = Promise.all([claudePath, loginEnv]).then(([path, env]) =>
    path ? createRunClaude(execFile, path, env) : null,
  )
  // The claude plugin commands of Live details get their own run (D25). In a test home, they
  // get HOME and CLAUDE_CONFIG_DIR of the test home. So they change only files under the test
  // home. Each other claude call uses run, so the session list stays the real one.
  const pluginRun = Promise.all([claudePath, loginEnv]).then(([path, env]) =>
    path ? createRunClaude(execFile, path, pluginEnv(env, home)) : null,
  )
  const getManager = (): Promise<PtyManager | null> => managerPromise as Promise<PtyManager | null>
  // All text and keys that Bifrost types into a session go through this object (D1).
  // A hidden attach opens at the current size of the session (M3).
  const input = new SessionInput({
    pty: getManager,
    readSize: pid => readSessionSize(execFile, pid),
    rows: () => liveService?.rows() ?? [],
  })
  managerPromise = Promise.all([claudePath, loginEnv]).then(([path, env]) => {
    if (!path) return null
    const m = new PtyManager(nodePtySpawn, path, env)
    m.onData((viewId, chunk) => {
      input.data(viewId)
      // Only the main process uses the hidden send views. Their output stays here.
      if (CHAT_VIEW.test(viewId)) send('pty:data', viewId, chunk)
      if (viewId === TRUST_VIEW) send('reviews:trust-data', chunk)
      // A full redraw follows a resize by any client (M0 question 1). So read the size.
      // A sequence split over two chunks is missed. The next redraw or the open recovers it.
      if (chunk.includes(FULL_REDRAW)) sizeWatcher.poke(viewId)
    })
    // close, closeAll and a replacing open do not run the exit callback. So forget here too.
    m.onClose(viewId => {
      sizeWatcher.forget(viewId)
      input.ended(viewId)
    })
    m.onExit((viewId, exitCode, signal) => {
      sizeWatcher.forget(viewId)
      input.ended(viewId)
      if (CHAT_VIEW.test(viewId)) send('pty:exit', viewId, exitCode, signal)
      if (viewId === TRUST_VIEW) trustWindow?.exited()
    })
    liveManager = m
    return m
  })
  const paths = defaultPaths(home?.home ?? homedir())
  // The settings store opens one time. Each user gets the same store.
  const settings = openSettings(join(app.getPath('userData'), 'settings.json'), health)
  usageAlerts = startUsageAlerts(home, settings)
  const service = startService(run, settings, health)
  // gh gets the login-shell env. In a test home, that is the env of the process, so the PATH of
  // the smoke test decides which gh runs.
  const gh = createGh({ env: async () => childEnv(await loginEnv, { pty: false }), exec: execFile })
  const reviews = startReviews(paths.bifrostHome, gh, settings, health, {
    home,
    loginEnv,
    pty: getManager,
    run,
    service,
    skillsDir: skillsSourceDir(app.getAppPath()),
  })
  startPerformance(home, paths.bifrostHome, gh, health)
  // A release build is packaged, has the real home, and has the app-update.yml file of the release
  // config. Only a release build runs the updater and opens What's new by itself. So pnpm dev, a
  // test home and a local build never check for updates and never open What's new by themselves.
  const releaseBuild =
    app.isPackaged && home === null && existsSync(join(process.resourcesPath, 'app-update.yml'))
  if (releaseBuild) {
    startUpdater(settings, health).catch(err =>
      console.error('Bifrost cannot start the updater.', err),
    )
  }
  // The release notes (What's new and Settings > Updates > Release notes). The source reads GitHub
  // only when a view opens. A test home reads the file github-releases.json of the test home, so a
  // test never calls GitHub.
  const releaseNotes = createReleaseNotesSource({
    fetch: home
      ? fileFetch(join(home.home, 'github-releases.json'))
      : (url, init) => net.fetch(url, init),
    log: line => console.error(line),
    now: () => Date.now(),
  })
  const whatsNew = releaseBuild
    ? createWhatsNew({
        openStore: () => openReleaseNotesStore(releaseNotesFile(app.getPath('userData'))),
        setupDone: async () => (await settings).get().setupDone,
        version: app.getVersion(),
      })
    : null
  ipcMain.handle('release-notes:list', e => fromPage(e, () => releaseNotes.list()))
  // The page asks one time after it loads. Only the first call can open What's new.
  ipcMain.handle('release-notes:whats-new', e =>
    fromPage(e, async () => (await whatsNew?.take()) ?? null),
  )
  // The page sends a version or null. The main process finds the URL, so the page never gives one.
  ipcMain.handle('release-notes:open', (e, version: unknown) =>
    fromPage(e, async () => shell.openExternal(releaseNotes.urlOf(version))),
  )
  ipcMain.handle('settings:get', e => fromPage(e, async () => (await settings).get()))
  // The key recorder starts or ends. A value that is not a boolean is refused.
  ipcMain.handle('settings:recording', (e, on: unknown) =>
    fromPage(e, async () => keyRecording.set(on)),
  )
  // The store checks each value. It refuses a patch with an unknown key or a bad value.
  ipcMain.handle('settings:set', (e, patch: unknown) =>
    fromPage(e, async () => (await settings).update(patch)),
  )
  ipcMain.handle('system:info', e =>
    fromPage(e, async () => ({
      packaged: app.isPackaged,
      testHome: testHome !== null,
      version: app.getVersion(),
    })),
  )
  // The UI store opens one time. The handlers use the same store.
  const uiStore = openUiStore(join(app.getPath('userData'), 'ui-state.json'), console.error, health)
  ipcMain.handle('ui:load', e => fromPage(e, async () => (await uiStore).load()))
  ipcMain.handle('ui:save', (e, data: unknown) =>
    fromPage(e, async () => (await uiStore).save(data)),
  )

  ipcMain.handle('display:get', e =>
    fromPage(e, async (): Promise<DisplayMode> => modeController?.get() ?? 'window'),
  )
  ipcMain.handle('display:set', (e, mode: unknown) =>
    fromPage(e, async () => {
      if (!isDisplayMode(mode)) throw new Error('refused: not a display mode')
      if (!modeController) throw new Error('refused: no window')
      await modeController.set(mode)
    }),
  )

  ipcMain.handle('claude:path', () => claudePath)
  ipcMain.handle('claude:version', async (): Promise<ClaudeVersion> => {
    const runClaude = await run
    if (!runClaude) return { minimum: MIN_CLAUDE_VERSION, ok: false, version: null }
    return checkClaudeVersion(runClaude)
  })
  ipcMain.handle('registry:rows', async () => (await service).rows())
  ipcMain.handle('events:list', e => fromPage(e, async () => eventLog.list()))
  ipcMain.handle('service:status', e => fromPage(e, async () => serviceList(serviceMonitor)))
  ipcMain.handle('service:open-page', (e, id: unknown) =>
    fromPage(e, async () => {
      const def = SERVICES.find(s => s.id === id)
      if (!def) throw new Error('refused: unknown service')
      await shell.openExternal(def.base)
    }),
  )
  ipcMain.handle('usage:get', e => fromPage(e, async () => (await service).usage()))
  ipcMain.handle('usage:account-get', e => fromPage(e, async () => accountUsage?.current() ?? null))
  ipcMain.handle('usage:hud-opened', e =>
    fromPage(e, async () => {
      accountUsage?.requestPoll()
    }),
  )
  // The Reviews panel. The page sends a PR key or nothing. Each call except the snapshot refuses
  // while Watch GitHub is off. Open on GitHub opens only a URL that gh gave and that starts with
  // https://github.com/.
  ipcMain.handle('reviews:snapshot', e => fromPage(e, async () => (await reviews).current()))
  ipcMain.handle('reviews:refresh', e =>
    fromPage(e, async () => whileOn(await reviews).requestPoll()),
  )
  ipcMain.handle('reviews:pause', (e, key: unknown) =>
    fromPage(e, async () => whileOn(await reviews).pause(checkPrKey(key))),
  )
  ipcMain.handle('reviews:end-pause', (e, key: unknown) =>
    fromPage(e, async () => whileOn(await reviews).endPause(checkPrKey(key))),
  )
  ipcMain.handle('reviews:open-pr', (e, key: unknown) =>
    fromPage(e, async () => shell.openExternal(urlToOpen(await reviews, key))),
  )
  // The review rounds. The page sends a PR key of a To review row, a repository key of the trust
  // list, terminal text and sizes, or nothing. It never sends a path, a URL or a command.
  ipcMain.handle('reviews:review', (e, key: unknown) =>
    fromPage(e, async () => {
      const k = toReviewKey(whileOn(await reviews), checkPrKey(key))
      const runner = reviewRunner
      if (runner === null) throw new Error(NO_RUNNER)
      await friendlyFailure(() => runner.review(k), REVIEW_FAILED, reviewLog)
    }),
  )
  ipcMain.handle('reviews:cancel', (e, key: unknown) =>
    fromPage(e, async () => {
      const k = toReviewKey(whileOn(await reviews), checkPrKey(key))
      const runner = reviewRunner
      if (runner === null) throw new Error(NO_RUNNER)
      await friendlyFailure(() => runner.cancel(k), REVIEW_FAILED, reviewLog)
    }),
  )
  ipcMain.handle('reviews:stop-session', (e, key: unknown) =>
    fromPage(e, async () => {
      const k = toReviewKey(whileOn(await reviews), checkPrKey(key))
      const runner = reviewRunner
      if (runner === null) throw new Error(NO_RUNNER)
      await friendlyFailure(() => runner.stopSession(k), REVIEW_FAILED, reviewLog)
    }),
  )
  ipcMain.handle('reviews:trust-open', (e, repo: unknown) =>
    fromPage(e, async () => {
      whileOn(await reviews)
      const runner = reviewRunner
      if (typeof repo !== 'string' || !REPO_KEY.test(repo) || runner === null) {
        throw new Error(REFUSED_UNKNOWN_REPO)
      }
      const cwd = runner.clonePathOf(repo)
      if (!runner.trust().some(need => need.repo === repo) || cwd === null) {
        throw new Error(REFUSED_UNKNOWN_REPO)
      }
      try {
        await trustWindow?.open(repo, cwd)
      } catch (error) {
        console.error('Bifrost cannot open the trust terminal.', error)
        throw new Error(TRUST_OPEN_FAILED)
      }
      // The open ends with no terminal when claude is not on the PATH.
      if (trustWindow?.current() !== repo) throw new Error(TRUST_OPEN_FAILED)
    }),
  )
  ipcMain.handle('reviews:trust-write', (e, data: unknown) =>
    fromPage(e, async () => {
      whileOn(await reviews)
      if (typeof data !== 'string' || Buffer.byteLength(data) > MAX_TRUST_WRITE) {
        throw new Error(REFUSED_BAD_TERMINAL)
      }
      trustWindow?.write(data)
    }),
  )
  ipcMain.handle('reviews:trust-resize', (e, cols: unknown, rows: unknown) =>
    fromPage(e, async () => {
      whileOn(await reviews)
      if (!isTerminalSize(cols) || !isTerminalSize(rows)) throw new Error(REFUSED_BAD_TERMINAL)
      trustWindow?.resize(cols, rows)
    }),
  )
  // A closed trust panel ends the trust step. The repository then gets one start, also when the
  // trust read says no.
  ipcMain.handle('reviews:trust-close', e =>
    fromPage(e, async () => {
      whileOn(await reviews)
      const repo = trustWindow?.current() ?? null
      trustWindow?.close()
      if (repo !== null) reviewRunner?.trustChanged(repo)
    }),
  )
  // Delete the clones also while Watch GitHub is off.
  ipcMain.handle('reviews:remove-clones', e =>
    fromPage(e, async () => {
      await reviews
      const runner = reviewRunner
      if (runner === null) throw new Error(NO_RUNNER)
      await friendlyFailure(() => runner.removeClones(), REMOVE_CLONES_FAILED, reviewLog)
    }),
  )
  // The updater (updater design). With no updater, the snapshot has available false, and the other
  // calls do nothing.
  ipcMain.handle('updates:snapshot', e =>
    fromPage(
      e,
      async () =>
        updater?.snapshot() ?? { ...EMPTY_UPDATES, available: false, version: app.getVersion() },
    ),
  )
  // The check continues after the reply. Its states come through updates:update.
  ipcMain.handle('updates:check', e =>
    fromPage(e, async () => {
      void updater?.checkNow()
    }),
  )
  ipcMain.handle('updates:restart', e =>
    fromPage(e, async () => {
      updater?.restart()
    }),
  )
  ipcMain.handle('updates:show-log', e =>
    fromPage(e, async () => {
      const log = updateLog
      if (log === null) return
      // The log file does not exist before the first log line. Make it, so the open finds a file.
      await mkdir(dirname(log.path), { recursive: true })
      await appendFile(log.path, '')
      const error = await shell.openPath(log.path)
      if (error) console.error(`Bifrost cannot open the update log. ${error}`)
    }),
  )
  ipcMain.handle('registry:set-alias', (e, sessionId: unknown, name: unknown) =>
    fromPage(e, async () => {
      const check = checkAliasRequest(sessionId, name)
      if (!check.ok) throw new Error('refused: bad name')
      if (!(await service).setAlias(sessionId as string, check.name)) {
        throw new Error('refused: unknown session')
      }
    }),
  )
  ipcMain.handle('registry:set-priority', (e, sessionId: unknown, priority: unknown) =>
    fromPage(e, async () => {
      if (typeof sessionId !== 'string' || (priority !== null && !isPriority(priority))) {
        throw new Error('refused: bad priority')
      }
      if (!(await service).setPriority(sessionId, priority)) {
        throw new Error('refused: unknown session')
      }
    }),
  )
  // Each watchlist handler checks the input. Then the service changes the watchlist.
  const watchHandler = (
    channel: string,
    change: (service: RegistryService, a: string, b: unknown) => boolean,
    valid: (a: unknown, b: unknown) => boolean,
    code: string,
  ): void => {
    ipcMain.handle(channel, (e, a: unknown, b: unknown) =>
      fromPage(e, async () => {
        if (typeof a !== 'string') throw new Error('refused: bad session ID')
        if (!valid(a, b)) throw new Error(code)
        if (!change(await service, a, b)) throw new Error('refused: unknown session')
      }),
    )
  }
  watchHandler(
    'registry:watch-add',
    (s, id, colour) => s.watchAdd(id, colour as WatchColour),
    (_id, colour) => isWatchColour(colour),
    'refused: bad watch colour',
  )
  watchHandler(
    'registry:watch-remove',
    (s, id) => s.watchRemove(id),
    () => true,
    'refused: bad session ID',
  )
  watchHandler(
    'registry:watch-colour',
    (s, id, colour) => s.watchColour(id, colour as WatchColour),
    (_id, colour) => isWatchColour(colour),
    'refused: bad watch colour',
  )
  watchHandler(
    'registry:watch-move',
    (s, id, before) => s.watchMove(id, before as string | null),
    (_id, before) => before === null || typeof before === 'string',
    'refused: bad watch move',
  )
  // The renderer sends IDs only. The main process finds the row, the path and the app.
  const exists = (path: string): Promise<boolean> =>
    access(path).then(
      () => true,
      () => false,
    )
  const actions = createActions({
    apps: () => findProjectApps(homedir(), exists, getSettings().terminalApp),
    exec: execFile,
    rows: () => liveService?.rows() ?? [],
    writeClipboard: text => clipboard.writeText(text),
  })
  ipcMain.handle('actions:apps', e => fromPage(e, () => actions.listApps()))
  // The terminal apps for the Settings select. The list has the IDs and the labels only.
  ipcMain.handle('actions:terminal-apps', e =>
    fromPage(e, async () =>
      (await findTerminalApps(homedir(), exists)).map(({ id, label }) => ({ id, label })),
    ),
  )
  ipcMain.handle('actions:open-project', (e, sessionId: unknown, appId: unknown) =>
    fromPage(e, () => actions.openProject(sessionId, appId)),
  )
  ipcMain.handle('actions:copy-session-id', (e, sessionId: unknown) =>
    fromPage(e, () => actions.copySessionId(sessionId)),
  )
  // Open in terminal. The command files are in <bifrostHome>/run and only the user can use them.
  const runDir = join(paths.bifrostHome, 'run')
  const terminals = createTerminalLauncher({
    apps: () => findProjectApps(homedir(), exists, getSettings().terminalApp),
    claudePath: () => claudePath,
    exec: execFile,
    fileIcon: path =>
      appIcon(path, {
        fileIcon: (file, size) => app.getFileIcon(file, { size }),
        thumbnail: (file, width, height) =>
          nativeImage.createThumbnailFromPath(file, { height, width }),
      }),
    remove: file => rm(file, { force: true }),
    rows: () => liveService?.rows() ?? [],
    runDir,
    terminalOf: id => liveService?.terminalOf(id),
    writeClipboard: text => clipboard.writeText(text),
    writeScript: async (file, text) => {
      await mkdir(runDir, { mode: 0o700, recursive: true })
      await writeFile(file, text, { mode: 0o700 })
    },
  })
  ipcMain.handle('actions:open-in-terminal', (e, sessionId: unknown) =>
    fromPage(e, () => terminals.openInTerminal(sessionId)),
  )
  ipcMain.handle('actions:terminal-icon', (e, sessionId: unknown) =>
    fromPage(e, () => terminals.terminalIcon(sessionId)),
  )
  // The session commands. The renderer sends session IDs and the New session values only.
  // The main process finds the row, the PID and the directory, and makes the claude arguments.
  // SIGTERM goes only to the process of an external session in Take control (D6).
  // process-info refuses a PID that is not an integer above 1, before each kill.
  const kill = (pid: number, signal: string | number): void => {
    process.kill(pid, signal)
  }
  // Take control reads only the start of the transcript of the session (Task 15). Hand over reads
  // the lines after a baseline (spec 8 of the skills design).
  const projectsDir = join(homedir(), '.claude', 'projects')
  // The Hand over run. The request prompt goes through the same SessionInput as Send message.
  // Bifrost writes each note to a new file in its handovers folder.
  const handOver = createHandOver({
    now: () => Date.now(),
    readTail: (file, offset) => readTail(file, offset, TRANSCRIPT_TAIL_MAX),
    requestId: () => randomUUID().slice(0, 8),
    rows: () => liveService?.rows() ?? [],
    rules: () => readFile(handOverRulesPath(app.getAppPath()), 'utf8'),
    send: (id, text) => input.send(id, text),
    size: async file => (await stat(file)).size,
    sleep: ms => new Promise(resolve => setTimeout(resolve, ms)),
    transcript: row => findTranscript(projectsDir, row),
    writeNote: (name, note, at) =>
      writeNoteFile(join(paths.bifrostHome, 'handovers'), noteFileName(name, at), note),
  })
  const sessions = createSessionActions({
    checkWorktree: worktree => checkWorktreeHead(worktree, execFile),
    dirInfo: dir => dirInfo(execFile, stat, dir),
    forget: id => liveService?.forget(id),
    handOver,
    hasMessages: id => hasMessages(projectsDir, id),
    isAlive: pid => isAlive(kill, pid),
    markStarted: id => liveService?.markStarted(id),
    markStopped: id => liveService?.markStopped(id),
    processName: pid => processName(execFile, pid),
    rememberWorktree: (id, worktree) => {
      liveService?.rememberWorktree(id, worktree)
    },
    rows: () => liveService?.rows() ?? [],
    run: () => run,
    signal: (pid, signal) => sendSignal(kill, pid, signal),
    trackedChanges: worktree => trackedChanges(worktree, execFile),
    waitForRow: async (match, timeoutMs) => (await service).waitForRow(match, timeoutMs),
  })
  const worktrees = createWorktreeActions({
    exec: execFile,
    rows: () => liveService?.rows() ?? [],
  })
  ipcMain.handle('sessions:delete-check', (e, sessionId: unknown) =>
    fromPage(e, () => worktrees.deleteCheck(sessionId)),
  )
  ipcMain.handle('sessions:open-worktree', (e, sessionId: unknown) =>
    fromPage(e, () => worktrees.openWorktree(sessionId)),
  )
  // The PR of a session. The page sends the session ID only. The main process finds the folder
  // and the branch from the row, and opens only a URL that gh gave.
  const prs = createPrLookup({
    env: async () => childEnv(await loginEnv, { pty: false }),
    exec: execFile,
    exists: dir =>
      access(dir).then(
        () => true,
        () => false,
      ),
    now: () => Date.now(),
  })
  const prRow = (sessionId: unknown) => {
    if (typeof sessionId !== 'string') throw new Error('refused: bad session ID')
    const row = liveService?.rows().find(r => r.sessionId === sessionId)
    if (!row) throw new Error('refused: unknown session')
    return row
  }
  ipcMain.handle('info:pr', (e, sessionId: unknown) =>
    fromPage(e, async () => {
      const row = prRow(sessionId)
      return prs.lookup(row.cwd, row.branch)
    }),
  )
  ipcMain.handle('info:open-pr', (e, sessionId: unknown) =>
    fromPage(e, async () => {
      const row = prRow(sessionId)
      const url = await prUrlToOpen(prs, row.cwd, row.branch)
      if (url !== null) await shell.openExternal(url)
    }),
  )
  ipcMain.handle('sessions:create', (e, spec: unknown) => fromPage(e, () => sessions.create(spec)))
  ipcMain.handle('sessions:stop', (e, sessionId: unknown) =>
    fromPage(e, () => sessions.stop(sessionId)),
  )
  // seen is the check that the Delete dialog showed. session-actions checks each value.
  ipcMain.handle('sessions:remove', (e, sessionId: unknown, confirmed: unknown, seen: unknown) =>
    fromPage(e, () => sessions.remove(sessionId, confirmed, seen)),
  )
  ipcMain.handle('sessions:resume', (e, sessionId: unknown) =>
    fromPage(e, () => sessions.resume(sessionId)),
  )
  ipcMain.handle('sessions:resume-all', e => fromPage(e, () => sessions.resumeAll()))
  ipcMain.handle('sessions:take-control', (e, sessionId: unknown, confirmed: unknown) =>
    fromPage(e, () => sessions.takeControl(sessionId, confirmed)),
  )
  // The page sends the session ID only. The main process finds the row and makes the prompts.
  ipcMain.handle('sessions:hand-over', (e, sessionId: unknown) =>
    fromPage(e, () => sessions.handOver(sessionId)),
  )
  ipcMain.handle('sessions:dir-info', (e, dir: unknown) => fromPage(e, () => sessions.dirInfo(dir)))
  // The picker starts at the directory from the renderer when it is absolute, else at home.
  ipcMain.handle('sessions:pick-directory', (e, defaultPath: unknown) =>
    fromPage(e, async () => {
      const options: OpenDialogOptions = {
        defaultPath:
          typeof defaultPath === 'string' && defaultPath.startsWith('/') ? defaultPath : homedir(),
        properties: ['openDirectory', 'createDirectory'],
      }
      const win = currentWindow && !currentWindow.isDestroyed() ? currentWindow : null
      const result = await (win
        ? dialog.showOpenDialog(win, options)
        : dialog.showOpenDialog(options))
      return result.canceled ? null : (result.filePaths[0] ?? null)
    }),
  )
  // Only one Live details action runs at a time. A second call rejects. The start runs first,
  // and an action that comes during the start waits for it.
  const serial = createSerialRunner()
  // Live details. One server listens for the lines of the mod (D9).
  // The four actions use one serial runner. Then the removal of an old hook install and a plugin
  // command never run at the same time.
  const liveServer = createLiveServer({
    now: () => Date.now(),
    onEvent: ev => liveService?.pushLive(ev),
    socketPath: join(paths.bifrostHome, 'live.sock'),
  })
  const live = createLiveControl({
    clearLive: () => liveService?.clearLive(),
    cli: async () => {
      const runClaude = await pluginRun
      return runClaude ? createPluginCli(runClaude) : null
    },
    forceListen: process.env.BIFROST_LIVE_LISTEN === '1',
    health,
    liveSessions: () => liveService?.liveCount() ?? 0,
    modDir: join(paths.bifrostHome, 'mod'),
    modSource: modSourceDir(app.getAppPath()),
    oldInstall: () => oldInstallStatus(paths),
    removeOldInstall: () => uninstall(paths, new Date()),
    server: liveServer,
    version: async (): Promise<ClaudeVersion> => {
      const runClaude = await run
      if (!runClaude) return { minimum: LIVE_MIN_CLAUDE_VERSION, ok: false, version: null }
      return checkClaudeVersion(runClaude, LIVE_MIN_CLAUDE_VERSION)
    },
  })
  liveControl = live
  // The skills plugin. It uses the same claude run and the same serial runner as Live details.
  const skills = createSkillsControl({
    cli: async () => {
      const runClaude = await pluginRun
      return runClaude
        ? createPluginCli(runClaude, { marketplace: SKILLS_MARKETPLACE, plugin: SKILLS_PLUGIN_ID })
        : null
    },
    dir: join(paths.bifrostHome, 'skills'),
    source: skillsSourceDir(app.getAppPath()),
  })
  // Nothing else cleans the data of the old hooks. Remove it one time at start, before the live
  // control starts. keepOldScripts decides if bin/ stays.
  // A failure never stops the start.
  const cleanOldHookData = async (): Promise<void> => {
    try {
      const old = await oldInstallStatus(paths)
      await removeOldHookData(paths.bifrostHome, keepOldScripts(old))
    } catch (err) {
      console.warn('Live details: the clean-up of old hook data failed.', err)
    }
  }
  // Start after the service loads, so an event finds the service.
  // Do not start when the app quits before the store loads.
  // The start runs first in the serial runner of the four actions. An action that comes before
  // the start ends waits for it. So two copies of the mod folder never run at the same time.
  void serial
    .runFirst(async () => {
      await service
      if (serviceStopped) return
      await cleanOldHookData()
      if (!serviceStopped) await live.start()
      if (!serviceStopped) await skills.start()
    })
    .catch(err => console.warn('Live details: the start failed.', err))
  const liveAction = (channel: string, fn: () => Promise<LiveStatus>): void => {
    ipcMain.handle(channel, e => fromPage(e, () => serial.run(fn)))
  }
  // The status read waits for the start, but it does not take the lock. Else a read before the
  // start ends can give listening false for a plugin that is on, and the side bar shows a false
  // warning. The start always ends. It returns at once when the app quits first, and each claude
  // call in it has a time limit.
  ipcMain.handle('live:status', e => fromPage(e, () => serial.afterFirst(() => live.status())))
  liveAction('live:install', () => live.install())
  liveAction('live:enable', () => live.enable())
  liveAction('live:disable', () => live.disable())
  liveAction('live:uninstall', () => live.uninstall())
  // The skills actions use the same serial runner as Live details.
  const skillsAction = (channel: string, fn: () => Promise<SkillsStatus>): void => {
    ipcMain.handle(channel, e => fromPage(e, () => serial.run(fn)))
  }
  ipcMain.handle('skills:status', e => fromPage(e, () => serial.afterFirst(() => skills.status())))
  skillsAction('skills:install', () => skills.install())
  skillsAction('skills:enable', () => skills.enable())
  skillsAction('skills:disable', () => skills.disable())
  skillsAction('skills:uninstall', () => skills.uninstall())
  // The renderer can open, write, resize and close only chat views.
  // Only the main process uses send views (D1).
  const isChatView = (viewId: unknown): viewId is string =>
    typeof viewId === 'string' && CHAT_VIEW.test(viewId)
  ipcMain.handle(
    'pty:open',
    async (
      e,
      viewId: unknown,
      args: string[],
      opts: { cwd: string; cols: number; rows: number },
    ) => {
      if (!isChatView(viewId)) throw new Error(REFUSED_NOT_CHAT)
      // Get the page token before the first wait.
      const token = page.token()
      const manager = await getManager()
      if (!manager) throw new Error('claude not found')
      // Open a PTY only for an attach to an owned session that is not parked.
      // The attach must be for the session of the chat view.
      const first = checkChatOpen((await service).rows(), viewId, args)
      if (!first.ok) throw new Error(first.reason)
      // One attach serves each session. Wait until a hidden send of this session ends (D1).
      await input.idle(first.sessionId)
      // The rows can change during the wait. Check them again.
      const again = checkChatOpen((await service).rows(), viewId, args)
      if (!again.ok) throw new Error(again.reason)
      // The page can end during the waits above. Then no page owns the PTY, so do not open it.
      if (!isLivePage(e.sender, token)) {
        throw new Error('refused: the page that asked for the PTY is gone')
      }
      const pid = manager.open(viewId, args, { ...opts, cwd: resolve(process.cwd(), opts.cwd) })
      input.opened(viewId, args[1])
      sizeWatcher.poke(viewId)
      return pid
    },
  )
  ipcMain.handle('pty:write', async (_e, viewId: unknown, data: unknown) => {
    if (!isChatView(viewId) || typeof data !== 'string') return false
    // The left arrow key can open the agent view. A send to this view then waits (spec 8.5).
    if (hasLeftKey(data)) input.leftKey(viewId)
    const manager = await getManager()
    return manager ? manager.write(viewId, data) : false
  })
  // A click on a link of a chat window opens the link outside Bifrost (main/pty/open-link.ts).
  ipcMain.handle('pty:open-link', (e, uri: unknown) =>
    fromPage(e, () =>
      openLink(uri, {
        hostname,
        openExternal: url => shell.openExternal(url),
        openPath: path => shell.openPath(path),
        showItemInFolder: path => shell.showItemInFolder(path),
        stat,
      }),
    ),
  )
  ipcMain.handle('pty:resize', async (_e, viewId: unknown, cols: number, rows: number) => {
    if (!isChatView(viewId)) return
    ;(await getManager())?.resize(viewId, cols, rows)
  })
  ipcMain.handle('pty:close', async (_e, viewId: unknown, signal?: string) => {
    if (!isChatView(viewId)) return
    sizeWatcher.forget(viewId)
    input.ended(viewId)
    ;(await getManager())?.close(viewId, signal)
  })
  // The renderer reports the agent view of a chat window. Then a send to it rejects.
  ipcMain.handle('pty:set-blocked', (e, viewId: unknown, blocked: unknown) =>
    fromPage(e, async () => input.setBlocked(viewId, blocked)),
  )
  // The renderer sends the session ID and the text only. The main process finds the row,
  // checks it and the red box, and writes into the chat PTY or a hidden attach.
  ipcMain.handle('input:send', (e, sessionId: unknown, text: unknown) =>
    fromPage(e, () => input.send(sessionId, text)),
  )
  ipcMain.handle('input:interrupt', (e, sessionId: unknown) =>
    fromPage(e, () => input.interrupt(sessionId)),
  )
  // The size of the session TTY. The row must be owned and have a PID. Bifrost only reads it.
  ipcMain.handle('pty:session-size', (e, sessionId: unknown) =>
    fromPage(e, async () => {
      if (typeof sessionId !== 'string') return null
      await service
      const pid = pidOfSession(sessionId)
      return pid === undefined ? null : readSessionSize(execFile, pid)
    }),
  )
}

// Make a window the target of pty:data, pty:exit, registry:update and usage:update.
// A reload or a renderer crash does not run the cleanup code of the page.
// The main process must close the PTYs of the old page.
// It closes all PTYs when a new page loads and when the renderer stops.
// When the window closes, close all PTYs and clear the window reference.
export function attachWindow(win: BrowserWindow): void {
  currentWindow = win
  // A new page has no recorder. The old page cannot say that it ended.
  resetOnPageEnd(win, keyRecording)
  win.webContents.on('did-navigate', () => {
    endPage()
  })
  // Apply the Interface scale to each page that loads.
  win.webContents.on('dom-ready', () => {
    if (currentWindow === win) applyZoom()
  })
  // A renderer that stops with a reason other than clean-exit is a crash (P8). Only this listener
  // reports to the health log, so each crash gives one event.
  win.webContents.on('render-process-gone', (_e, details) => {
    if (currentWindow === win) unloadPendingOpens()
    if (details.reason !== 'clean-exit') healthLog?.crash('window', details.reason)
    endPage()
  })
  win.on('closed', () => {
    if (currentWindow === win) {
      currentWindow = null
      unloadPendingOpens()
    }
    endPage()
  })
  // A notification click while no page is loaded waits for the next load (D13).
  win.webContents.on('did-start-loading', () => {
    if (currentWindow === win) unloadPendingOpens()
  })
  win.webContents.on('did-finish-load', () => {
    if (currentWindow !== win) return
    const sessionId = pendingOpen.load()
    if (sessionId !== null) send('alerts:open', sessionId)
    if (pendingReviewsOpen.load() !== null) send('reviews:open')
    if (pendingUsageOpen.load() !== null) send('usage:open')
  })
}

// The page ended. Close its PTYs. The Performance monitor then stops its fast checks, because
// no panel shows until the next page reports (design section 7).
function endPage(): void {
  page.end()
  perfMonitor?.pageGone()
}

// No page is loaded now. A notification click waits for the next page.
function unloadPendingOpens(): void {
  pendingOpen.unload()
  pendingReviewsOpen.unload()
  pendingUsageOpen.unload()
}

// Close all PTYs. Call it when the app quits.
export function closeAllPtys(): void {
  endPage()
}

// Stop the registry service, the server of Live details, the pollers, the updater, the Performance
// monitor and its delay histogram. Call it when the app quits.
export function stopRegistry(): void {
  serviceStopped = true
  liveService?.stop()
  eventBatcher.stop()
  liveControl?.stop()
  serviceMonitor?.stop()
  accountUsage?.stop()
  reviewRunner?.stop()
  trustWindow?.close()
  reviewsWatcher?.stop()
  updater?.stop()
  perfMonitor?.stop()
  loopDelay?.stop()
}
