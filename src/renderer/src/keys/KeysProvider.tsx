// The keys of spec 9.4 in the app (D5, D8, D26). TanStack Hotkeys registers each key on the
// document in the capture phase. The callback finds the focus zone. Only a key that keyAllowed
// accepts stops the event and runs its command. So a chat window gets every other key unchanged.
import { type UseHotkeyDefinition, useHotkeys } from '@tanstack/react-hotkeys'
import {
  createContext,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import {
  activeBindings,
  effectiveKeys,
  type FocusZone,
  type KeySlot,
  keyAllowed,
} from '../../../shared/keys'
import { useActions } from '../actions/actions-context'
import { useRegistry } from '../data/registry'
import { useOverviews } from '../overview/overviews-context'
import { useSettings } from '../settings/settings-context'
import { useLayouts, useWmControls, useWmState } from '../wm/context'
import { topOverview } from '../wm/SideBar'
import { type KeyContext, type KeyIntent, planHold, planKey } from './commands'
import { focusChange, focusZone, OVERVIEW_ROWS_ATTR } from './focus-zone'
import { HoldGate } from './hold-gate'
import { gateChange, toRawChord } from './raw-chord'

export interface KeysValue {
  // A primary pointer-down on a row calls this. It claims a held hold key for the row (D8). So a
  // keyup before the mouse-up does not act on the selected row.
  holdPress(sessionId: string): void
  // A row click calls this first. True means that the pointer-down of this click claimed a held
  // hold key. The hold command then runs on the row (D8).
  holdClick(sessionId: string): boolean
  // True while a row click is a hold click. Then a double-click does not select or open the row.
  holding(): boolean
}

const KeysContext = createContext<KeysValue | null>(null)

// The options of all Bifrost keys (D5).
const COMMON_OPTIONS = {
  capture: true,
  conflictBehavior: 'allow',
  ignoreInputs: false,
  preventDefault: false,
  stopPropagation: false,
} as const

// The bindings that TanStack Hotkeys cannot use. Each one goes to the console one time.
const logged = new Set<string>()

function logBadBinding(binding: string): void {
  if (logged.has(binding)) return
  logged.add(binding)
  console.warn(`Bifrost cannot register the key "${binding}".`)
}

// The focus zone of the focused element now.
function currentZone(): FocusZone {
  return focusZone(document.activeElement)
}

// It must be inside the providers of the registry, the window manager, the actions and the
// Overview configs.
export function KeysProvider({ children }: { children: React.ReactNode }): React.JSX.Element {
  const { settings } = useSettings()
  const actions = useActions()
  const { rows, select, selectedId } = useRegistry()
  const { frames } = useWmState()
  const { dispatch, loadLayout, openLayoutSave } = useWmControls()
  const layouts = useLayouts()
  const overviews = useOverviews()
  const [gate] = useState(() => new HoldGate())

  const bindings = useMemo(() => activeBindings(effectiveKeys(settings.keys)), [settings.keys])
  // The hold keys are the bindings of the hold slots.
  const holdKeys = useMemo(
    () =>
      new Set(bindings.filter(entry => entry.slot.group === 'hold').map(entry => entry.binding)),
    [bindings],
  )

  // The callbacks read the data of the last render from this ref, at the time of the event.
  const latest = useRef({
    actions,
    bindings,
    dispatch,
    frames,
    holdKeys,
    layouts,
    loadLayout,
    openLayoutSave,
    overviews,
    rows,
    select,
    selectedId,
    settings,
  })
  useLayoutEffect(() => {
    latest.current = {
      actions,
      bindings,
      dispatch,
      frames,
      holdKeys,
      layouts,
      loadLayout,
      openLayoutSave,
      overviews,
      rows,
      select,
      selectedId,
      settings,
    }
  })

  // The functions below read only the ref and the gate. So they never change.
  const [run] = useState(() => {
    // The context of planKey for the current state.
    const contextFor = (zone: FocusZone): KeyContext => {
      const now = latest.current
      return {
        // The project apps come from the actions context of the selected row (D-7).
        apps: now.selectedId === null ? [] : now.actions.contextFor(now.selectedId).apps,
        frames: now.frames,
        overviews: now.overviews.state,
        projectApp: now.settings.projectApp,
        rows: now.rows,
        selectedId: now.selectedId,
        zone,
      }
    }

    // Focus the rows of an Overview in the next animation frame, after the panel shows.
    const focusRows = (panelId: string): void => {
      requestAnimationFrame(() => {
        const selector = `[${OVERVIEW_ROWS_ATTR}="${CSS.escape(panelId)}"]`
        document.querySelector<HTMLElement>(selector)?.focus()
      })
    }

    const intent = (next: KeyIntent): void => {
      const now = latest.current
      switch (next.kind) {
        case 'none':
          return
        case 'action':
          now.actions.run(next.action, next.sessionId, next.arg)
          return
        case 'global':
          now.actions.runGlobal(next.action)
          return
        case 'select':
          now.select(next.sessionId)
          return
        case 'overview-tab':
          now.overviews.dispatch({
            action: { tabId: next.tabId, type: 'activate' },
            panelId: next.panelId,
            type: 'update',
          })
          return
        case 'activate-panel':
          now.dispatch({ panelId: next.panelId, type: 'activate' })
          return
        case 'focus-overview': {
          // With no shown Overview, a minimised Overview or an Overview tab of a stack comes
          // back. With no Overview at all, overview:1 opens (D9).
          const panelId = next.panelId ?? topOverview(now.frames) ?? 'overview:1'
          now.dispatch({ panelId, type: 'open' })
          focusRows(panelId)
          return
        }
        case 'open-panel':
          now.dispatch({ panelId: next.panelId, type: 'open' })
          return
        case 'load-layout': {
          const name = now.layouts[next.index]
          if (name !== undefined) now.loadLayout(name)
          return
        }
        case 'save-layout':
          now.openLayoutSave()
          return
        case 'leave-send-box': {
          const active = document.activeElement
          if (active instanceof HTMLElement) active.blur()
          return
        }
      }
    }

    // A key that is not a hold key. Return at once when the zone does not allow it (D5).
    // Esc does not stop the event, so the Esc listener of a Watchlist drag still gets it (D26).
    const key = (slot: KeySlot, binding: string, event: KeyboardEvent): void => {
      const zone = currentZone()
      if (!keyAllowed(slot, binding, zone)) return
      event.preventDefault()
      if (slot.command !== 'escape') event.stopPropagation()
      intent(planKey(slot, contextFor(zone)))
    }

    // A hold key goes down. It is active only in the other zone (ruling C3).
    const holdDown = (holdKey: string, event: KeyboardEvent): void => {
      const active = currentZone() === 'other'
      gate.down(holdKey, active)
      if (active) event.preventDefault()
    }

    // A hold key goes up. With no row click during the hold, the key runs the command of its
    // slot that is not a hold slot (D8).
    const holdUp = (holdKey: string): void => {
      if (!gate.up(holdKey)) return
      const entry = latest.current.bindings.find(
        item => item.slot.group !== 'hold' && item.binding === holdKey,
      )
      if (!entry) return
      // The focus can move during the hold. Then the key does not act.
      const zone = currentZone()
      if (!keyAllowed(entry.slot, holdKey, zone)) return
      intent(planKey(entry.slot, contextFor(zone)))
    }

    const holdPress = (sessionId: string): void => {
      gate.press(sessionId)
    }

    const holdClick = (sessionId: string): boolean => {
      const holdKey = gate.release(sessionId)
      if (holdKey === null) return false
      const now = latest.current
      const entry = now.bindings.find(
        item => item.slot.group === 'hold' && item.binding === holdKey,
      )
      if (!entry) return false
      const apps = now.actions.contextFor(sessionId).apps
      intent(planHold(entry.slot, sessionId, { apps, projectApp: now.settings.projectApp }))
      return true
    }

    return { holdClick, holdDown, holdPress, holdUp, key }
  })

  const definitions = useMemo(() => {
    const list: UseHotkeyDefinition[] = []
    for (const { slot, binding } of bindings) {
      if (slot.group === 'hold' || holdKeys.has(binding)) continue
      const hotkey = toRawChord(binding)
      if (hotkey === null) {
        logBadBinding(binding)
        continue
      }
      list.push({ callback: event => run.key(slot, binding, event), hotkey })
    }
    for (const holdKey of holdKeys) {
      const hotkey = toRawChord(holdKey)
      if (hotkey === null) {
        logBadBinding(holdKey)
        continue
      }
      list.push({ callback: event => run.holdDown(holdKey, event), hotkey })
      list.push({
        callback: () => run.holdUp(holdKey),
        hotkey,
        options: { eventType: 'keyup' },
      })
    }
    return list
  }, [bindings, holdKeys, run])

  useHotkeys(definitions, COMMON_OPTIONS)

  // The gate forgets all keys when the window loses the focus or the page hides. Then no keyup
  // comes. It also forgets all keys at a keydown or a keyup of Cmd, because macOS sends no keyup
  // for a key that goes up while Cmd is down. A keyup with a modifier does not match the hotkey of
  // a hold key, so a listener here removes that key from the gate.
  // A focus in a chat window selects its session, and a focus on the key recorder clears the gate
  // (see focusChange).
  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      const type = event.type === 'keyup' ? 'keyup' : 'keydown'
      const change = gateChange(type, event, latest.current.holdKeys)
      if (change?.kind === 'clear') gate.clear()
      else if (change?.kind === 'up') gate.up(change.key)
    }
    const onFocusIn = (event: FocusEvent): void => {
      const now = latest.current
      const target = event.target instanceof Element ? event.target : null
      const change = focusChange(target, now.selectedId, now.rows)
      if (change.clearGate) gate.clear()
      if (change.select !== null) now.select(change.select)
    }
    const onBlur = (): void => gate.clear()
    const onVisibility = (): void => {
      if (document.visibilityState === 'hidden') gate.clear()
    }
    document.addEventListener('keydown', onKey, true)
    document.addEventListener('keyup', onKey, true)
    document.addEventListener('focusin', onFocusIn, true)
    window.addEventListener('blur', onBlur)
    document.addEventListener('visibilitychange', onVisibility)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      document.removeEventListener('keyup', onKey, true)
      document.removeEventListener('focusin', onFocusIn, true)
      window.removeEventListener('blur', onBlur)
      document.removeEventListener('visibilitychange', onVisibility)
    }
  }, [gate])

  const value = useMemo<KeysValue>(
    () => ({ holdClick: run.holdClick, holding: () => gate.holding(), holdPress: run.holdPress }),
    [gate, run],
  )
  return <KeysContext value={value}>{children}</KeysContext>
}

export function useKeys(): KeysValue {
  const value = useContext(KeysContext)
  if (!value) throw new Error('useKeys needs a KeysProvider.')
  return value
}
