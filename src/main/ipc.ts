import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { constants, existsSync } from 'node:fs'
import {
  access,
  appendFile,
  mkdir,
  readFile,
  realpath,
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
import { localDate } from '../shared/daily-schedule'
import { LIVE_MIN_CLAUDE_VERSION } from '../shared/live'
import { type ModulesSnapshot, REFUSED_BAD_MODULE_INPUT } from '../shared/modules'
import { isPriority } from '../shared/priority'
import { ITEM_ID, MAX_ANSWERS, REPO_KEY } from '../shared/reviews'
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
import { recordNotifications, showNotification } from './alerts/notifier'
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
import { createRunClaudeJob } from './claude/job-runner'
import { createSpawnLines, type SpawnLines } from './claude/spawn-lines'
import { checkClaudeVersion, MIN_CLAUDE_VERSION } from './claude/version'
import {
  checkBoolean,
  checkDraftText,
  checkId,
  checkPageTrigger,
  createDailyUpdateService,
  DAILY_TITLE,
  type DailyUpdateService,
  dailyFolder,
} from './daily-update/service'
import { skillExportFile, writeSkillExport } from './daily-update/skill-export'
import { dailyStateFile, openDailyStateStore } from './daily-update/state-store'
import { chatEventSender, registerDictationIpc } from './dictation/dictation-ipc'
import { createDictationService, type DictationService } from './dictation/dictation-service'
import { helperToRun } from './dictation/helper-path'
import { createVimModeCheck, fileStamp } from './dictation/vim-mode'
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
import { mainFetch } from './main-network'
import { createDiscuss, type Discuss } from './modules/discuss'
import { activeModule, createHeimdall, type ModuleNotice } from './modules/heimdall'
import { createJobs, type Jobs, moduleJobsRoot, watchLocalDay } from './modules/jobs'
import { createModuleDataStore, type ModuleDataStore } from './modules/module-data'
import { modulesSnapshot } from './modules/module-rows'
import { createModuleService, moduleCodeRoot } from './modules/module-service'
import {
  carriedDiscussSession,
  type ModulesState,
  type ModulesStateStore,
  modulesStateFile,
  openModulesStateStore,
  withDiscussSession,
  withoutDiscussSession,
} from './modules/module-state'
import { createFromPage } from './page-guard'
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
import { createOutputBatcher } from './pty/output-batcher'
import { PageScope } from './pty/page-scope'
import { PtyManager } from './pty/pty-manager'
import { chatSessionOf, createSessionSizeReader, SessionSizeWatcher } from './pty/session-size'
import { isTerminalSize, REFUSED_BAD_SIZE } from './pty/terminal-size'
import { createBranchReader } from './registry/git-branch'
import { checkVisible } from './registry/poll-interval'
import { SessionRegistry } from './registry/registry'
import { RegistryService, SERVICE_TIMING, type ServiceDeps } from './registry/service'
import { openStore } from './registry/store-file'
import { readProcessTable } from './registry/terminal-app'
import { createReleaseNotesSource, fileFetch } from './release-notes/source'
import { openReleaseNotesStore, releaseNotesFile } from './release-notes/state-store'
import { createWhatsNew } from './release-notes/whats-new'
import { type Approver, createApprover } from './reviews/approve'
import { checkDraftEdits, createDraftEditor, type DraftEditor } from './reviews/draft-panel'
import { friendlyFailure } from './reviews/friendly-failure'
import { createGh, type Gh } from './reviews/gh'
import { createRepoGit } from './reviews/repo-git'
import { reposRoot } from './reviews/repo-paths'
import { createRepoStore, remoteBase } from './reviews/repo-store'
import { createRequestJob } from './reviews/request-job'
import { createFixPusher, createSignedPusher } from './reviews/request-push'
import { claudeSettingsFile } from './reviews/request-session'
import { createReviewJob } from './reviews/review-job'
import { createReviewSessions } from './reviews/review-session'
import {
  createReviewRunner,
  REFUSED_BAD_ANSWER,
  REFUSED_NOT_HANDLEABLE,
  REFUSED_UNKNOWN_REPO,
  type ReviewRunner,
} from './reviews/rounds'
import { MAX_ANSWER } from './reviews/state'
import { openReviewsStateStore, reviewsStateFile } from './reviews/state-store'
import { createTrustWindow, TRUST_VIEW, type TrustWindow, trustedDirs } from './reviews/trust'
import {
  approveKey,
  checkPrKey,
  commentUrlToOpen,
  createReviewsWatcher,
  draftKey,
  IDLE_MINE,
  mineKey,
  type RequestNotice,
  type ReviewsWatcher,
  removeKey,
  rowKey,
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
import { findOnPath, pluginEnv, recordTestPaths, type TestHome } from './test-home'
import { openUpdateLog } from './updates/open-log'
import { appBundlePath } from './updates/rules'
import { openUpdateStateStore } from './updates/state-store'
import { createUpdateLog, type UpdateLog, updateLogPath } from './updates/update-log'
import { createUpdater, type Updater } from './updates/updater'
import { claudeJsonFile, readClaudeJson, readExtraUsageFlag } from './usage-alerts/claude-json'
import { createUsageAlertMonitor, type UsageAlertMonitor } from './usage-alerts/monitor'
import { openUsageAlertStore, usageAlertsFile } from './usage-alerts/state-store'
import type { ModeController } from './window/display-mode'
import { seenFocused, seenVisible } from './window/show-window'
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

// One reader for all size reads. It keeps the TTY device of a pid for 30 s.
const readSessionSize = createSessionSizeReader(execFile)

// Reads the session size after a redraw. It sends the size to the page when it changes.
const sizeWatcher = new SessionSizeWatcher({
  emit: (viewId, size) => send('pty:size', viewId, size),
  pidOf: pidOfView,
  read: readSessionSize,
})
// The main process sets liveService and liveRegistry when the store loads.
let liveService: RegistryService | null = null
let liveRegistry: SessionRegistry | null = null
// True when the page says the window is visible. False with no page, so a closed window polls
// slowly (user decision, 2026-11-13).
let pageVisible = false

function setPageVisible(visible: boolean): void {
  pageVisible = visible
  liveService?.setPageVisible(pollVisible())
}

// The visibility that the session poll uses. A headless test window never shows, but it polls as
// a visible window (user decision, 2026-11-13).
function pollVisible(): boolean {
  return seenVisible(pageVisible, headless)
}

// True when the window has the focus. A headless test window counts as focused, as a shown window
// of a smoke test. So no alert notification starts in a smoke test.
function windowFocused(): boolean {
  return seenFocused(
    currentWindow !== null && !currentWindow.isDestroyed() && currentWindow.isFocused(),
    headless,
  )
}
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
// True in a headless test home (BIFROST_TEST_HEADLESS=1). registerIpc sets it.
let headless = false
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

// The modules state (Modules design 7). registerIpc opens the store. Until the store is open, the
// state has no module, so the module protocol serves no file.
let modulesStore: ModulesStateStore | null = null
// The Bifrost folder of the modules. registerIpc sets it.
let modulesHome: string | null = null
// The module jobs of the modules (plan Task 7). registerIpc makes them. stopRegistry stops them.
let moduleJobs: Jobs | null = null
// Discuss with Claude (plan Task 10). registerIpc makes it. The end of a page drops its open
// request.
let moduleDiscuss: Discuss | null = null
// The timer that sends the rows of the modules at local midnight, so the rows show the jobs of
// the new day. registerIpc starts it. stopRegistry stops it.
let stopModulesDay: (() => void) | null = null

// The newest modules state. index.ts gives it to the module protocol.
export function modulesState(): ModulesState {
  return modulesStore?.get() ?? { modules: {} }
}

// The rows of the modules for the page (plan Task 6). A packaged app treats a dev module as off.
function moduleRows(): ModulesSnapshot {
  return modulesSnapshot(modulesState(), {
    devAllowed: !app.isPackaged,
    home: homedir(),
    today: localDate(new Date()),
    waiting: id => moduleJobs?.waiting(id) ?? 0,
  })
}

// The registry forgot a session for good (a Delete, or gone from the counted lists). Its id
// leaves the saved sessions of Discuss with Claude (ruling P12), so the list stays small. A
// failed or empty poll never comes here, so a session that comes back stays hidden. Before the
// modules state opens, the id stays: it only hides a session that does not exist.
function forgetDiscussSession(sessionId: string): void {
  const store = modulesStore
  if (store === null || !(store.get().discussSessions ?? []).includes(sessionId)) return
  store
    .change(s => withoutDiscussSession(s, sessionId))
    .catch(err => {
      console.error('Bifrost cannot save the sessions of Discuss with Claude.', err)
    })
}

// Send the rows of the modules to the page. A failed send must not throw, for example while the
// window closes.
function sendModules(): void {
  try {
    send('modules:changed', moduleRows())
  } catch (err) {
    console.error('Bifrost cannot send the modules to the window.', err)
  }
}

// The code folder of a module: the approved copy, or the folder of a dev module. It is "" before
// registerIpc, and the protocol refuses a path that is not absolute.
export function moduleFilesDir(id: string): string {
  if (modulesHome === null) return ''
  const modules = modulesState().modules
  return moduleCodeRoot(modulesHome, id, Object.hasOwn(modules, id) ? modules[id] : undefined)
}

// The storage of the modules (Modules design 8.2). registerIpc makes it. stopRegistry writes its
// changes before the app quits.
let moduleDataStore: ModuleDataStore | null = null

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
// The Approve button of the To review tab (user decision, 2026-11-13). startReviews makes it. It
// has no timer, so stopRegistry has nothing to stop.
let reviewApprover: Approver | null = null
// The Review panel of the To review tab (user decision, 2026-11-13). startReviews makes it. It
// has no timer either.
let reviewDrafts: DraftEditor | null = null
// The most bytes of text that the page may write to the trust terminal in one call.
const MAX_TRUST_WRITE = 64 * 1024
const REFUSED_BAD_TERMINAL = 'refused: bad terminal value'
// A test home has no git identity, because GIT_CONFIG_GLOBAL is /dev/null. A fix commit needs one.
const TEST_GIT_IDENTITY = [
  '-c',
  'user.name=Bifrost Test',
  '-c',
  'user.email=bifrost-test@example.invalid',
]
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

// The Daily update (Daily update design). registerIpc starts it after the settings store opens. A
// tick checks the schedule at the start, every 30 seconds, and when the Mac wakes or unlocks.
// stopRegistry stops the ticks, the run and the probes. A click on a reminder while no page is
// loaded waits for the next page. PendingOpen keeps a text, so the empty text DAILY_NO_AREA means
// "no area".
const DAILY_TICK_MS = 30_000
const pendingDailyOpen = new PendingOpen()
const DAILY_NO_AREA = ''
const DAILY_FAILED = "Bifrost couldn't do that. Please try again."
let stopDaily: (() => void) | null = null

// The dictation service (dictation design). registerIpc makes it. It runs the speech helper and
// gives its events to the chat view that dictates. stopRegistry stops the helper.
let dictation: DictationService | null = null

const fetchJson = createFetchJson(mainFetch)

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

// Run a call only when the sender is the top frame of the page that the current window shows
// now. Another webContents must not read or change the integration of the user. A frame inside
// the page, for example a module frame, gets a refusal on each channel (main/page-guard.ts).
const fromPage = createFromPage<WebContents>(sender => isLivePage(sender, page.token()))

// The folder dialog of an install from a folder. null when the user closes it.
async function pickModuleFolder(): Promise<string | null> {
  const options: OpenDialogOptions = {
    buttonLabel: 'Choose',
    defaultPath: homedir(),
    message: 'Choose the folder of the module.',
    properties: ['openDirectory'],
  }
  const win = currentWindow && !currentWindow.isDestroyed() ? currentWindow : null
  const result = await (win ? dialog.showOpenDialog(win, options) : dialog.showOpenDialog(options))
  return result.canceled ? null : (result.filePaths[0] ?? null)
}

const reviewLog = (m: string): void => console.error(m)

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
        // Save fixFrom first. Then start the runner and the watcher, if Watch is still on.
        void (reviewRunner?.watchTurnedOn() ?? Promise.resolve())
          .catch(() => console.error('The round runner could not save the turn-on time.'))
          .finally(() => {
            if (!getSettings().reviewsWatch) return
            reviewRunner?.start()
            reviewsWatcher?.start()
          })
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
    case 'reviews-autofix':
      // The runner saves the new start time first. Then the rows show the new counts.
      void (reviewRunner?.autoFixChanged(effect.on) ?? Promise.resolve())
        .catch(() => console.error('The round runner could not apply the automatic setting.'))
        .finally(() => reviewsWatcher?.rebuild())
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
  if (!getSettings().notifications || windowFocused()) return
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

// A notification of a module (Modules design 8.2). It shows only when the Notifications setting is
// on. The title starts with the name of the module. A click shows the window.
function notifyForModule(notice: ModuleNotice): void {
  if (!getSettings().notifications) return
  showNotification(
    {
      body: notice.body,
      label: `the module ${notice.moduleId}`,
      sessionId: null,
      title: `${notice.moduleName}: ${notice.title}`,
    },
    () => showWindowFn?.(),
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

// The answers that the page sent: 1 to MAX_ANSWERS objects with exactly an id and a text. The id
// matches ITEM_ID. The text is MAX_ANSWER characters or less, or null.
function checkAnswers(value: unknown): { id: string; text: string | null }[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > MAX_ANSWERS) {
    throw new Error(REFUSED_BAD_ANSWER)
  }
  return value.map((item: unknown) => {
    if (typeof item !== 'object' || item === null || Array.isArray(item)) {
      throw new Error(REFUSED_BAD_ANSWER)
    }
    const keys = Object.keys(item)
    const { id, text } = item as { id?: unknown; text?: unknown }
    if (keys.length !== 2 || !keys.includes('id') || !keys.includes('text')) {
      throw new Error(REFUSED_BAD_ANSWER)
    }
    if (typeof id !== 'string' || !ITEM_ID.test(id)) throw new Error(REFUSED_BAD_ANSWER)
    if (text !== null && (typeof text !== 'string' || text.length > MAX_ANSWER)) {
      throw new Error(REFUSED_BAD_ANSWER)
    }
    return { id, text }
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
    approval: key => reviewApprover?.entry(key) ?? null,
    draft: key => reviewDrafts?.entry(key) ?? null,
    emit: snapshot => send('reviews:update', snapshot),
    gh,
    health,
    log: message => console.error(message),
    notify: notifyReviewRequest,
    now: () => Date.now(),
    reviews: {
      afterPoll: poll => reviewRunner?.afterPoll(poll),
      mine: key => reviewRunner?.mine(key) ?? IDLE_MINE,
      session: key => reviewRunner?.session(key) ?? null,
      sessionOf: key => reviewRunner?.sessionOf(key) ?? null,
      trust: () => reviewRunner?.trust() ?? [],
    },
    settings: () => settings.get(),
    store,
  })
  reviewsWatcher = watcher
  // The Approve button needs no session, so it works also with no registry service.
  reviewApprover = createApprover({
    changed: () => watcher.rebuild(),
    eventNotice: text => eventBatcher.push([eventLog.line(text, Date.now())]),
    gh,
    log: message => console.error(message),
    now: () => Date.now(),
    pollStartedAt: () => watcher.pollStartedAt(),
    requestPoll: () => watcher.requestPoll(),
    store,
    toReviewPr: key => watcher.toReviewPr(key),
    viewer: () => watcher.viewer(),
  })
  // The Review panel needs no session either.
  reviewDrafts = createDraftEditor({
    changed: () => watcher.rebuild(),
    eventNotice: text => eventBatcher.push([eventLog.line(text, Date.now())]),
    gh,
    log: message => console.error(message),
    now: () => Date.now(),
    pollStartedAt: () => watcher.pollStartedAt(),
    requestPoll: () => watcher.requestPoll(),
    store,
    toReviewPr: key => watcher.toReviewPr(key),
    viewer: () => watcher.viewer(),
  })
  if (service === null) {
    if (!serviceStopped && settings.get().reviewsWatch) watcher.start()
    return watcher
  }
  const claudeJson = claudeJsonFile(home?.home ?? homedir())
  const claudeSettings = claudeSettingsFile(home?.home ?? homedir())
  const repoGit = createRepoGit({
    env: async () => ({
      ...childEnv(await parts.loginEnv, { pty: false }),
      ...(home === null ? {} : { GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' }),
    }),
    exec: execFile,
    extraConfig: home === null ? [] : TEST_GIT_IDENTITY,
  })
  const repos = createRepoStore({
    bifrostHome,
    git: repoGit,
    remoteBase: remoteBase(home?.home ?? null),
  })
  // The push of a fix of a request round. It is the only git write to GitHub.
  const pusher = createFixPusher({ git: repoGit, remoteBase: remoteBase(home?.home ?? null) })
  // With signed commits on, the fix goes to GitHub with createCommitOnBranch, and GitHub signs it.
  const signedPusher = createSignedPusher({
    gh,
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
    claudeSettings,
    eventNotice: text => eventBatcher.push([eventLog.line(text, Date.now())]),
    gh,
    jobs: [createReviewJob(), createRequestJob({ pusher, signedPusher })],
    log: message => console.error(message),
    minePr: key => watcher.minePr(key),
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
    // Ruling S20: the row of the setting then shows that the automatic fixes are off.
    turnOffAutoFix: async () => {
      await settings.update({ reviewsAutoFix: false })
    },
    viewer: () => watcher.viewer(),
  })
  reviewRunner = runner
  service.onUpdate(rows => {
    try {
      runner.onRows(rows)
    } catch {
      console.error('The round runner failed on a session update.')
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

// What startDailyUpdate needs besides the settings: the runners of gh and claude, and the skills
// plugin folder of the review sessions.
interface DailyParts {
  gh: Gh
  run: Promise<RunClaude | null>
  spawnLines: Promise<SpawnLines | null>
  pluginDir: string
}

// Write the Daily update settings for the skill. The folder gets mode 700 before the write. A
// failure goes to the console only.
async function exportDailySettings(bifrostHome: string, settings: Settings): Promise<void> {
  try {
    await dailyFolder(bifrostHome)
    await writeSkillExport(skillExportFile(bifrostHome), settings.dailyUpdate)
  } catch (err) {
    console.error('Bifrost cannot write the Daily update settings for the skill.', err)
  }
}

// Show the window and open the Daily update panel at the area.
function openDailyPanel(areaId: string | null): void {
  showWindowFn?.()
  // With no loaded page, the open waits for the did-finish-load of the next page.
  if (pendingDailyOpen.click(areaId ?? DAILY_NO_AREA) !== null) send('daily-update:open', areaId)
}

// Open the day state and make the Daily update service. The state and the skill export go to
// bifrostHome, so a test home uses its own files. Write the skill export at the start and after
// each change of the Daily update settings. Then start the ticks.
async function startDailyUpdate(
  bifrostHome: string,
  settingsReady: Promise<SettingsStore>,
  parts: DailyParts,
): Promise<DailyUpdateService> {
  const settings = await settingsReady
  // The exports run one at a time, so an older export never writes over a newer one.
  let exports = exportDailySettings(bifrostHome, settings.get())
  await exports
  const store = await openDailyStateStore(dailyStateFile(bifrostHome))
  const service = createDailyUpdateService({
    bifrostHome,
    bounce: () => {
      app.dock?.bounce('informational')
    },
    eventNotice: text => eventBatcher.push([eventLog.line(text, Date.now())]),
    gh: parts.gh,
    log: message => console.error(message),
    notify: (text, sound, onClick) =>
      showNotification(
        { body: text, label: 'daily update', sessionId: null, sound, title: DAILY_TITLE },
        () => onClick(),
        logRefusedNotification,
      ),
    now: () => Date.now(),
    openExternal: url => shell.openExternal(url),
    openPanel: openDailyPanel,
    pluginDir: parts.pluginDir,
    runClaude: () => parts.run,
    settings: () => settings.get().dailyUpdate,
    spawnLines: () => parts.spawnLines,
    store,
    writeClipboard: text => clipboard.writeText(text),
  })
  service.onUpdate(snapshot => send('daily-update:update', snapshot))
  settings.onChange((next, prev) => {
    if (next.dailyUpdate === prev.dailyUpdate) return
    exports = exports.then(() => exportDailySettings(bifrostHome, settings.get()))
    send('daily-update:update', service.snapshot())
  })
  // The app can quit before the state opens. Then stop the service and do not start the ticks.
  if (serviceStopped) {
    service.stop()
    return service
  }
  const tick = (): void => {
    service.tick().catch(err => console.error('The Daily update tick failed.', err))
  }
  const timer = setInterval(tick, DAILY_TICK_MS)
  powerMonitor.on('resume', tick)
  powerMonitor.on('unlock-screen', tick)
  // A child of a quit app continues on macOS. So the stop also ends the run and the probes.
  stopDaily = () => {
    clearInterval(timer)
    powerMonitor.off('resume', tick)
    powerMonitor.off('unlock-screen', tick)
    service.stop()
  }
  tick()
  return service
}

// A call of the Daily update panel. A refusal of Bifrost passes on as it is. Each other error
// becomes a fixed text, so the page never gets a path.
async function dailyCall<T>(
  daily: Promise<DailyUpdateService>,
  fn: (service: DailyUpdateService) => Promise<T>,
): Promise<T> {
  try {
    return await fn(await daily)
  } catch (error) {
    if (error instanceof Error && error.message.startsWith('refused: ')) throw error
    console.error('A Daily update call failed.', error)
    throw new Error(DAILY_FAILED)
  }
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
    probe: url => probeUrl(mainFetch, url, () => performance.now()),
    ptys: () => liveManager?.list() ?? [],
    rateLimit: () => reviewsWatcher?.rateLimit() ?? null,
    rows: () => liveService?.rows() ?? [],
    thermal: thermalState,
  })
  perfMonitor = monitor
  monitor.start()
  // The page says if the window is visible. A window that is not visible polls more slowly.
  ipcMain.handle('window:visible', (e, value: unknown) =>
    fromPage(e, async () => setPageVisible(checkVisible(value))),
  )
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
// The branch read runs no git in the reviews folder of bifrostHome, where a PR session can write.
async function startService(
  run: Promise<RunClaude | null>,
  settingsReady: Promise<SettingsStore>,
  health: HealthLog,
  bifrostHome: string,
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
  // Read no HEAD file and run no git in the folders that a PR session can write.
  const branchReader = createBranchReader(execFile, { skipRoot: reposRoot(bifrostHome) })
  const deps: ServiceDeps = {
    health,
    listActive: () => list(false),
    listAll: () => list(true),
    now,
    readBranch: cwd => branchReader.read(cwd),
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
    focused: windowFocused,
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
  service.onForget(forgetDiscussSession)
  service.onUsage(usage => {
    send('usage:update', usage)
    usageAlerts?.session(usage)
  })
  service.onEvents(events => eventBatcher.push(eventLog.append(events)))
  liveRegistry = registry
  liveService = service
  service.setPageVisible(pollVisible())
  // The app can quit before the store loads. Then do not start the service.
  if (!serviceStopped) service.start()
  return service
}

// Register all IPC handlers one time for the app process.
// Call it before any window loads a page. A second call does nothing.
// The main process finds the claude path one time. The renderer cannot set it.
// With a test home (D12), Bifrost uses the paths of the test home, the first claude on the PATH
// and the env of the process. It does not read the env of a login shell. A test home records its
// notifications and shows none. hidden is true in a headless test home.
export function registerIpc(home: TestHome | null = null, hidden = false): void {
  if (registered) return
  registered = true
  testHome = home
  headless = hidden
  recordNotifications(home !== null)
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
      fetch: mainFetch,
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
  // The module jobs of the modules get their own runner, because only a job gets stdin, and a
  // timeout stops the whole process group of a job. It uses the same env as run.
  const jobRun = Promise.all([claudePath, loginEnv]).then(([path, env]) =>
    path ? createRunClaudeJob(path, env) : null,
  )
  // The claude plugin commands of Live details get their own run (D25). In a test home, they
  // get HOME and CLAUDE_CONFIG_DIR of the test home. So they change only files under the test
  // home. Each other claude call uses run, so the session list stays the real one.
  const pluginRun = Promise.all([claudePath, loginEnv]).then(([path, env]) =>
    path ? createRunClaude(execFile, path, pluginEnv(env, home)) : null,
  )
  // The probe of the MCP servers reads the stream of claude line by line. It uses the same env as
  // run.
  const spawnLines = Promise.all([claudePath, loginEnv]).then(([path, env]) =>
    path ? createSpawnLines(spawn, path, env) : null,
  )
  const getManager = (): Promise<PtyManager | null> => managerPromise as Promise<PtyManager | null>
  // A test home runs the fake helper of the smoke tests (helperToRun). An event goes only to a
  // chat view that has a terminal. So no event goes to a chat window that closed.
  const hasTerminal = (viewId: string): boolean => liveManager?.has(viewId) ?? false
  dictation = createDictationService({
    clearTimeout: timer => clearTimeout(timer),
    now: () => Date.now(),
    path: () => helperToRun(home !== null, process.env.PATH, defaultIsExecutable),
    send: chatEventSender(hasTerminal, send),
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    spawn: path =>
      spawn(path, [], {
        env: childEnv(process.env, { pty: false }),
        stdio: ['pipe', 'pipe', 'ignore'],
      }),
  })
  // All text and keys that Bifrost types into a session go through this object (D1).
  // A hidden attach opens at the current size of the session (M3).
  const input = new SessionInput({
    pty: getManager,
    readSize: readSessionSize,
    rows: () => liveService?.rows() ?? [],
  })
  managerPromise = Promise.all([claudePath, loginEnv]).then(([path, env]) => {
    if (!path) return null
    const m = new PtyManager(nodePtySpawn, path, env)
    // Chat output goes to the page in batches. Exit and close flush the batch first.
    const batcher = createOutputBatcher({ send: (viewId, data) => send('pty:data', viewId, data) })
    m.onData((viewId, chunk) => {
      input.data(viewId)
      // Only the main process uses the hidden send views. Their output stays here.
      if (CHAT_VIEW.test(viewId)) batcher.push(viewId, chunk)
      if (viewId === TRUST_VIEW) send('reviews:trust-data', chunk)
      // A full redraw follows a resize by any client (M0 question 1). So read the size.
      // A sequence split over two chunks is missed. The next redraw or the open recovers it.
      if (chunk.includes(FULL_REDRAW)) sizeWatcher.poke(viewId)
    })
    // close, closeAll and a replacing open do not run the exit callback. So forget here too.
    // The end of the terminal of a chat also stops its dictation.
    m.onClose(viewId => {
      batcher.flush(viewId)
      sizeWatcher.forget(viewId)
      input.ended(viewId)
      dictation?.stop(viewId)
    })
    m.onExit((viewId, exitCode, signal) => {
      batcher.flush(viewId)
      sizeWatcher.forget(viewId)
      input.ended(viewId)
      dictation?.stop(viewId)
      if (CHAT_VIEW.test(viewId)) send('pty:exit', viewId, exitCode, signal)
      if (viewId === TRUST_VIEW) trustWindow?.exited()
    })
    liveManager = m
    return m
  })
  const paths = defaultPaths(home?.home ?? homedir())
  modulesHome = paths.bifrostHome
  // The page gets the rows after the store opens, and again after each change of the state.
  const modulesReady = openModulesStateStore(modulesStateFile(paths.bifrostHome)).then(
    store => {
      modulesStore = store
      store.onChange(sendModules)
      sendModules()
    },
    err => console.error('Bifrost cannot open the modules state.', err),
  )
  stopModulesDay = watchLocalDay(sendModules, { log: message => console.error(message) })
  // A smoke test reads these paths and checks that each one is in the test home.
  recordTestPaths(home, {
    bifrostHome: paths.bifrostHome,
    claudeJson: claudeJsonFile(home?.home ?? homedir()),
    claudeSettings: paths.claudeSettings,
  })
  // The settings store opens one time. Each user gets the same store.
  const settings = openSettings(join(app.getPath('userData'), 'settings.json'), health)
  usageAlerts = startUsageAlerts(home, settings)
  const service = startService(run, settings, health, paths.bifrostHome)
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
  // The Daily update uses the same skills plugin folder as the review sessions.
  const daily = startDailyUpdate(paths.bifrostHome, settings, {
    gh,
    pluginDir: skillsSourceDir(app.getAppPath()),
    run,
    spawnLines,
  })
  daily.catch(err => console.error('Bifrost cannot start the Daily update.', err))
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
    fetch: home ? fileFetch(join(home.home, 'github-releases.json')) : mainFetch,
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

  ipcMain.handle('claude:version', e =>
    fromPage(e, async (): Promise<ClaudeVersion> => {
      const runClaude = await run
      if (!runClaude) return { minimum: MIN_CLAUDE_VERSION, ok: false, version: null }
      return checkClaudeVersion(runClaude)
    }),
  )
  ipcMain.handle('registry:rows', e => fromPage(e, async () => (await service).rows()))
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
  // View on GitHub in the Answer panel. The page sends a PR key and an item ID. The main process
  // finds the saved link and checks it.
  ipcMain.handle('reviews:open-comment', (e, key: unknown, itemId: unknown) =>
    fromPage(e, async () => shell.openExternal(commentUrlToOpen(await reviews, key, itemId))),
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
      const k = rowKey(whileOn(await reviews), key)
      const runner = reviewRunner
      if (runner === null) throw new Error(NO_RUNNER)
      await friendlyFailure(() => runner.cancel(k), REVIEW_FAILED, reviewLog)
    }),
  )
  ipcMain.handle('reviews:stop-session', (e, key: unknown) =>
    fromPage(e, async () => {
      const k = rowKey(whileOn(await reviews), key)
      const runner = reviewRunner
      if (runner === null) throw new Error(NO_RUNNER)
      await friendlyFailure(() => runner.stopSession(k), REVIEW_FAILED, reviewLog)
    }),
  )
  // The Approve button (user decision, 2026-11-13). The page sends only the PR key of a To review
  // row. Main finds all other values in its own state, and reads the PR from GitHub again before
  // the write. No other code path approves.
  ipcMain.handle('reviews:approve', (e, ...args: unknown[]) =>
    fromPage(e, async () => {
      const k = approveKey(whileOn(await reviews), args)
      const approver = reviewApprover
      if (approver === null) throw new Error(NO_RUNNER)
      await friendlyFailure(() => approver.approve(k), REVIEW_FAILED, reviewLog)
    }),
  )
  // The Review panel (user decision, 2026-11-13). The page sends the PR key of a To review row
  // that offers the panel, and Send review also sends the edits of the user. Main finds the IDs
  // of the review in its own state and in a fresh read of GitHub (ruling B10). Approve instead
  // deletes the draft, then approves through the approver, as the Approve button does.
  ipcMain.handle('reviews:draft', (e, ...args: unknown[]) =>
    fromPage(e, async () => {
      const k = draftKey(whileOn(await reviews), args, 1)
      const drafts = reviewDrafts
      if (drafts === null) throw new Error(NO_RUNNER)
      return await friendlyFailure(() => drafts.open(k), REVIEW_FAILED, reviewLog)
    }),
  )
  ipcMain.handle('reviews:draft-send', (e, ...args: unknown[]) =>
    fromPage(e, async () => {
      const k = draftKey(whileOn(await reviews), args, 2)
      const edits = checkDraftEdits(args[1])
      const drafts = reviewDrafts
      if (drafts === null) throw new Error(NO_RUNNER)
      return await friendlyFailure(() => drafts.send(k, edits), REVIEW_FAILED, reviewLog)
    }),
  )
  ipcMain.handle('reviews:draft-discard', (e, ...args: unknown[]) =>
    fromPage(e, async () => {
      const k = draftKey(whileOn(await reviews), args, 1)
      const drafts = reviewDrafts
      if (drafts === null) throw new Error(NO_RUNNER)
      return await friendlyFailure(() => drafts.discard(k), REVIEW_FAILED, reviewLog)
    }),
  )
  ipcMain.handle('reviews:draft-approve', (e, ...args: unknown[]) =>
    fromPage(e, async () => {
      const k = draftKey(whileOn(await reviews), args, 1)
      const drafts = reviewDrafts
      const approver = reviewApprover
      if (drafts === null || approver === null) throw new Error(NO_RUNNER)
      const step = { result: () => approver.entry(k), run: () => approver.approve(k) }
      return await friendlyFailure(() => drafts.approveInstead(k, step), REVIEW_FAILED, reviewLog)
    }),
  )
  // Remove of an approved-by-others row (ruling B3). The page sends only the PR key. Bifrost hides
  // the PR in its own state. Nothing goes to GitHub.
  ipcMain.handle('reviews:remove', (e, ...args: unknown[]) =>
    fromPage(e, async () => {
      const k = removeKey(whileOn(await reviews), args)
      const watcher = await reviews
      await friendlyFailure(() => watcher.remove(k), REVIEW_FAILED, reviewLog)
    }),
  )
  // The request rounds. The page sends the key of a My PRs row, a fixed word, or answers. Each
  // answer has an item ID and a text or null.
  ipcMain.handle('reviews:handle', (e, key: unknown, what: unknown) =>
    fromPage(e, async () => {
      const k = mineKey(whileOn(await reviews), key)
      if (what !== 'all' && what !== 'copilot') throw new Error(REFUSED_NOT_HANDLEABLE)
      const runner = reviewRunner
      if (runner === null) throw new Error(NO_RUNNER)
      await friendlyFailure(() => runner.handle(k, what), REVIEW_FAILED, reviewLog)
    }),
  )
  ipcMain.handle('reviews:retry', (e, key: unknown) =>
    fromPage(e, async () => {
      const k = mineKey(whileOn(await reviews), key)
      const runner = reviewRunner
      if (runner === null) throw new Error(NO_RUNNER)
      await friendlyFailure(() => runner.retry(k), REVIEW_FAILED, reviewLog)
    }),
  )
  ipcMain.handle('reviews:answer', (e, key: unknown, answers: unknown) =>
    fromPage(e, async () => {
      const k = mineKey(whileOn(await reviews), key)
      const checked = checkAnswers(answers)
      const runner = reviewRunner
      if (runner === null) throw new Error(NO_RUNNER)
      await friendlyFailure(() => runner.answer(k, checked), REVIEW_FAILED, reviewLog)
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
  // The Daily update panel. The page sends area IDs, item IDs, the text of a draft, a boolean or
  // a trigger. It never sends a path, a URL or a command. Open item opens only an https link of
  // the state.
  ipcMain.handle('daily-update:snapshot', e =>
    fromPage(e, () => dailyCall(daily, async s => s.snapshot())),
  )
  ipcMain.handle('daily-update:refresh', (e, trigger: unknown) =>
    fromPage(e, () => dailyCall(daily, s => s.refresh(checkPageTrigger(trigger)))),
  )
  ipcMain.handle('daily-update:redo', (e, areaId: unknown) =>
    fromPage(e, () => dailyCall(daily, s => s.redo(checkId(areaId)))),
  )
  ipcMain.handle('daily-update:edit-draft', (e, areaId: unknown, text: unknown) =>
    fromPage(e, () => dailyCall(daily, s => s.editDraft(checkId(areaId), checkDraftText(text)))),
  )
  const dailyAreaHandler = (
    channel: string,
    fn: (s: DailyUpdateService, areaId: string) => Promise<void>,
  ): void => {
    ipcMain.handle(channel, (e, areaId: unknown) =>
      fromPage(e, () => dailyCall(daily, s => fn(s, checkId(areaId)))),
    )
  }
  dailyAreaHandler('daily-update:use-pending', (s, id) => s.usePending(id))
  dailyAreaHandler('daily-update:keep-mine', (s, id) => s.keepMine(id))
  dailyAreaHandler('daily-update:mark-sent', (s, id) => s.markSent(id))
  dailyAreaHandler('daily-update:undo-sent', (s, id) => s.undoSent(id))
  dailyAreaHandler('daily-update:copy', (s, id) => s.copy(id))
  ipcMain.handle('daily-update:set-skipped', (e, skipped: unknown) =>
    fromPage(e, () => dailyCall(daily, s => s.setSkipped(checkBoolean(skipped)))),
  )
  ipcMain.handle('daily-update:open-item', (e, areaId: unknown, itemId: unknown) =>
    fromPage(e, () => dailyCall(daily, s => s.openItem(checkId(areaId), checkId(itemId)))),
  )
  // The service gives a friendly text with no path for each failure of the inventory.
  ipcMain.handle('daily-update:inventory', e =>
    fromPage(e, async () => (await dailyCall(daily, async s => s)).inventory()),
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
      await openUpdateLog(updateLogPath(app.getPath('logs')), {
        ensureFile: async path => {
          await mkdir(dirname(path), { recursive: true })
          await appendFile(path, '')
        },
        exists: path =>
          access(path).then(
            () => true,
            () => false,
          ),
        openPath: path => shell.openPath(path),
        showItemInFolder: path => shell.showItemInFolder(path),
        updaterRuns: updateLog !== null,
      })
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
    // A hand-over of a session that Discuss started gives a session that modules also cannot see.
    carryOver: (from, to) => {
      liveService?.carryOver(from, to)
      moduleDiscuss?.carryOver(from, to)
    },
    checkWorktree: worktree => checkWorktreeHead(worktree, execFile),
    defer: entry => liveService?.defer(entry),
    deferredIn: worktree => liveService?.deferredIn(worktree) ?? [],
    dirInfo: dir => dirInfo(execFile, stat, dir),
    dropDeferred: id => liveService?.dropDeferred(id),
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
    undefer: id => liveService?.undefer(id),
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
  // The storage of the modules. stopRegistry writes its changes at the quit. Settings > Modules
  // (the module service) calls flush when the user turns a module off or updates it, and drop
  // before it deletes the data file of a removed module.
  const moduleData = createModuleDataStore(paths.bifrostHome)
  moduleDataStore = moduleData
  // Heimdall's call check (Modules design 8). The bridge of a module frame sends each call with
  // the module id of the frame. Heimdall checks the module, the caps and the permission, and
  // filters each answer. The storage of each module goes to modules-data in the Bifrost folder.
  // The module jobs (plan Task 7) run claude with no tools, no skills and no saved session, each
  // in the empty fixed job folder of its module in the system temp folder (ruling S-A10). That
  // path holds no user name. A test home keeps the job folders in the test home.
  // The rows show the count of the jobs that wait for Refresh. Heimdall sends the refresh event,
  // so the event passes its checks and its filter.
  const jobs = createJobs({
    changed: sendModules,
    devAllowed: !app.isPackaged,
    emit: (moduleId, name, data) => heimdall.event(moduleId, name, data),
    jobsRoot: moduleJobsRoot(home ? home.home : app.getPath('temp')),
    log: message => console.error(message),
    now: () => Date.now(),
    runner: () => jobRun,
    store: {
      change: async fn => {
        await modulesReady
        if (modulesStore === null) throw new Error('Bifrost cannot open the modules state.')
        return modulesStore.change(fn)
      },
      get: modulesState,
    },
  })
  moduleJobs = jobs
  // A change of the modules state for Discuss with Claude. A failure goes to the log only.
  const saveModules = (fn: (s: ModulesState) => ModulesState): void => {
    modulesReady
      .then(() => {
        if (modulesStore === null) throw new Error('Bifrost cannot open the modules state.')
        return modulesStore.change(fn)
      })
      .catch(err => console.error('Bifrost cannot save the sessions of Discuss with Claude.', err))
  }
  // Discuss with Claude (plan Task 10). A module can only ask, and Heimdall's panel shows the
  // request. Only the main process copies a card. A session starts through the New session path
  // with the prompt of the user, never in a folder that a module can write or that the module
  // jobs use. A test home also blocks the job folders in the system temp folder.
  const discuss = createDiscuss({
    blockedFolders: [
      join(paths.bifrostHome, 'modules'),
      join(paths.bifrostHome, 'modules-data'),
      moduleJobsRoot(home ? home.home : app.getPath('temp')),
      moduleJobsRoot(app.getPath('temp')),
    ],
    carrySession: (from, to) => saveModules(s => carriedDiscussSession(s, from, to)),
    createSession: spec => sessions.create(spec),
    moduleName: id => {
      const entry = activeModule(modulesState(), id, !app.isPackaged)
      return entry?.granted.includes('discuss') ? entry.manifest.name : null
    },
    now: () => performance.now(),
    open: view => send('modules:discuss', view),
    realpath: path => realpath(path),
    requestId: () => randomUUID(),
    // The saved ids hide the sessions from every module after a restart too (ruling P12).
    saveSession: id => saveModules(s => withDiscussSession(s, id)),
    // The folder check compares the device and the inode, so a firmlink form cannot get past it.
    stat: async path => {
      const info = await stat(path, { bigint: true })
      return { dev: info.dev, ino: info.ino }
    },
    writeClipboard: text => clipboard.writeText(text),
  })
  moduleDiscuss = discuss
  const heimdall = createHeimdall({
    devAllowed: !app.isPackaged,
    discuss,
    emit: (moduleId, name, data) => send('modules:event', moduleId, name, data),
    jobs,
    notify: notifyForModule,
    now: () => Date.now(),
    serviceStatus: () => serviceList(serviceMonitor),
    sessions: {
      pr: row => prs.lookup(row.cwd, row.branch),
      rows: () => liveService?.rows() ?? [],
    },
    state: modulesState,
    store: moduleData,
    usage: async () => ({
      account: accountUsage?.current() ?? null,
      snapshot: (await service).usage(),
    }),
  })
  // Only the top frame of the Bifrost page sends a module call. fromPage checks the frame.
  const moduleCall = async (moduleId: unknown, name: unknown, args: unknown): Promise<unknown> => {
    if (typeof moduleId !== 'string' || typeof name !== 'string') {
      throw new Error(REFUSED_BAD_MODULE_INPUT)
    }
    return heimdall.call(moduleId, name, args)
  }
  ipcMain.handle('modules:call', (e, moduleId: unknown, name: unknown, args: unknown) =>
    fromPage(e, () => moduleCall(moduleId, name, args)),
  )
  // A click on Refresh in the title bar of a module panel. Only Bifrost's own title bar sends it,
  // never a module frame. The waiting jobs of the module run, and the module gets the refresh
  // event.
  ipcMain.handle('modules:refresh', (e, moduleId: unknown) =>
    fromPage(e, async () => {
      if (typeof moduleId !== 'string') throw new Error(REFUSED_BAD_MODULE_INPUT)
      moduleJobs?.refresh(moduleId)
    }),
  )
  // Start, Copy and Cancel of Discuss with Claude come only from Heimdall's panel, which is
  // Bifrost's own UI. The page sends the request id, the prompt and the folder only.
  ipcMain.handle('modules:discuss-start', (e, requestId: unknown, input: unknown) =>
    fromPage(e, () => discuss.start(requestId, input)),
  )
  ipcMain.handle('modules:discuss-copy', (e, requestId: unknown, cardIndex: unknown) =>
    fromPage(e, () => discuss.copy(requestId, cardIndex)),
  )
  ipcMain.handle('modules:discuss-cancel', (e, requestId: unknown) =>
    fromPage(e, async () => discuss.cancel(requestId)),
  )
  // The rows of the modules. The answer waits until the state opens, so a module panel of a saved
  // layout does not show the notice for a module that is on.
  ipcMain.handle('modules:snapshot', e =>
    fromPage(e, async () => {
      await modulesReady
      return moduleRows()
    }),
  )
  // The install, the update and the removal of modules (plan Task 9). A git install clones only
  // a GitHub repository, through the gh login of the user and with no prompt. A test home reads
  // no git config of the user, and clones from its local remotes.
  const modulesGit = createRepoGit({
    env: async () => ({
      ...childEnv(await loginEnv, { pty: false }),
      ...(home === null ? {} : { GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' }),
    }),
    exec: execFile,
    extraConfig: home === null ? [] : TEST_GIT_IDENTITY,
  })
  const moduleService = createModuleService({
    bifrostHome: paths.bifrostHome,
    bifrostVersion: app.getVersion(),
    data: moduleData,
    devAllowed: !app.isPackaged,
    git: modulesGit,
    jobs: { cancel: id => jobs.cancel(id) },
    log: message => console.error(message),
    pickFolder: pickModuleFolder,
    remoteBase: remoteBase(home?.home ?? null),
    store: {
      change: async fn => {
        await modulesReady
        if (modulesStore === null) throw new Error('Bifrost cannot open the modules state.')
        return modulesStore.change(fn)
      },
      get: modulesState,
    },
  })
  // Remove the old temporary clones and copies after the state opens.
  void modulesReady
    .then(() => moduleService.cleanup())
    .catch(err => {
      console.error('Bifrost cannot clean the modules folder.', err)
    })
  ipcMain.handle('modules:install-folder', e => fromPage(e, () => moduleService.installFolder()))
  ipcMain.handle('modules:install-git', (e, url: unknown) =>
    fromPage(e, () => moduleService.installGit(url)),
  )
  ipcMain.handle('modules:install-dev', e => fromPage(e, () => moduleService.installDev()))
  ipcMain.handle('modules:check-updates', e => fromPage(e, () => moduleService.checkUpdates()))
  ipcMain.handle('modules:review-update', (e, id: unknown) =>
    fromPage(e, () => moduleService.reviewUpdate(id)),
  )
  // Allow and Cancel come only from Heimdall's panel, which is Bifrost's own UI.
  ipcMain.handle('modules:approve', (e, requestId: unknown) =>
    fromPage(e, () => moduleService.allow(requestId)),
  )
  ipcMain.handle('modules:decline', (e, requestId: unknown) =>
    fromPage(e, () => moduleService.decline(requestId)),
  )
  ipcMain.handle('modules:set-enabled', (e, id: unknown, on: unknown) =>
    fromPage(e, () => moduleService.setEnabled(id, on)),
  )
  ipcMain.handle('modules:revoke', (e, id: unknown, permission: unknown) =>
    fromPage(e, () => moduleService.revoke(id, permission)),
  )
  ipcMain.handle('modules:grant', (e, id: unknown, permission: unknown) =>
    fromPage(e, () => moduleService.grant(id, permission)),
  )
  ipcMain.handle('modules:set-model', (e, id: unknown, model: unknown) =>
    fromPage(e, () => moduleService.setModel(id, model)),
  )
  ipcMain.handle('modules:set-cap', (e, id: unknown, cap: unknown) =>
    fromPage(e, () => moduleService.setCap(id, cap)),
  )
  ipcMain.handle('modules:remove', (e, id: unknown) => fromPage(e, () => moduleService.remove(id)))
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
    (e, viewId: unknown, args: string[], opts: { cols: number; rows: number }) =>
      fromPage(e, async () => {
        if (!isChatView(viewId)) throw new Error(REFUSED_NOT_CHAT)
        if (!isTerminalSize(opts?.cols) || !isTerminalSize(opts?.rows)) {
          throw new Error(REFUSED_BAD_SIZE)
        }
        const { cols, rows } = opts
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
        // The folder comes from the row of the session, never from the page.
        const pid = manager.open(viewId, args, {
          cols,
          cwd: resolve(process.cwd(), again.cwd),
          rows,
        })
        input.opened(viewId, args[1])
        sizeWatcher.poke(viewId)
        return pid
      }),
  )
  ipcMain.handle('pty:write', (e, viewId: unknown, data: unknown) =>
    fromPage(e, async () => {
      if (!isChatView(viewId) || typeof data !== 'string') return false
      // The left arrow key can open the agent view. A send to this view then waits (spec 8.5).
      if (hasLeftKey(data)) input.leftKey(viewId)
      const manager = await getManager()
      return manager ? manager.write(viewId, data) : false
    }),
  )
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
  ipcMain.handle('pty:resize', (e, viewId: unknown, cols: unknown, rows: unknown) =>
    fromPage(e, async () => {
      if (!isChatView(viewId) || !isTerminalSize(cols) || !isTerminalSize(rows)) return
      ;(await getManager())?.resize(viewId, cols, rows)
    }),
  )
  ipcMain.handle('pty:close', (e, viewId: unknown, signal?: string) =>
    fromPage(e, async () => {
      if (!isChatView(viewId)) return
      sizeWatcher.forget(viewId)
      input.ended(viewId)
      ;(await getManager())?.close(viewId, signal)
    }),
  )
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
  // Dictation (dictation design): warm, start, stop and the System Settings panes of a notice
  // (main/dictation/dictation-ipc.ts).
  // The vim mode check reads ~/.claude.json and ~/.claude/settings.json of the home. A test home
  // uses its own files. It parses a file again only after a change.
  const claudeHome = home?.home ?? homedir()
  const vimFiles = [claudeJsonFile(claudeHome), claudeSettingsFile(claudeHome)]
  const vimMode = createVimModeCheck(vimFiles, { read: readClaudeJson, stat: fileStamp })
  registerDictationIpc({
    fromPage,
    handle: (channel, listener) => ipcMain.handle(channel, listener),
    hasTerminal,
    openExternal: url => shell.openExternal(url),
    service: () => dictation,
    vimMode: () => vimMode(),
  })
  // The size of the session TTY. The row must be owned and have a PID. Bifrost only reads it.
  ipcMain.handle('pty:session-size', (e, sessionId: unknown) =>
    fromPage(e, async () => {
      if (typeof sessionId !== 'string') return null
      await service
      const pid = pidOfSession(sessionId)
      return pid === undefined ? null : readSessionSize(pid)
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
    if (currentWindow === win) {
      unloadPendingOpens()
      setPageVisible(false)
    }
    if (details.reason !== 'clean-exit') healthLog?.crash('window', details.reason)
    endPage()
  })
  win.on('closed', () => {
    if (currentWindow === win) {
      currentWindow = null
      unloadPendingOpens()
      setPageVisible(false)
    }
    endPage()
  })
  // A notification click while no page is loaded waits for the next load (D13).
  win.webContents.on('did-start-loading', () => {
    if (currentWindow === win) {
      unloadPendingOpens()
      // The new page says its visibility when it loads.
      setPageVisible(false)
    }
  })
  win.webContents.on('did-finish-load', () => {
    if (currentWindow !== win) return
    const sessionId = pendingOpen.load()
    if (sessionId !== null) send('alerts:open', sessionId)
    if (pendingReviewsOpen.load() !== null) send('reviews:open')
    if (pendingUsageOpen.load() !== null) send('usage:open')
    const areaId = pendingDailyOpen.load()
    if (areaId !== null) send('daily-update:open', areaId === DAILY_NO_AREA ? null : areaId)
  })
}

// The page ended. Close its PTYs. The Performance monitor then stops its fast checks, because
// no panel shows until the next page reports (design section 7).
function endPage(): void {
  page.end()
  perfMonitor?.pageGone()
  moduleDiscuss?.clear()
}

// No page is loaded now. A notification click waits for the next page.
function unloadPendingOpens(): void {
  pendingOpen.unload()
  pendingReviewsOpen.unload()
  pendingUsageOpen.unload()
  pendingDailyOpen.unload()
}

// Close all PTYs. Call it when the app quits.
export function closeAllPtys(): void {
  endPage()
}

// Stop the registry service, the server of Live details, the pollers, the updater, the Performance
// monitor and its delay histogram, the Daily update, the module jobs of the modules and their
// midnight timer, and the speech helper. Call it when the app quits.
export function stopRegistry(): void {
  serviceStopped = true
  stopDaily?.()
  stopDaily = null
  dictation?.stopAll()
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
  moduleJobs?.stop()
  stopModulesDay?.()
  stopModulesDay = null
  moduleDataStore?.flushSync()
}
