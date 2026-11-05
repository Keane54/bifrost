// The tab row of an Overview: one coloured tab for each tab, the tab menu and the + button.
import { Button } from '@base-ui/react/button'
import { ContextMenu } from '@base-ui/react/context-menu'
import { Check, ChevronRight, Plus } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import type { SessionState } from '../../../shared/types'
import { REASON_LAST_TAB, REASON_MAX_TABS } from '../actions/reasons'
import { cx } from '../lib/cx'
import { MENU_ITEM, MENU_POPUP, MENU_SEPARATOR, Tip } from '../lib/menu'
import { TAB_TEXT } from './cells'
import { COLUMN_IDS, COLUMN_LABELS, type ColumnId } from './columns'
import {
  MAX_TAB_NAME,
  MAX_TABS,
  type OverviewAction,
  type OverviewConfig,
  type OverviewTab,
  STATES,
} from './config'
import { stateLabel } from './format'

type Update = (action: OverviewAction) => void

// The kind column is always visible (D4). So the Columns menu does not show it.
const MENU_COLUMNS: readonly ColumnId[] = COLUMN_IDS.filter(id => id !== 'kind')

function Submenu({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <ContextMenu.SubmenuRoot>
      <ContextMenu.SubmenuTrigger
        className={cx(MENU_ITEM, 'justify-between pr-1 data-popup-open:bg-hover')}
      >
        {label}
        <ChevronRight aria-hidden={true} size={12} />
      </ContextMenu.SubmenuTrigger>
      <ContextMenu.Portal>
        <ContextMenu.Positioner alignOffset={-5} className='z-50 outline-none'>
          <ContextMenu.Popup className={MENU_POPUP}>{children}</ContextMenu.Popup>
        </ContextMenu.Positioner>
      </ContextMenu.Portal>
    </ContextMenu.SubmenuRoot>
  )
}

// A check item stays open after a click, so you can change more than one item.
function CheckItem(props: {
  checked: boolean
  label: string
  onChange(checked: boolean): void
}): React.JSX.Element {
  return (
    <ContextMenu.CheckboxItem
      checked={props.checked}
      className={MENU_ITEM}
      onCheckedChange={checked => props.onChange(checked)}
    >
      <span className='flex w-3 shrink-0 justify-center'>
        <ContextMenu.CheckboxItemIndicator>
          <Check aria-hidden={true} size={12} />
        </ContextMenu.CheckboxItemIndicator>
      </span>
      {props.label}
    </ContextMenu.CheckboxItem>
  )
}

// The name field of a tab. Enter and blur save the name. Esc cancels. A null name means cancel.
function TabNameInput(props: { name: string; onDone(name: string | null): void }) {
  const [value, setValue] = useState(props.name)
  const ref = useRef<HTMLInputElement>(null)
  // Enter removes the field, and the removal can cause a blur. So save one time only.
  const done = useRef(false)

  useEffect(() => {
    ref.current?.focus()
    ref.current?.select()
  }, [])

  function finish(name: string | null): void {
    if (done.current) return
    done.current = true
    props.onDone(name)
  }

  return (
    <input
      aria-label='Tab name'
      className='w-32 min-w-0 self-center bg-bg px-1 text-xs outline-1 outline-current'
      maxLength={MAX_TAB_NAME}
      onBlur={() => finish(value)}
      onChange={e => setValue(e.target.value)}
      onKeyDown={e => {
        if (e.key === 'Enter') {
          e.preventDefault()
          finish(value)
        } else if (e.key === 'Escape') {
          e.preventDefault()
          e.stopPropagation()
          finish(null)
        }
      }}
      ref={ref}
      type='text'
      value={value}
    />
  )
}

