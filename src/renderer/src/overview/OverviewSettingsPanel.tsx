// The Overview Settings panel (spec 8.3). It edits the tabs of one Overview.
// The selector at the top is the active tab of the Overview. So the Overview shows each change
// at once.
// Columns: a checkbox for each column. Drag a row up or down to change the column order. The top
// row is the leftmost column.
// Filters: checkboxes for the states, the kinds and the boxes that the tab shows.
import { Button } from '@base-ui/react/button'
import { Checkbox } from '@base-ui/react/checkbox'
import { Select } from '@base-ui/react/select'
import { Check, ChevronDown, GripVertical } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import type { SessionKind } from '../../../shared/types'
import { REASON_DEFAULT_TAB, REASON_KIND_COLUMN } from '../actions/reasons'
import { cx } from '../lib/cx'
import { MENU_ITEM, MENU_POPUP, Tip } from '../lib/menu'
import { movedToStack } from '../wm/hit'
import { settingsOverviewId } from '../wm/state'
import { TAB_TEXT } from './cells'
import { type ColumnId, isColumnId } from './columns'
import { activeTab, KINDS, type OverviewConfig, type OverviewTab, STATES } from './config'
import { stateLabel } from './format'
import { useOverview } from './overviews-context'
import {
  columnRows,
  dropTarget,
  moveColumn,
  resetTab,
  setBoxOnly,
  showKind,
  showState,
  toggleColumn,
} from './settings-model'

type Edit = (change: (config: OverviewConfig) => OverviewConfig) => void
type Page = 'columns' | 'filters'

const PAGES: { id: Page; label: string }[] = [
  { id: 'columns', label: 'Columns' },
  { id: 'filters', label: 'Filters' },
]

const KIND_LABELS: Record<SessionKind, string> = { external: 'External', owned: 'Owned' }

// The checkbox is the box and its name. A click on the name also changes the box.
// The box is small and dark, with a check mark. A disabled box is faded (spec 9.1).
const CHECKBOX =
  'group flex min-w-0 flex-1 items-center gap-2 outline-none not-data-disabled:active:bg-accent/12'
const BOX =
  'flex size-3.5 shrink-0 items-center justify-center border border-text-dim bg-bg text-text-strong group-focus-visible:outline-1 group-focus-visible:outline-text-strong group-data-checked:border-text group-data-disabled:opacity-40'

function CheckBox(props: {
  checked: boolean
  disabled?: boolean
  label: string
  onChange(checked: boolean): void
}): React.JSX.Element {
  return (
    <Checkbox.Root
      checked={props.checked}
      className={CHECKBOX}
      disabled={props.disabled}
      onCheckedChange={checked => props.onChange(checked)}
    >
      <span className={BOX}>
        <Checkbox.Indicator className='flex data-unchecked:hidden'>
          <Check aria-hidden={true} size={10} strokeWidth={3} />
        </Checkbox.Indicator>
      </span>
      <span className='truncate'>{props.label}</span>
    </Checkbox.Root>
  )
}

// The rows of the list in screen order, and the row under the pointer with the half of that row.
// A pointer above the list is on the upper half of the first row. A pointer below the list is on
// the lower half of the last row.
function placeAt(
  list: HTMLElement | null,
  y: number,
): { order: ColumnId[]; overIndex: number; upperHalf: boolean } {
  const items = Array.from(list?.querySelectorAll<HTMLElement>('[data-column-id]') ?? [])
  const order: ColumnId[] = []
  let overIndex = 0
  let upperHalf = true
  for (const item of items) {
    const id = item.dataset.columnId
    if (!isColumnId(id)) continue
    const box = item.getBoundingClientRect()
    if (y >= box.top) {
      overIndex = order.length
      upperHalf = y < box.top + box.height / 2
    }
    order.push(id)
  }
  return { order, overIndex, upperHalf }
}

// The dragged row and the column that it goes before. Null means the end of the list.
interface DropMark {
  id: ColumnId
  before: ColumnId | null
}

