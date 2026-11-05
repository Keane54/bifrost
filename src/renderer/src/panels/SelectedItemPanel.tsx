// The Selected Item panel (spec 8.4): the data and the buttons of the selected session.
import type { SessionRow } from '../../../shared/types'
import ActionButton from '../actions/ActionButton'
import { SELECTED_ITEM_ACTIONS } from '../actions/action-model'
import { useActions } from '../actions/actions-context'
import { comesIn } from '../actions/reasons'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { Tip } from '../lib/menu'
import { PRIO_TEXT, TONE_TEXT } from '../overview/cells'
import {
  barFill,
  formatCost,
  formatPercent,
  previewLines,
  projectLabel,
  stateLabel,
  stateTone,
} from '../overview/format'
import { SessionIcon } from '../overview/SessionIcon'

const LABEL = 'text-text-dim'

// An empty value shows "-".
function orDash(text: string | undefined): string {
  return text ? text : '-'
}

function Details({ row }: { row: SessionRow }): React.JSX.Element {
  const lines = previewLines(row.lastMessage, 3)
  return (
    <div className='flex min-w-0 select-text flex-col gap-2 p-3 text-xs'>
      {/* 1. The icon, the name, the state and the priority. */}
      <div className='flex min-w-0 items-center gap-2'>
        <SessionIcon row={row} size={22} />
        <span className='min-w-0 truncate font-semibold text-[13px]'>{row.name}</span>
        <span className={cx('shrink-0', TONE_TEXT[stateTone(row)])}>{stateLabel(row.state)}</span>
        <span
          className={cx('shrink-0', row.priority ? PRIO_TEXT[row.priority] : 'text-text-dim')}
          title='Priority'
        >
          {row.priority ?? '-'}
        </span>
      </div>
      {/* 2. The action buttons. */}
      <div className='flex gap-1' data-selected-actions={true}>
        {SELECTED_ITEM_ACTIONS.map(id => (
          <ActionButton action={id} key={id} sessionId={row.sessionId} />
        ))}
      </div>
      {/* 3. The project, the branch and the model. */}
      <dl className='grid min-w-0 grid-cols-[auto_1fr] gap-x-3 gap-y-0.5'>
        <dt className={LABEL}>Project</dt>
        <dd className='truncate' title={row.cwd}>
          {orDash(projectLabel(row.cwd))}
        </dd>
        <dt className={LABEL}>Branch</dt>
        <dd className='truncate'>{orDash(row.branch)}</dd>
        <dt className={LABEL}>Model</dt>
        <dd className='truncate'>{orDash(row.model)}</dd>
      </dl>
      {/* 4. The context bar, the context percent and the cost. */}
      <div className='flex items-center gap-2'>
        <div aria-hidden={true} className='h-1 min-w-0 flex-1 bg-panel-edge'>
          <div
            className='h-full bg-text-strong'
            style={{ width: `${barFill(row.contextPercent)}%` }}
          />
        </div>
        <span className='shrink-0' title='Context'>
          {orDash(formatPercent(row.contextPercent))}
        </span>
        <span className='shrink-0' title='Cost'>
          {orDash(formatCost(row.costUsd))}
        </span>
      </div>
      {/* 5. The first lines of the last reply. Each line is cut off. It does not wrap. */}
      {lines.length > 0 && (
        <p className='overflow-hidden text-ellipsis whitespace-pre text-text-dim'>
          {lines.join('\n')}
        </p>
      )}
      {/* 6. The send box comes in M4. The field ignores the pointer.
          The wrapper gets the pointer and shows the tooltip. */}
      <Tip label={comesIn(4)}>
        <div className='flex' data-send-box={true}>
          <textarea
            aria-label='Send message'
            className='pointer-events-none min-w-0 flex-1 resize-none rounded border border-panel-edge bg-bg px-2 py-1 text-text opacity-40'
            disabled={true}
            placeholder='Send message'
            rows={3}
          />
        </div>
      </Tip>
    </div>
  )
}

export default function SelectedItemPanel(): React.JSX.Element {
  const { rows, selectedId } = useRegistry()
  const { error } = useActions()
  const row = selectedId === null ? undefined : rows.find(r => r.sessionId === selectedId)

  return (
    // The frame content area scrolls. The panel is at least as high as the area.
    // So the error line is at the bottom.
    <div className='flex min-h-full min-w-0 flex-col' data-selected-item={row?.sessionId ?? ''}>
      <div className='flex-1'>
        {row ? (
          <Details row={row} />
        ) : (
          <p className='p-3 text-[13px] text-text-dim'>No session selected.</p>
        )}
      </div>
      <ErrorLine message={error} />
    </div>
  )
}
