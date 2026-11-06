import { Button } from '@base-ui/react/button'
import {
  Crosshair,
  Eye,
  Gauge,
  List,
  ListPlus,
  type LucideIcon,
  RotateCcw,
  ScrollText,
  Settings,
  SquarePlus,
} from 'lucide-react'
import { memo, useId } from 'react'
import {
  actionLabel,
  buttonTip,
  type GlobalActionId,
  globalActionState,
} from '../actions/action-model'
import { useActions } from '../actions/actions-context'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { Tip } from '../lib/menu'
import { panelTitle } from '../panels/panels'
import { useLive } from '../settings/live-context'
import { useSettingsNav } from '../settings/settings-nav'
import { useWmControls, useWmState } from './context'
import LayoutMenu from './LayoutMenu'
import { type Frame, frameOf, panelKind, type WmState } from './state'

const MAX_OVERVIEW = 99

// A press gives a short cyan tint. A hover stays neutral (spec 8.10).
const BUTTON =
  'flex w-8 shrink-0 items-center justify-center text-text-dim text-xs hover:bg-panel hover:text-text enabled:active:bg-accent/12 disabled:opacity-40 disabled:hover:bg-transparent'

// The Overview to focus: the top visible frame with an Overview first, then a minimised one.
// In a frame, the active panel wins over the other tabs.
export function topOverview(frames: Frame[]): string | undefined {
  const order = [...frames].reverse()
  for (const frame of [...order.filter(f => !f.minimised), ...order.filter(f => f.minimised)]) {
    if (panelKind(frame.active) === 'overview') return frame.active
    const panelId = frame.panels.find(p => panelKind(p) === 'overview')
    if (panelId) return panelId
  }
  return undefined
}

// The lowest Overview number that no frame has.
function freeOverview(state: WmState): string | undefined {
  for (let n = 1; n <= MAX_OVERVIEW; n++) {
    const panelId = `overview:${n}`
    if (!frameOf(state, panelId)) return panelId
  }
  return undefined
}

// With dot, the button shows a 6 px square white dot at its top right corner, and the
// tooltip gives the reason. The name stays the label. A hidden text gives the reason to a
// screen reader as the description.
function SideButton(props: {
  label: string
  icon: LucideIcon
  disabled?: boolean
  size?: number
  dot?: string
  onClick(): void
}): React.JSX.Element {
  const Icon = props.icon
  const dotId = useId()
  return (
    <button
      aria-describedby={props.dot === undefined ? undefined : dotId}
      aria-label={props.label}
      className={cx(BUTTON, 'relative h-8')}
      disabled={props.disabled}
      onClick={props.onClick}
      title={props.dot ?? props.label}
      type='button'
    >
      <Icon aria-hidden={true} size={props.size ?? 16} />
      {props.dot !== undefined && (
        <>
          <span
            aria-hidden={true}
            className='absolute top-1.5 right-1.5 size-1.5 bg-text-strong'
            data-side-warning={true}
          />
          <span className='sr-only' id={dotId}>
            {props.dot}
          </span>
        </>
      )}
    </button>
  )
}

const SETTINGS_ATTENTION = 'Settings - something needs your attention'

// A button for an action that needs no row (D8). A disabled button shows darker and faded.
// It keeps the focus and the tooltip with the reason. A click on it has no effect (spec 9.1).
function GlobalButton(props: { action: GlobalActionId; icon: LucideIcon }): React.JSX.Element {
  const { globalContext, runGlobal } = useActions()
  const ctx = globalContext()
  const state = globalActionState(props.action, ctx)
  const Icon = props.icon
  return (
    <Tip label={buttonTip(props.action, state, ctx.labels)} side='right'>
      <Button
        aria-label={actionLabel(props.action, ctx.labels)}
        className='flex h-8 w-8 shrink-0 items-center justify-center text-text-dim text-xs hover:bg-panel hover:text-text not-data-disabled:active:bg-accent/12 data-disabled:opacity-40 data-disabled:hover:bg-transparent'
        data-global-action={props.action}
        disabled={!state.enabled}
        focusableWhenDisabled={true}
        onClick={() => runGlobal(props.action)}
      >
        <Icon aria-hidden={true} size={15} />
      </Button>
    </Tip>
  )
}

// The thin bar on the left edge: one button for each panel type, the actions that need no row,
// then the minimised frames. The Layouts button is at the bottom.
function SideBar(): React.JSX.Element {
  const state = useWmState()
  const { dispatch } = useWmControls()
  const { rows } = useRegistry()
  const settingsNav = useSettingsNav()
  const { warning } = useLive()
  const open = (panelId: string): void => dispatch({ panelId, type: 'open' })
  const free = freeOverview(state)
  const minimised = state.frames.filter(f => f.minimised)

  return (
    <nav
      aria-label='Side bar'
      className='flex w-10 shrink-0 select-none flex-col items-center gap-1 border-panel-edge border-r bg-title py-2'
    >
      <SideButton
        icon={List}
        label='Overview'
        onClick={() => open(topOverview(state.frames) ?? 'overview:1')}
      />
      <SideButton
        disabled={free === undefined}
        icon={ListPlus}
        label='New Overview'
        onClick={() => free && open(free)}
      />
      <SideButton icon={Crosshair} label='Selected Item' onClick={() => open('selected-item')} />
      <SideButton icon={Eye} label='Watchlist' onClick={() => open('watchlist')} />
      <SideButton icon={ScrollText} label='Event log' onClick={() => open('event-log')} />
      <SideButton icon={Gauge} label='Usage HUD' onClick={() => open('usage-hud')} />
      <div className='my-1 h-px w-6 shrink-0 bg-panel-edge' />
      <GlobalButton action='new-session' icon={SquarePlus} />
      <GlobalButton action='resume-all' icon={RotateCcw} />
      {minimised.length > 0 && <div className='my-1 h-px w-6 shrink-0 bg-panel-edge' />}
      <div className='flex min-h-0 flex-col items-center gap-1 overflow-y-auto'>
        {minimised.map(frame => {
          const title = panelTitle(frame.active, rows)
          return (
            <button
              aria-label={`Restore ${title}`}
              className={cx(BUTTON, 'max-h-40 rotate-180 truncate py-2 [writing-mode:vertical-rl]')}
              key={frame.id}
              onClick={() => dispatch({ frameId: frame.id, type: 'restore' })}
              title={title}
              type='button'
            >
              {title}
            </button>
          )
        })}
      </div>
      <LayoutMenu className={BUTTON} />
      <SideButton
        dot={warning ? SETTINGS_ATTENTION : undefined}
        icon={Settings}
        label='Settings'
        onClick={() => settingsNav.open()}
        size={15}
      />
    </nav>
  )
}

// The side bar has no props. It renders only when a context value changes.
// A drag step changes no context value, so the side bar does not render at each step.
export default memo(SideBar)
