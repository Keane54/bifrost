// An icon button for one action of a session (spec 8.4 item 2).
import { Button } from '@base-ui/react/button'
import { Menu } from '@base-ui/react/menu'
import {
  AppWindow,
  Circle,
  Eye,
  EyeOff,
  Hand,
  Info,
  type LucideIcon,
  MessageSquare,
  Power,
  Shrink,
  Slash,
  SquareTerminal,
} from 'lucide-react'
import { isWatchColour } from '../../../shared/watch'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { MENU_ITEM, MENU_POPUP, Tip } from '../lib/menu'
import { WATCH_SWATCH } from '../watch/watch-colours'
import {
  type ActionId,
  actionLabel,
  actionStateFor,
  buttonTip,
  checkedKey,
  rowMenu,
} from './action-model'
import { useActions } from './actions-context'

// The icons of the Selected Item buttons. Another action shows a plain circle.
const ICONS: Partial<Record<ActionId, LucideIcon>> = {
  compact: Shrink,
  interrupt: Hand,
  open: AppWindow,
  'open-in-terminal': SquareTerminal,
  'run-slash': Slash,
  'send-message': MessageSquare,
  'show-info': Info,
  stop: Power,
  'watch-add': Eye,
  'watch-remove': EyeOff,
}

const BUTTON =
  'flex size-6 shrink-0 items-center justify-center text-text hover:bg-hover not-data-disabled:active:bg-accent/12 data-disabled:opacity-40 data-disabled:hover:bg-transparent'

// The Add to watchlist button. It opens the colour submenu of the row menu (spec 8.12).
// The items come from the same model, so the colours and the labels are the same.
function WatchAddButton({ sessionId }: { sessionId: string }): React.JSX.Element {
  const { rows } = useRegistry()
  const { contextFor, run } = useActions()
  const ctx = contextFor(sessionId)
  const row = rows.find(r => r.sessionId === sessionId)
  const state = actionStateFor('watch-add', row, ctx)
  const entry = row
    ? rowMenu(row, ctx).find(e => e.type !== 'separator' && e.action === 'watch-add')
    : undefined
  const items = entry?.type === 'submenu' ? entry.items : []
  return (
    <Menu.Root>
      <Tip label={buttonTip('watch-add', state, ctx.labels)}>
        <Menu.Trigger
          aria-label={actionLabel('watch-add', ctx.labels)}
          className={BUTTON}
          data-action='watch-add'
          disabled={!state.enabled}
        >
          <Eye aria-hidden={true} size={15} />
        </Menu.Trigger>
      </Tip>
      <Menu.Portal>
        <Menu.Positioner className='z-50 outline-none' side='bottom'>
          <Menu.Popup className={MENU_POPUP} data-submenu='watch-add'>
            <Menu.RadioGroup value={checkedKey(items)}>
              {items.map(item => (
                <Menu.RadioItem
                  className={MENU_ITEM}
                  closeOnClick={true}
                  data-arg={item.key}
                  key={item.key}
                  onClick={() => run('watch-add', sessionId, item.arg)}
                  value={item.key}
                >
                  <span
                    aria-hidden={true}
                    className={cx(
                      'size-2 shrink-0',
                      isWatchColour(item.arg) && WATCH_SWATCH[item.arg],
                    )}
                  />
                  {item.label}
                </Menu.RadioItem>
              ))}
            </Menu.RadioGroup>
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  )
}

// A disabled button shows darker and faded. It keeps the focus and the tooltip.
// A click on it has no effect (spec 9.1). A press on a button that is not disabled gives a short
// cyan tint (spec 8.10).
export default function ActionButton({
  action,
  sessionId,
}: {
  action: ActionId
  sessionId: string
}): React.JSX.Element {
  const { rows } = useRegistry()
  const { contextFor, run } = useActions()
  const ctx = contextFor(sessionId)
  if (action === 'watch-add') return <WatchAddButton sessionId={sessionId} />
  const state = actionStateFor(
    action,
    rows.find(r => r.sessionId === sessionId),
    ctx,
  )
  const Icon = ICONS[action] ?? Circle
  return (
    <Tip label={buttonTip(action, state, ctx.labels)}>
      <Button
        aria-label={actionLabel(action, ctx.labels)}
        className={BUTTON}
        data-action={action}
        disabled={!state.enabled}
        focusableWhenDisabled={true}
        onClick={() => run(action, sessionId)}
      >
        <Icon aria-hidden={true} size={15} />
      </Button>
    </Tip>
  )
}
