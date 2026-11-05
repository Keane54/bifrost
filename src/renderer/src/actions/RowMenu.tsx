// The entries of the right-click menu of a row (spec 9.5). They go in a ContextMenu.Popup.
import { ContextMenu } from '@base-ui/react/context-menu'
import { Check, ChevronRight } from 'lucide-react'
import { isPriority } from '../../../shared/priority'
import { cx } from '../lib/cx'
import { MENU_ITEM, MENU_POPUP, MENU_SEPARATOR, Tip } from '../lib/menu'
import { PRIO_BG } from '../overview/cells'
import {
  type ActionId,
  buttonTip,
  type MenuArg,
  type MenuEntry,
  type SubItem,
} from './action-model'
import { LABELS } from './actions-context'

type Run = (id: ActionId, arg?: MenuArg) => void
type ActionEntry = Exclude<MenuEntry, { type: 'separator' }>
type SubmenuEntry = Extract<MenuEntry, { type: 'submenu' }>

// A disabled entry shows the label and the reason. An enabled entry has no tooltip.
function tipOf(entry: ActionEntry): string | null {
  return entry.state.enabled ? null : buttonTip(entry.action, entry.state, LABELS)
}

function ItemEntry({ entry, onRun }: { entry: ActionEntry; onRun: Run }): React.JSX.Element {
  return (
    <Tip label={tipOf(entry)} side='right'>
      <ContextMenu.Item
        className={MENU_ITEM}
        data-action={entry.action}
        disabled={!entry.state.enabled}
        onClick={() => onRun(entry.action)}
      >
        {entry.label}
      </ContextMenu.Item>
    </Tip>
  )
}

// The Set priority items. The current priority has a check mark. None has no swatch.
function PriorityItems({ items, onRun }: { items: SubItem[]; onRun: Run }): React.JSX.Element {
  const checked = items.find(item => item.checked)?.key
  return (
    <ContextMenu.RadioGroup
      onValueChange={key => {
        const item = items.find(i => i.key === key)
        if (item) onRun('set-priority', item.arg)
      }}
      value={checked}
    >
      {items.map(item => (
        <ContextMenu.RadioItem
          className={MENU_ITEM}
          closeOnClick={true}
          data-arg={item.key}
          key={item.key}
          value={item.key}
        >
          <span className='flex w-3 shrink-0 justify-center'>
            <ContextMenu.RadioItemIndicator>
              <Check aria-hidden={true} size={12} />
            </ContextMenu.RadioItemIndicator>
          </span>
          <span
            aria-hidden={true}
            className={cx('size-2 shrink-0', isPriority(item.arg) && PRIO_BG[item.arg])}
          />
          {item.label}
        </ContextMenu.RadioItem>
      ))}
    </ContextMenu.RadioGroup>
  )
}

// A disabled submenu does not open. Its root is disabled too, so a key does not open it.
// The tooltip also sets data-popup-open on the trigger. So an open submenu shows with aria-expanded.
function Submenu({ entry, onRun }: { entry: SubmenuEntry; onRun: Run }): React.JSX.Element {
  const disabled = !entry.state.enabled
  return (
    <ContextMenu.SubmenuRoot disabled={disabled}>
      <Tip label={tipOf(entry)} side='right'>
        <ContextMenu.SubmenuTrigger
          className={cx(MENU_ITEM, 'justify-between pr-1 aria-expanded:bg-hover')}
          data-action={entry.action}
          disabled={disabled}
        >
          {entry.label}
          <ChevronRight aria-hidden={true} size={12} />
        </ContextMenu.SubmenuTrigger>
      </Tip>
      <ContextMenu.Portal>
        <ContextMenu.Positioner alignOffset={-5} className='z-50 outline-none'>
          <ContextMenu.Popup className={MENU_POPUP} data-submenu={entry.action}>
            {entry.action === 'set-priority' ? (
              <PriorityItems items={entry.items} onRun={onRun} />
            ) : (
              entry.items.map(item => (
                <ContextMenu.Item
                  className={MENU_ITEM}
                  data-arg={item.key}
                  key={item.key}
                  onClick={() => onRun(entry.action, item.arg)}
                >
                  {item.label}
                </ContextMenu.Item>
              ))
            )}
          </ContextMenu.Popup>
        </ContextMenu.Positioner>
      </ContextMenu.Portal>
    </ContextMenu.SubmenuRoot>
  )
}

export default function RowMenu({
  entries,
  onRun,
}: {
  entries: MenuEntry[]
  onRun(id: ActionId, arg?: MenuArg): void
}): React.JSX.Element {
  const nodes: React.ReactNode[] = []
  // A separator takes its key from the entry before it. The entries have no other ID.
  let last = 'start'
  for (const entry of entries) {
    if (entry.type === 'separator') {
      nodes.push(<ContextMenu.Separator className={MENU_SEPARATOR} key={`separator:${last}`} />)
      continue
    }
    last = entry.action
    nodes.push(
      entry.type === 'submenu' ? (
        <Submenu entry={entry} key={entry.action} onRun={onRun} />
      ) : (
        <ItemEntry entry={entry} key={entry.action} onRun={onRun} />
      ),
    )
  }
  return <>{nodes}</>
}
