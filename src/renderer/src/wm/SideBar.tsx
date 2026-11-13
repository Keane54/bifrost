import { Button } from '@base-ui/react/button'
import {
  CircleArrowDown,
  ListPlus,
  type LucideIcon,
  RotateCcw,
  SquarePlus,
  TriangleAlert,
} from 'lucide-react'
import { memo, useId } from 'react'
import type { SessionRow } from '../../../shared/types'
import { UPDATE_TEXTS } from '../../../shared/updates'
import {
  actionLabel,
  buttonTip,
  type GlobalActionId,
  globalActionState,
} from '../actions/action-model'
import { useActions } from '../actions/actions-context'
import { chatSessionId } from '../chat/views'
import { useDailyMarker } from '../daily-update/use-daily-update'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { Tip } from '../lib/menu'
import { TONE_TEXT } from '../overview/cells'
import { stateTone } from '../overview/format'
import { SessionIcon } from '../overview/SessionIcon'
import { panelTitle } from '../panels/panels'
import { usePerformanceState } from '../performance/use-performance'
import { useReviewsAttention } from '../reviews/use-reviews'
import { useLive } from '../settings/live-context'
import { useSettingsNav } from '../settings/settings-nav'
import { useUpdateButton } from '../updates/use-updates'
import { useWmControls, useWmState } from './context'
import LayoutMenu from './LayoutMenu'
import { PANEL_ICONS } from './panel-icons'
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

// The tooltip at the right of the button gives the name of the button (user decision, 2026-11-09).
// With dot, the button shows a 6 px square dot at its top right corner, and the tooltip
// gives the reason. The dot is white, or it has the colour class dotClass. The name stays the
// label. A hidden text gives the reason to a screen reader as the description.
function SideButton(props: {
  label: string
  icon: LucideIcon
  disabled?: boolean
  size?: number
  dot?: string
  dotClass?: string
  // A class for the icon, for example a colour.
  iconClass?: string
  // The tooltip gives the reason, but the button shows no dot.
  dotHidden?: boolean
  onClick(): void
}): React.JSX.Element {
  const Icon = props.icon
  const dotId = useId()
  return (
    <Tip label={props.dot ?? props.label} side='right'>
      <button
        aria-describedby={props.dot === undefined ? undefined : dotId}
        aria-label={props.label}
        className={cx(BUTTON, 'relative h-8')}
        disabled={props.disabled}
        onClick={props.onClick}
        type='button'
      >
        <Icon aria-hidden={true} className={props.iconClass} size={props.size ?? 16} />
        {props.dot !== undefined && (
          <>
            {props.dotHidden !== true && (
              <span
                aria-hidden={true}
                className={cx(
                  'absolute top-1.5 right-1.5 size-1.5',
                  props.dotClass ?? 'bg-text-strong',
                )}
                data-side-warning={true}
              />
            )}
            <span className='sr-only' id={dotId}>
              {props.dot}
            </span>
          </>
        )}
      </button>
    </Tip>
  )
}

// The icon of a minimised frame. A chat shows the icon of its session and the state dot, as the
// chat title does. Every other panel shows the icon of its side bar button.
function MinimisedIcon(props: { panelId: string; rows: SessionRow[] }): React.JSX.Element {
  const kind = panelKind(props.panelId)
  const id = kind === 'chat' ? chatSessionId(props.panelId) : undefined
  const row = props.rows.find(r => r.sessionId === id)
  if (row) {
    return (
      <>
        <span className='pointer-events-none inline-flex'>
          <SessionIcon noTitle={true} row={row} size={16} />
        </span>
        <span
          aria-hidden={true}
          className={cx(
            'absolute right-1.5 bottom-1.5 size-1.5 bg-current',
            TONE_TEXT[stateTone(row)],
          )}
          data-state-dot={row.state}
        />
      </>
    )
  }
  const Icon = PANEL_ICONS[kind ?? 'chat']
  return <Icon aria-hidden={true} className='pointer-events-none' size={16} />
}

// The update button shows only for a ready update (a pulsing green dot) or a failed update
// (an orange triangle). In every other state it does not show.
function UpdateButton(): React.JSX.Element | null {
  const update = useUpdateButton()
  const settingsNav = useSettingsNav()
  if (update === null) return null
  if (update.kind === 'failed') {
    return (
      <SideButton
        dot={UPDATE_TEXTS.failed}
        dotHidden={true}
        icon={TriangleAlert}
        iconClass='text-ctx-mid'
        label='Update Bifrost'
        onClick={() => settingsNav.open('updates')}
      />
    )
  }
  return (
    <SideButton
      dot={UPDATE_TEXTS.ready(update.version)}
      dotClass={cx('bg-ctx-low', 'animate-update-pulse', 'motion-reduce:animate-none')}
      icon={CircleArrowDown}
      label='Update Bifrost'
      onClick={() => {
        window.bifrost.updates.restart().catch(() => {})
      }}
    />
  )
}

