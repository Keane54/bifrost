// An icon button for one action of a session (spec 8.4 item 2).
import { Button } from '@base-ui/react/button'
import {
  AppWindow,
  Circle,
  Hand,
  Info,
  type LucideIcon,
  MessageSquare,
  Power,
  Slash,
  SquareTerminal,
} from 'lucide-react'
import { useRegistry } from '../data/registry'
import { Tip } from '../lib/menu'
import { type ActionId, actionLabel, actionStateFor, buttonTip } from './action-model'
import { useActions } from './actions-context'

// The icons of the Selected Item buttons. Another action shows a plain circle.
const ICONS: Partial<Record<ActionId, LucideIcon>> = {
  interrupt: Hand,
  open: AppWindow,
  'open-in-terminal': SquareTerminal,
  'run-slash': Slash,
  'send-message': MessageSquare,
  'show-info': Info,
  stop: Power,
}

// A disabled button shows darker and faded. It keeps the focus and the tooltip.
// A click on it has no effect (spec 9.1).
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
        className='flex size-6 shrink-0 items-center justify-center rounded text-text hover:bg-hover data-disabled:opacity-40 data-disabled:hover:bg-transparent'
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
