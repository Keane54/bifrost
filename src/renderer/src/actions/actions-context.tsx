// Run the actions of a session and the actions that need no row (spec 9.1, 9.2).
// It also gives the context that the action model needs.
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import { isPriority } from '../../../shared/priority'
import type { Settings } from '../../../shared/settings'
import type { ProjectApp, ProjectAppId, SeenCounts, SessionRow } from '../../../shared/types'
import { DEFAULT_WATCH_COLOUR, isWatchColour } from '../../../shared/watch'
import { useChats } from '../chat/chat-terminals'
import { chatPanelId } from '../chat/views'
import { useRegistry } from '../data/registry'
import { errorMessage } from '../lib/error-message'
import { rememberSlash } from '../sessions/history'
import { useHistory } from '../sessions/history-context'
import NewSessionDialog from '../sessions/NewSessionDialog'
import { useSettings } from '../settings/settings-context'
import { useWmControls, useWmState } from '../wm/context'
import { frameOf, type WmState } from '../wm/state'
import {
  type ActionContext,
  type ActionId,
  type GlobalActionId,
  type GlobalContext,
  globalActionState,
  type LabelSet,
  type MenuArg,
} from './action-model'
import { useConfirm } from './ConfirmDialog'
import { confirmFor } from './confirm'
import { createDeleteNotices } from './delete-notice'
import { friendlyError } from './errors'
import RenameDialog from './RenameDialog'
import { type FocusRequest, notifiedOpenStep, planRun, type RunPlan } from './run-plan'

// A notice of an action shows for 5 seconds. An error stays until the user closes it, because a
// Delete error can be long (Task 17).
const MESSAGE_MS = 5000

// A rename command does not go into the recent slash commands.
// A click on it in the submenu would give its name to another session.
const RENAME_COMMAND = /^\/rename(?:\s|$)/

// The notice while the unmerged-work check of a Delete runs (Task 13).
const CHECKING_NOTICE = 'Checking for unmerged work...'
// The notice while a Delete runs after the confirm. claude rm can take some minutes (Task 17).
const DELETING_NOTICE = 'Deleting the session...'
// The notice when a confirmation cannot open, because another dialog is open.
const DIALOG_BUSY_NOTICE = 'Another dialog is open. Finish that one first.'

export interface ActionsValue {
  // The apps of "Open project". The list follows the Terminal app setting.
  apps: ProjectApp[]
  run(id: ActionId, sessionId: string, arg?: MenuArg): void
  runGlobal(id: GlobalActionId): void
  // Type the text into the session. The promise rejects with the message of the failure.
  send(sessionId: string, text: string): Promise<void>
  contextFor(sessionId: string): ActionContext
  globalContext(): GlobalContext
  // The message of the last failed action, or null. It is the text for the user. It stays until
  // closeError or the next error.
  error: string | null
  // Remove the error.
  closeError(): void
  // A message for the user after an action, or null.
  notice: string | null
  // The New session dialog is open.
  newSessionOpen: boolean
  // The send box of this session takes the focus.
  focusRequest: FocusRequest | null
  // A send box used the request with this number. The request goes away.
  clearFocusRequest(n: number): void
}

type CallPlan = Extract<RunPlan, { kind: 'call' }>

const ActionsContext = createContext<ActionsValue | null>(null)

function contextOf(
  sessionId: string,
  state: WmState,
  apps: ProjectApp[],
  running: boolean,
  slashRecent: string[],
  settings: Settings,
): ActionContext {
  return {
    apps,
    chatOpen: frameOf(state, chatPanelId(sessionId)) !== undefined,
    labels: settings.labels,
    running,
    slashFavourites: settings.slashCommands,
    slashRecent,
  }
}

function globalOf(rows: SessionRow[], resumeAllRunning: boolean, labels: LabelSet): GlobalContext {
  return {
    labels,
    resumable: rows.filter(r => r.resumable).length,
    resumeAllRunning,
  }
}

function isAppId(arg: MenuArg | undefined, apps: ProjectApp[]): arg is ProjectAppId {
  return typeof arg === 'string' && apps.some(app => app.id === arg)
}

function resumedNotice(n: number): string {
  return n === 1 ? 'Resumed 1 session.' : `Resumed ${n} sessions.`
}

interface TimedMessage {
  text: string | null
  // Show the text. A new text replaces the last one. The result identifies this text for hide.
  show(text: string, opts?: { untilHidden?: boolean }): number
  // Remove the text, if it is still the text that show gave the number for.
  hide(id: number): void
  // Remove the text that shows now.
  clear(): void
}

