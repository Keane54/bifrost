import { Crosshair, List, ListPlus, type LucideIcon, Plug } from 'lucide-react'
import { memo } from 'react'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { panelTitle } from '../panels/panels'
import { useWmControls, useWmState } from './context'
import LayoutMenu from './LayoutMenu'
import { type Frame, frameOf, panelKind, type WmState } from './state'

const MAX_OVERVIEW = 99

const BUTTON =
  'flex w-8 shrink-0 items-center justify-center rounded text-text-dim text-xs hover:bg-panel hover:text-text disabled:opacity-40 disabled:hover:bg-transparent'

// The Overview to focus: the top visible frame with an Overview first, then a minimised one.
// In a frame, the active panel wins over the other tabs.
function topOverview(frames: Frame[]): string | undefined {
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

function SideButton(props: {
  label: string
  icon: LucideIcon
  disabled?: boolean
  onClick(): void
}): React.JSX.Element {
  const Icon = props.icon
  return (
    <button
      aria-label={props.label}
      className={cx(BUTTON, 'h-8')}
      disabled={props.disabled}
      onClick={props.onClick}
      title={props.label}
      type='button'
    >
      <Icon aria-hidden={true} size={16} />
    </button>
  )
}

// The thin bar on the left edge: one button for each panel type, then the minimised frames.
// The Layouts button is at the bottom.
function SideBar(): React.JSX.Element {
  const state = useWmState()
  const { dispatch } = useWmControls()
  const { rows } = useRegistry()
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
      <SideButton icon={Plug} label='Integration' onClick={() => open('integration')} />
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
    </nav>
  )
}

// The side bar has no props. It renders only when a context value changes.
// A drag step changes no context value, so the side bar does not render at each step.
export default memo(SideBar)
