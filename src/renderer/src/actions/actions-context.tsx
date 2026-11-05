// Run the actions of M3 for a session, and give the context that the action model needs.
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
import type { ProjectApp, ProjectAppId } from '../../../shared/types'
import { chatPanelId } from '../chat/views'
import { useRegistry } from '../data/registry'
import { errorMessage } from '../lib/error-message'
import { useWmControls, useWmState } from '../wm/context'
import { frameOf, type WmState } from '../wm/state'
import {
  type ActionContext,
  type ActionId,
  actionStateFor,
  type LabelSet,
  type MenuArg,
} from './action-model'

// The Labels setting comes in M5 (spec 9.1). Until then, Bifrost uses the plain labels.
export const LABELS: LabelSet = 'plain'

// An error of an action shows for 5 seconds.
const ERROR_MS = 5000

export interface ActionsValue {
  run(id: ActionId, sessionId: string, arg?: MenuArg): void
  contextFor(sessionId: string): ActionContext
  // The message of the last failed action, or null.
  error: string | null
}

const ActionsContext = createContext<ActionsValue | null>(null)

function contextOf(sessionId: string, state: WmState, apps: ProjectApp[]): ActionContext {
  return { apps, chatOpen: frameOf(state, chatPanelId(sessionId)) !== undefined, labels: LABELS }
}

function isAppId(arg: MenuArg | undefined, apps: ProjectApp[]): arg is ProjectAppId {
  return typeof arg === 'string' && apps.some(app => app.id === arg)
}

// It must be inside the providers of the registry and of the window manager.
export function ActionsProvider({ children }: { children: React.ReactNode }): React.JSX.Element {
  const state = useWmState()
  const { dispatch } = useWmControls()
  const { rows } = useRegistry()
  const [apps, setApps] = useState<ProjectApp[]>([])
  const [error, setError] = useState<string | null>(null)
  const errorTimer = useRef<number | undefined>(undefined)
  // run reads the data of the last render from this ref. So it checks the current row.
  const latest = useRef({ apps, rows, state })

  useLayoutEffect(() => {
    latest.current = { apps, rows, state }
  }, [apps, rows, state])

  // One call at mount. The list stays empty until the call resolves.
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
  }, [])

  useEffect(() => () => window.clearTimeout(errorTimer.current), [])

  // A new error replaces the last error. It shows for the full time.
  const fail = useCallback((err: unknown) => {
    window.clearTimeout(errorTimer.current)
    setError(errorMessage(err))
    errorTimer.current = window.setTimeout(() => setError(null), ERROR_MS)
  }, [])

  const run = useCallback(
    (id: ActionId, sessionId: string, arg?: MenuArg) => {
      const now = latest.current
      const row = now.rows.find(r => r.sessionId === sessionId)
      // A disabled action has no effect. The row can change after the menu opens.
      if (!actionStateFor(id, row, contextOf(sessionId, now.state, now.apps)).enabled) return
      let call: Promise<void> | undefined
      switch (id) {
        // The window manager focuses an open chat window, or opens a new one (spec 9.1).
        case 'open':
          dispatch({ panelId: chatPanelId(sessionId), type: 'open' })
          break
        case 'close-window':
          dispatch({ panelId: chatPanelId(sessionId), type: 'close' })
          break
        case 'set-priority':
          if (arg === null || isPriority(arg)) {
            call = window.bifrost.registry.setPriority(sessionId, arg)
          }
          break
        case 'copy-id':
          call = window.bifrost.actions.copySessionId(sessionId)
          break
        case 'open-project':
          if (isAppId(arg, now.apps)) call = window.bifrost.actions.openProject(sessionId, arg)
          break
        default:
          // The other actions come in M4 and M5. The action model disables them.
          break
      }
      call?.catch(fail)
    },
    [dispatch, fail],
  )

  const value = useMemo<ActionsValue>(
    () => ({ contextFor: sessionId => contextOf(sessionId, state, apps), error, run }),
    [apps, error, run, state],
  )
  return <ActionsContext value={value}>{children}</ActionsContext>
}

export function useActions(): ActionsValue {
  const value = useContext(ActionsContext)
  if (!value) throw new Error('useActions needs an ActionsProvider.')
  return value
}