function TabItem(props: {
  tab: OverviewTab
  active: boolean
  only: boolean
  update: Update
}): React.JSX.Element {
  const { tab, active, only, update } = props
  const [editing, setEditing] = useState(false)
  // Rename... opens the name field after the menu has closed.
  // Else the menu gives the focus back to the tab, and the field loses the focus at once.
  const renameNext = useRef(false)
  const { states, kinds, boxOnly } = tab.filter

  function setFilter(next: { states?: SessionState[]; boxOnly?: boolean }): void {
    update({
      filter: { boxOnly: next.boxOnly ?? boxOnly, kinds, states: next.states ?? states },
      tabId: tab.id,
      type: 'setFilter',
    })
  }

  return (
    <ContextMenu.Root
      onOpenChangeComplete={open => {
        if (open || !renameNext.current) return
        renameNext.current = false
        setEditing(true)
      }}
    >
      <ContextMenu.Trigger
        className={cx(
          'flex shrink-0 items-stretch border-b-2',
          TAB_TEXT[tab.color],
          active ? 'border-current' : 'border-transparent opacity-70 hover:opacity-100',
        )}
        data-tab-id={tab.id}
      >
        {editing ? (
          <TabNameInput
            name={tab.name}
            onDone={name => {
              setEditing(false)
              if (name !== null) update({ name, tabId: tab.id, type: 'renameTab' })
            }}
          />
        ) : (
          <button
            aria-selected={active}
            className='whitespace-nowrap px-2 font-medium text-xs active:bg-accent/12'
            onClick={() => update({ tabId: tab.id, type: 'activate' })}
            role='tab'
            type='button'
          >
            {tab.name}
          </button>
        )}
      </ContextMenu.Trigger>
      <ContextMenu.Portal>
        <ContextMenu.Positioner className='z-50 outline-none'>
          <ContextMenu.Popup className={MENU_POPUP}>
            <ContextMenu.Item
              className={MENU_ITEM}
              onClick={() => {
                renameNext.current = true
              }}
            >
              Rename...
            </ContextMenu.Item>
            <Submenu label='Filter'>
              {STATES.map(state => (
                <CheckItem
                  checked={states.includes(state)}
                  key={state}
                  label={stateLabel(state)}
                  onChange={on =>
                    setFilter({
                      states: STATES.filter(s => (s === state ? on : states.includes(s))),
                    })
                  }
                />
              ))}
              <ContextMenu.Separator className={MENU_SEPARATOR} />
              <CheckItem
                checked={boxOnly}
                label='Only rows with a box'
                onChange={on => setFilter({ boxOnly: on })}
              />
            </Submenu>
            <Submenu label='Columns'>
              {MENU_COLUMNS.map(column => (
                <CheckItem
                  checked={tab.columns.includes(column)}
                  key={column}
                  label={COLUMN_LABELS[column]}
                  onChange={on => {
                    if (on !== tab.columns.includes(column)) {
                      update({ column, tabId: tab.id, type: 'toggleColumn' })
                    }
                  }}
                />
              ))}
            </Submenu>
            <ContextMenu.Item
              className={MENU_ITEM}
              onClick={() => update({ by: -1, tabId: tab.id, type: 'moveTab' })}
            >
              Move left
            </ContextMenu.Item>
            <ContextMenu.Item
              className={MENU_ITEM}
              onClick={() => update({ by: 1, tabId: tab.id, type: 'moveTab' })}
            >
              Move right
            </ContextMenu.Item>
            <ContextMenu.Separator className={MENU_SEPARATOR} />
            <Tip label={only ? REASON_LAST_TAB : null}>
              <ContextMenu.Item
                className={MENU_ITEM}
                disabled={only}
                onClick={() => update({ tabId: tab.id, type: 'removeTab' })}
              >
                Remove tab
              </ContextMenu.Item>
            </Tip>
          </ContextMenu.Popup>
        </ContextMenu.Positioner>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  )
}

// Left-click on a tab activates it. Right-click opens the tab menu.
export default function OverviewTabs({
  config,
  update,
}: {
  config: OverviewConfig
  update: Update
}): React.JSX.Element {
  const full = config.tabs.length >= MAX_TABS
  const only = config.tabs.length <= 1

  return (
    <div className='flex h-[22px] shrink-0 items-stretch pr-1'>
      <div
        className='flex min-w-0 flex-1 items-stretch overflow-x-auto [scrollbar-width:none]'
        role='tablist'
      >
        {config.tabs.map(tab => (
          <TabItem
            active={tab.id === config.active}
            key={tab.id}
            only={only}
            tab={tab}
            update={update}
          />
        ))}
      </div>
      <Tip label={full ? REASON_MAX_TABS : 'Add tab'}>
        <Button
          aria-label='Add tab'
          className='flex w-6 shrink-0 items-center justify-center text-text-dim hover:text-text not-data-disabled:active:bg-accent/12 data-disabled:opacity-40 data-disabled:hover:text-text-dim'
          disabled={full}
          focusableWhenDisabled={true}
          onClick={() => update({ type: 'addTab' })}
        >
          <Plus aria-hidden={true} size={14} />
        </Button>
      </Tip>
    </div>
  )
}