const REVIEWS_ATTENTION = 'Reviews - a pull request waits for you'
// The Daily update dot shows on a due day after the draft time, while an area is not sent.
const DAILY_ATTENTION = 'Daily update - Not sent yet'
const SETTINGS_ATTENTION = 'Settings - something needs your attention'
// The Performance dot has the colour of the health state (design section 5.3). OK has no dot.
const PERFORMANCE_ATTENTION: Record<'warning' | 'problem', string> = {
  problem: 'Performance - Problem',
  warning: 'Performance - Warning',
}
const PERFORMANCE_DOT: Record<'warning' | 'problem', string> = {
  problem: 'bg-ctx-high',
  warning: 'bg-ctx-mid',
}

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
        className='flex h-8 w-8 shrink-0 items-center justify-center text-xs text-text-dim hover:bg-panel hover:text-text not-data-disabled:active:bg-accent/12 data-disabled:opacity-40 data-disabled:hover:bg-transparent'
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
  const reviewsAttention = useReviewsAttention()
  const health = usePerformanceState()
  const dailyMarker = useDailyMarker()
  const open = (panelId: string): void => dispatch({ panelId, type: 'open' })
  const free = freeOverview(state)
  const minimised = state.frames.filter(f => f.minimised)

  return (
    <nav
      aria-label='Side bar'
      className='flex w-10 shrink-0 flex-col items-center gap-1 border-r border-panel-edge bg-title py-2 select-none'
    >
      <SideButton
        icon={PANEL_ICONS.overview}
        label='Overview'
        onClick={() => open(topOverview(state.frames) ?? 'overview:1')}
      />
      <SideButton
        disabled={free === undefined}
        icon={ListPlus}
        label='New Overview'
        onClick={() => free && open(free)}
      />
      <SideButton
        icon={PANEL_ICONS['selected-item']}
        label='Selected Item'
        onClick={() => open('selected-item')}
      />
      <SideButton
        icon={PANEL_ICONS.watchlist}
        label='Watchlist'
        onClick={() => open('watchlist')}
      />
      <SideButton
        icon={PANEL_ICONS['event-log']}
        label='Event log'
        onClick={() => open('event-log')}
      />
      <SideButton
        icon={PANEL_ICONS['usage-hud']}
        label='Usage HUD'
        onClick={() => open('usage-hud')}
      />
      <SideButton
        icon={PANEL_ICONS['service-status']}
        label='Service status'
        onClick={() => open('service-status')}
      />
      <SideButton
        dot={reviewsAttention ? REVIEWS_ATTENTION : undefined}
        icon={PANEL_ICONS.reviews}
        label='Reviews'
        onClick={() => open('reviews')}
      />
      <SideButton
        dot={dailyMarker ? DAILY_ATTENTION : undefined}
        icon={PANEL_ICONS['daily-update']}
        label='Daily update'
        onClick={() => open('daily-update')}
      />
      <SideButton
        dot={health === 'ok' ? undefined : PERFORMANCE_ATTENTION[health]}
        dotClass={health === 'ok' ? undefined : PERFORMANCE_DOT[health]}
        icon={PANEL_ICONS.performance}
        label='Performance'
        onClick={() => open('performance')}
      />
      <div className='my-1 h-px w-6 shrink-0 bg-panel-edge' />
      <GlobalButton action='new-session' icon={SquarePlus} />
      <GlobalButton action='resume-all' icon={RotateCcw} />
      {minimised.length > 0 && <div className='my-1 h-px w-6 shrink-0 bg-panel-edge' />}
      <div className='flex min-h-0 flex-col items-center gap-1 overflow-y-auto'>
        {minimised.map(frame => {
          const title = panelTitle(frame.active, rows)
          return (
            <Tip key={frame.id} label={title} side='right'>
              <button
                aria-label={`Restore ${title}`}
                className={cx(BUTTON, 'relative h-8')}
                data-minimised-frame={frame.id}
                onClick={() => dispatch({ frameId: frame.id, type: 'restore' })}
                type='button'
              >
                <MinimisedIcon panelId={frame.active} rows={rows} />
              </button>
            </Tip>
          )
        })}
      </div>
      <UpdateButton />
      <LayoutMenu className={BUTTON} />
      <SideButton
        dot={warning ? SETTINGS_ATTENTION : undefined}
        icon={PANEL_ICONS.settings}
        label='Settings'
        onClick={() => settingsNav.open()}
        size={15}
      />
    </nav>
  )
}

// The side bar has no props. It renders only when a context value changes, when the health
// state of the Performance store changes, or when the Daily update marker changes. A drag step
// changes no context value, and a new snapshot with the same health state or the same marker
// gives the same value. So these do not render the side bar.
export default memo(SideBar)