// A drag starts after the pointer moves 4 px, as a frame drag does (M2). So a click on a row
// changes only its box. The order changes on the release. A line shows the drop place.
// The row captures the pointer when the drag starts, as a tab of a stack does for a tear-out.
// A cancel or a lost capture ends the drag with no change.
function ColumnList({
  config,
  tab,
  edit,
}: {
  config: OverviewConfig
  tab: OverviewTab
  edit: Edit
}): React.JSX.Element {
  const rows = columnRows(config, tab.id)
  const list = useRef<HTMLUListElement>(null)
  // Removes the window listeners of the current drag.
  const stop = useRef<(() => void) | null>(null)
  // True from the release of a drag until the click of that release has gone.
  // That click does not change a box.
  const noClick = useRef(false)
  const [mark, setMark] = useState<DropMark | null>(null)

  useEffect(() => () => stop.current?.(), [])

  function targetAt(id: ColumnId, y: number): ColumnId | null {
    const { order, overIndex, upperHalf } = placeAt(list.current, y)
    return dropTarget(order, id, overIndex, upperHalf)
  }

  function startDrag(e: React.PointerEvent<HTMLElement>, id: ColumnId): void {
    if (e.button !== 0 || id === 'kind') return
    stop.current?.()
    const element = e.currentTarget
    const { pointerId } = e
    const tabId = tab.id
    const start = { x: e.clientX, y: e.clientY }
    let started = false
    const onMove = (ev: PointerEvent): void => {
      if (ev.pointerId !== pointerId) return
      if (!started) {
        if (!movedToStack(start, { x: ev.clientX, y: ev.clientY })) return
        started = true
        try {
          element.setPointerCapture(pointerId)
        } catch {
          // Without the capture, the window listeners still get the pointer events.
        }
      }
      const before = targetAt(id, ev.clientY)
      setMark(prev => (prev?.id === id && prev.before === before ? prev : { before, id }))
    }
    const onUp = (ev: PointerEvent): void => {
      if (ev.pointerId !== pointerId) return
      end()
      if (!started) return
      noClick.current = true
      window.setTimeout(() => {
        noClick.current = false
      }, 0)
      const before = targetAt(id, ev.clientY)
      edit(c => moveColumn(c, tabId, id, before))
    }
    const onCancel = (ev: PointerEvent): void => {
      if (ev.pointerId === pointerId) end()
    }
    const end = (): void => {
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerup', onUp)
      window.removeEventListener('pointercancel', onCancel)
      window.removeEventListener('lostpointercapture', onCancel)
      if (element.hasPointerCapture(pointerId)) element.releasePointerCapture(pointerId)
      stop.current = null
      setMark(null)
    }
    window.addEventListener('pointermove', onMove)
    window.addEventListener('pointerup', onUp)
    window.addEventListener('pointercancel', onCancel)
    window.addEventListener('lostpointercapture', onCancel)
    stop.current = end
  }

  // A drop that does not change the order shows no line.
  const moves = mark !== null && moveColumn(config, tab.id, mark.id, mark.before) !== config
  const last = rows.at(-1)?.id

  return (
    <ul
      aria-label='Columns'
      className='py-1'
      onClickCapture={e => {
        if (!noClick.current) return
        e.preventDefault()
        e.stopPropagation()
      }}
      ref={list}
    >
      {rows.map(row => {
        const lineAbove = moves && mark?.before === row.id
        const lineBelow = moves && mark?.before === null && row.id === last
        const item = (
          <li
            className={cx(
              'relative flex h-[22px] items-center gap-2 px-2',
              !row.locked && 'hover:bg-hover',
              mark?.id === row.id && 'opacity-40',
            )}
            data-column-id={row.id}
            key={row.id}
            onPointerDown={e => startDrag(e, row.id)}
          >
            <CheckBox
              checked={row.visible}
              disabled={row.locked}
              label={row.label}
              onChange={on => {
                if (on !== row.visible) edit(c => toggleColumn(c, tab.id, row.id))
              }}
            />
            {/* The kind row cannot move. So it has no drag handle. */}
            {!row.locked && (
              <GripVertical
                aria-hidden={true}
                className='shrink-0 cursor-grab text-text-dim'
                size={12}
              />
            )}
            {(lineAbove || lineBelow) && (
              <span
                aria-hidden={true}
                className={cx(
                  'pointer-events-none absolute inset-x-1 h-px bg-text-strong',
                  lineAbove ? 'top-0' : 'bottom-0',
                )}
              />
            )}
          </li>
        )
        return row.locked ? (
          <Tip key={row.id} label={REASON_KIND_COLUMN}>
            {item}
          </Tip>
        ) : (
          item
        )
      })}
    </ul>
  )
}

function Group({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className='py-1'>
      <h3 className='px-2 pb-0.5 font-normal text-[11px] text-text-dim'>{title}</h3>
      <ul>{children}</ul>
    </section>
  )
}

function FilterRow({ children }: { children: React.ReactNode }) {
  return <li className='flex h-[22px] items-center px-2 hover:bg-hover'>{children}</li>
}