// A message that shows for MESSAGE_MS, or until hide when untilHidden is true.
// A new message replaces the last one and shows for the full time.
function useTimedMessage(): TimedMessage {
  const [text, setText] = useState<string | null>(null)
  const timer = useRef<number | undefined>(undefined)
  const shownId = useRef(0)
  useEffect(() => () => window.clearTimeout(timer.current), [])
  const show = useCallback((next: string, opts: { untilHidden?: boolean } = {}) => {
    window.clearTimeout(timer.current)
    timer.current = undefined
    shownId.current += 1
    const id = shownId.current
    setText(next)
    if (opts.untilHidden !== true) {
      timer.current = window.setTimeout(() => {
        if (shownId.current === id) setText(null)
      }, MESSAGE_MS)
    }
    return id
  }, [])
  const hide = useCallback((id: number) => {
    if (shownId.current !== id) return
    window.clearTimeout(timer.current)
    timer.current = undefined
    setText(null)
  }, [])
  const clear = useCallback(() => hide(shownId.current), [hide])
  return useMemo(() => ({ clear, hide, show, text }), [clear, hide, show, text])
}

// It must be inside the providers of the registry, the window manager, the history, the
// confirmation dialog and the chat terminals.
export function ActionsProvider({ children }: { children: React.ReactNode }): React.JSX.Element {
  const state = useWmState()
  const { dispatch } = useWmControls()
  const { loaded, rows, select, selectedId } = useRegistry()
  const { history, update: updateHistory } = useHistory()
  const confirm = useConfirm()
  const chats = useChats()
  const { settings } = useSettings()
  const [apps, setApps] = useState<ProjectApp[]>([])
  const errorLine = useTimedMessage()
  const noticeLine = useTimedMessage()
  const error = errorLine.text
  const notice = noticeLine.text
  const showErrorLine = errorLine.show
  const closeError = errorLine.clear
  // show and hide of useTimedMessage do not change. So the first render gives the notices.
  // While a Delete runs, its notice stays. Another notice shows after the Delete (M5).
  const [notices] = useState(() =>
    createDeleteNotices({ hide: noticeLine.hide, show: noticeLine.show }, DELETING_NOTICE),
  )
  const showError = useCallback(
    (text: string) => showErrorLine(text, { untilHidden: true }),
    [showErrorLine],
  )
  // The session IDs with a call that did not end. The ref has the value at once.
  const [running, setRunning] = useState<ReadonlySet<string>>(() => new Set())
  const runningRef = useRef<ReadonlySet<string>>(running)
  const [resumeAllRunning, setResumeAllRunning] = useState(false)
  const resumeAllRef = useRef(false)
  const [focusRequest, setFocusRequest] = useState<FocusRequest | null>(null)
  const focusCount = useRef(0)
  const [renameFor, setRenameFor] = useState<string | null>(null)
  const [newSessionOpen, setNewSessionOpen] = useState(false)
  // run reads the data of the last render from this ref. So it checks the current row.
  const latest = useRef({ apps, history, loaded, rows, selectedId, settings, state })

  useLayoutEffect(() => {
    latest.current = { apps, history, loaded, rows, selectedId, settings, state }
  }, [apps, history, loaded, rows, selectedId, settings, state])

  // One call at mount, and one more when the Terminal app setting changes. The main process
  // builds the list with that setting. The list stays empty until the first call resolves.
  // biome-ignore lint/correctness/useExhaustiveDependencies: the list of apps follows the Terminal app setting.
  useEffect(() => {
    let active = true
    window.bifrost.actions.apps().then(
      list => {
        if (active) setApps(list)
      },
      err => console.error('Bifrost cannot get the list of apps.', err),
    )
    return () => {
      active = false
    }
  }, [settings.terminalApp])

  const fail = useCallback(
    (err: unknown) => showError(friendlyError(errorMessage(err))),
    [showError],
  )

  const setRunningFor = useCallback((sessionId: string, on: boolean) => {
    const next = new Set(runningRef.current)
    if (on) next.add(sessionId)
    else next.delete(sessionId)
    runningRef.current = next
    setRunning(next)
  }, [])

  // A confirmation could not open, because another dialog is open. The action does not run.
  const onBusy = useCallback(() => {
    notices.notify(DIALOG_BUSY_NOTICE)
  }, [notices])

  // Close the Rename dialog only when it is still the dialog of this session. A send of an old
  // dialog can end after the user opened Rename for another session.
  const closeRename = useCallback((sessionId: string) => {
    setRenameFor(cur => (cur === sessionId ? null : cur))
  }, [])

  const closeNewSession = useCallback(() => setNewSessionOpen(false), [])

  const clearFocusRequest = useCallback((n: number) => {
    setFocusRequest(cur => (cur?.n === n ? null : cur))
  }, [])

  const send = useCallback(
    async (sessionId: string, text: string): Promise<void> => {
      await window.bifrost.input.send(sessionId, text)
      // rememberSlash keeps only a slash command. Other text gives the same history.
      if (!RENAME_COMMAND.test(text.trim())) updateHistory(h => rememberSlash(h, text))
    },
    [updateHistory],
  )

  // Run one API call. Take control and Delete pass true only after the confirm click.
  const runCall = useCallback(
    async (plan: CallPlan, row: SessionRow, arg: MenuArg | undefined): Promise<void> => {
      const api = window.bifrost
      const sessionId = row.sessionId
      // True only after a click on the confirm button of the dialog.
      let confirmed = false
      let marked = false
      // The counts and the worktree of the check that the Delete dialog showed. null when the
      // check failed or found no worktree. Then the main process never discards a worktree that claude rm keeps.
      let seen: SeenCounts | null = null
      // True while the Delete runs after the confirm.
      let deleting = false
      try {
        if (plan.call === 'remove') {
          // Delete runs the unmerged-work check first (Task 13). A failed check gives null.
          setRunningFor(sessionId, true)
          marked = true
          // The page is not modal during the check. The notice tells the user that it runs.
          const checking = notices.showUntilHidden(CHECKING_NOTICE)
          const check = await api.sessions.deleteCheck(sessionId).catch(() => null)
          notices.hide(checking)
          if (check !== null && check.worktree !== null) {
            // The main process refuses the Delete when the row has another worktree now.
            seen = {
              changedFiles: check.changedFiles,
              unmergedCommits: check.unmergedCommits,
              worktree: check.worktree,
            }
          }
          const now = latest.current.rows.find(r => r.sessionId === sessionId) ?? row
          const text = confirmFor('delete', now, latest.current.settings.labels, check)
          if (text === null) return
          confirmed = await confirm(text, {
            onBusy,
            // The main process finds the folder from the row. The page sends no path.
            onOpenFolder: () => {
              api.sessions.openWorktree(sessionId).catch(fail)
            },
          })
          if (!confirmed) return
        } else if (plan.confirm !== null) {
          confirmed = await confirm(plan.confirm, { onBusy })
          if (!confirmed) return
        }
        if (!marked) {
          setRunningFor(sessionId, true)
          marked = true
        }
        let resultId = sessionId
        switch (plan.call) {
          case 'interrupt':
            await api.input.interrupt(sessionId)
            break
          case 'stop':
            await api.sessions.stop(sessionId)
            break
          case 'remove':
            if (!confirmed) return
            notices.startDelete()
            deleting = true
            await api.sessions.remove(sessionId, true, seen)
            break
          case 'resume':
            await api.sessions.resume(sessionId)
            break
          case 'take-control': {
            if (!confirmed) return
            resultId = (await api.sessions.takeControl(sessionId, true)).sessionId
            break
          }
          case 'open-in-terminal': {
            const result = await api.actions.openInTerminal(sessionId)
            if (result.notice !== null) notices.notify(result.notice)
            break
          }
          case 'set-priority':
            if (arg === null || isPriority(arg)) await api.registry.setPriority(sessionId, arg)
            break
          case 'watch-add':
            // A call without a colour choice, for example the button, uses the default colour.
            await api.registry.watch.add(sessionId, isWatchColour(arg) ? arg : DEFAULT_WATCH_COLOUR)
            break
          case 'watch-colour':
            if (isWatchColour(arg)) await api.registry.watch.colour(sessionId, arg)
            break
          case 'watch-remove':
            await api.registry.watch.remove(sessionId)
            break
          case 'copy-id':
            await api.actions.copySessionId(sessionId)
            break
          case 'open-project':
            if (isAppId(arg, latest.current.apps)) await api.actions.openProject(sessionId, arg)
            break
        }
        switch (plan.after) {
          case 'open-chat':
            select(resultId)
            dispatch({ panelId: chatPanelId(resultId), type: 'open' })
            break
          case 'close-chat':
            dispatch({ panelId: chatPanelId(sessionId), type: 'close' })
            if (latest.current.selectedId === sessionId) select(null)
            break
          case 'restart-chat':
            chats.get(sessionId)?.restart()
            break
          case 'none':
            break
        }
      } catch (err) {
        fail(err)
      } finally {
        if (deleting) notices.endDelete()
        if (marked) setRunningFor(sessionId, false)
      }
    },
    [chats, confirm, dispatch, fail, notices, onBusy, select, setRunningFor],
  )

  const run = useCallback(
    (id: ActionId, sessionId: string, arg?: MenuArg) => {
      const now = latest.current
      const row = now.rows.find(r => r.sessionId === sessionId)
      const ctx = contextOf(
        sessionId,
        now.state,
        now.apps,
        runningRef.current.has(sessionId),
        now.history.recentSlash,
        now.settings,
      )
      // A disabled action gives none. The row can change after the menu opens.
      const plan = planRun(id, row, ctx, arg)
      switch (plan.kind) {
        case 'none':
          break
        // The window manager focuses an open chat window, or opens a new one (spec 9.1).
        case 'open-chat':
          dispatch({ panelId: chatPanelId(sessionId), type: 'open' })
          break
        case 'close-chat':
          dispatch({ panelId: chatPanelId(sessionId), type: 'close' })
          break
        case 'focus-send':
          select(sessionId)
          dispatch({ panelId: 'selected-item', type: 'open' })
          focusCount.current += 1
          setFocusRequest({ at: Date.now(), n: focusCount.current, sessionId, text: plan.text })
          break
        case 'send':
          send(sessionId, plan.text).catch(fail)
          break
        case 'rename':
          setRenameFor(sessionId)
          break
        case 'call':
          if (row) void runCall(plan, row, arg)
          break
      }
    },
    [dispatch, fail, runCall, select, send],
  )

  // The alerts listener reads run and select from this ref. So it subscribes one time.
  const alertsRef = useRef({ run, select })
  useLayoutEffect(() => {
    alertsRef.current = { run, select }
  }, [run, select])
  // The session of a click on a notification that waits for its row.
  const notifiedOpen = useRef<string | null>(null)

  // Open the session that waits, when its row is there (notifiedOpenStep).
  const openNotified = useCallback(() => {
    const sessionId = notifiedOpen.current
    if (sessionId === null) return
    const now = latest.current
    const step = notifiedOpenStep(sessionId, now.rows, now.loaded)
    if (step === 'wait') return
    notifiedOpen.current = null
    if (step === 'open') alertsRef.current.run('open', sessionId)
  }, [])

  // A click on a notification of a box selects the session and opens its chat window. The run
  // opens the chat window only for an owned row that is not parked. A new window can get the
  // click before the rows. Then the Open waits for the row.
  useEffect(
    () =>
      window.bifrost.alerts.onOpen(sessionId => {
        alertsRef.current.select(sessionId)
        notifiedOpen.current = sessionId
        openNotified()
      }),
    [openNotified],
  )

  // New rows or the first registry update can end the wait.
  // biome-ignore lint/correctness/useExhaustiveDependencies: each change of the rows can end the wait.
  useEffect(() => openNotified(), [loaded, rows, openNotified])

  const runGlobal = useCallback(
    (id: GlobalActionId) => {
      if (id === 'new-session') {
        setNewSessionOpen(true)
        return
      }
      const ctx = globalOf(
        latest.current.rows,
        resumeAllRef.current,
        latest.current.settings.labels,
      )
      if (!globalActionState('resume-all', ctx).enabled) return
      resumeAllRef.current = true
      setResumeAllRunning(true)
      window.bifrost.sessions
        .resumeAll()
        .then(result => {
          notices.notify(resumedNotice(result.resumed))
          if (result.failed.length > 0) {
            showError(result.failed.map(f => `${f.name}: ${friendlyError(f.error)}`).join('; '))
          }
        }, fail)
        .finally(() => {
          resumeAllRef.current = false
          setResumeAllRunning(false)
        })
    },
    [fail, notices, showError],
  )

  const value = useMemo<ActionsValue>(
    () => ({
      apps,
      clearFocusRequest,
      closeError,
      contextFor: sessionId =>
        contextOf(sessionId, state, apps, running.has(sessionId), history.recentSlash, settings),
      error,
      focusRequest,
      globalContext: () => globalOf(rows, resumeAllRunning, settings.labels),
      newSessionOpen,
      notice,
      run,
      runGlobal,
      send,
    }),
    [
      apps,
      clearFocusRequest,
      closeError,
      error,
      focusRequest,
      history.recentSlash,
      newSessionOpen,
      notice,
      resumeAllRunning,
      rows,
      run,
      runGlobal,
      running,
      send,
      settings,
      state,
    ],
  )
  return (
    <ActionsContext value={value}>
      {children}
      {renameFor !== null && (
        <RenameDialog
          key={renameFor}
          onClose={() => closeRename(renameFor)}
          sessionId={renameFor}
        />
      )}
      <NewSessionDialog onClose={closeNewSession} open={newSessionOpen} />
    </ActionsContext>
  )
}

export function useActions(): ActionsValue {
  const value = useContext(ActionsContext)
  if (!value) throw new Error('useActions needs an ActionsProvider.')
  return value
}