// The "Watched only" box comes with the Watchlist in M4.
function FilterList({ tab, edit }: { tab: OverviewTab; edit: Edit }): React.JSX.Element {
  const { states, kinds, boxOnly } = tab.filter
  return (
    <div className='py-1'>
      <Group title='States'>
        {STATES.map(state => (
          <FilterRow key={state}>
            <CheckBox
              checked={states.includes(state)}
              label={stateLabel(state)}
              onChange={on => edit(c => showState(c, tab.id, state, on))}
            />
          </FilterRow>
        ))}
      </Group>
      <Group title='Kinds'>
        {KINDS.map(kind => (
          <FilterRow key={kind}>
            <CheckBox
              checked={kinds.includes(kind)}
              label={KIND_LABELS[kind]}
              onChange={on => edit(c => showKind(c, tab.id, kind, on))}
            />
          </FilterRow>
        ))}
      </Group>
      <Group title='Boxes'>
        <FilterRow>
          <CheckBox
            checked={boxOnly}
            label='Only rows with a box'
            onChange={on => edit(c => setBoxOnly(c, tab.id, on))}
          />
        </FilterRow>
      </Group>
    </div>
  )
}

// The tab that the panel edits. A choice here also activates the tab in the Overview.
function TabSelect({
  config,
  tab,
  onChoose,
}: {
  config: OverviewConfig
  tab: OverviewTab
  onChoose(tabId: string): void
}): React.JSX.Element {
  const items = config.tabs.map(t => ({ label: t.name, value: t.id }))
  return (
    <Select.Root
      items={items}
      onValueChange={value => {
        if (typeof value === 'string') onChoose(value)
      }}
      value={tab.id}
    >
      <Select.Trigger
        aria-label='Tab'
        className='flex h-6 min-w-0 flex-1 items-center justify-between gap-2 border border-panel-edge bg-bg px-2 text-xs outline-none hover:border-text-strong/30 focus-visible:border-text-strong/30 active:bg-accent/12 data-popup-open:border-text-strong/30'
      >
        <Select.Value className={cx('truncate', TAB_TEXT[tab.color])} />
        <Select.Icon className='flex text-text-dim'>
          <ChevronDown aria-hidden={true} size={12} />
        </Select.Icon>
      </Select.Trigger>
      <Select.Portal>
        <Select.Positioner
          alignItemWithTrigger={false}
          className='z-50 outline-none'
          sideOffset={4}
        >
          <Select.Popup className={cx(MENU_POPUP, 'min-w-(--anchor-width)')}>
            <Select.List className='max-h-(--available-height) overflow-y-auto'>
              {config.tabs.map(t => (
                <Select.Item className={cx(MENU_ITEM, TAB_TEXT[t.color])} key={t.id} value={t.id}>
                  <span className='flex w-3 shrink-0 justify-center'>
                    <Select.ItemIndicator>
                      <Check aria-hidden={true} size={12} />
                    </Select.ItemIndicator>
                  </span>
                  <Select.ItemText>{t.name}</Select.ItemText>
                </Select.Item>
              ))}
            </Select.List>
          </Select.Popup>
        </Select.Positioner>
      </Select.Portal>
    </Select.Root>
  )
}

export default function OverviewSettingsPanel({ panelId }: { panelId: string }): React.JSX.Element {
  const overviewId = settingsOverviewId(panelId)
  const { config, edit, update } = useOverview(overviewId)
  const [page, setPage] = useState<Page>('columns')
  const tab = activeTab(config)
  // Reset has no effect on a tab with the default columns and filter.
  const isDefault = resetTab(config, tab.id) === config

  return (
    <div
      className='flex min-h-full select-none flex-col text-text text-xs'
      data-overview-settings={overviewId}
    >
      <div className='flex items-center gap-2 px-2 pt-2 pb-1'>
        <span className='text-text-dim'>Tab</span>
        <TabSelect
          config={config}
          onChoose={tabId => update({ tabId, type: 'activate' })}
          tab={tab}
        />
      </div>
      <div className='flex border-panel-edge border-b px-1' role='tablist'>
        {PAGES.map(p => (
          <button
            aria-selected={p.id === page}
            className={cx(
              'border-b-2 px-2 py-1 text-xs active:bg-accent/12',
              p.id === page
                ? 'border-text-strong text-text-strong'
                : 'border-transparent text-text-dim hover:text-text',
            )}
            key={p.id}
            onClick={() => setPage(p.id)}
            role='tab'
            type='button'
          >
            {p.label}
          </button>
        ))}
      </div>
      <div className='flex-1'>
        {page === 'columns' ? (
          <ColumnList config={config} edit={edit} tab={tab} />
        ) : (
          <FilterList edit={edit} tab={tab} />
        )}
      </div>
      <div className='flex justify-end border-panel-edge border-t p-2'>
        <Tip label={isDefault ? REASON_DEFAULT_TAB : null}>
          <Button
            className='border border-panel-edge px-2 py-0.5 text-text hover:bg-hover not-data-disabled:active:bg-accent/12 data-disabled:opacity-40 data-disabled:hover:bg-transparent'
            disabled={isDefault}
            focusableWhenDisabled={true}
            onClick={() => edit(c => resetTab(c, tab.id))}
          >
            Reset to default
          </Button>
        </Tip>
      </div>
    </div>
  )
}
