// The Selected Item panel (spec 8.4): the data and the buttons of the selected session.
import { CircleAlert, Info } from 'lucide-react'
import { useCallback, useState } from 'react'
import { aliasTip } from '../../../shared/alias'
import type { SessionRow } from '../../../shared/types'
import ActionButton from '../actions/ActionButton'
import { SELECTED_ITEM_ACTIONS } from '../actions/action-model'
import { useActions } from '../actions/actions-context'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { ErrorLine, NoticeLine } from '../lib/ErrorLine'
import { Tip } from '../lib/menu'
import { PRIO_TEXT, TONE_TEXT } from '../overview/cells'
import {
  barFill,
  type ContextBand,
  formatCost,
  formatPercent,
  projectLabel,
  shownContextBand,
  stateLabel,
  stateTone,
} from '../overview/format'
import { SessionIcon } from '../overview/SessionIcon'
import SendBox, { type SendLine } from './SendBox'
import { statusTexts } from './status-texts'

const LABEL = 'text-text-dim'

// The fill colour of each band. The class names stay whole, so Tailwind finds them.
const BAND_FILL: Record<ContextBand, string> = {
  high: 'bg-ctx-high',
  low: 'bg-ctx-low',
  mid: 'bg-ctx-mid',
}

// An empty value shows "-".
function orDash(text: string | undefined): string {
  return text ? text : '-'
}

// The status icon button. A click on the error icon closes the errors.
const STATUS_BUTTON =
  'flex size-4 shrink-0 items-center justify-center hover:bg-hover active:bg-accent/12'

function Details({ row }: { row: SessionRow }): React.JSX.Element {
  const { closeError, error, notice } = useActions()
  const [sendLine, setSendLine] = useState<SendLine | null>(null)
  const onLine = useCallback((line: SendLine | null) => setSendLine(line), [])
  const { kind, lines } = statusTexts({
    error,
    notice,
    sendFailed: sendLine?.failed ?? false,
    sendLine: sendLine?.text ?? null,
  })
  const statusText = lines.join('\n')
  const percent = formatPercent(row.contextPercent)
  const band = shownContextBand(row.contextPercent)
  return (
    <div className='flex min-w-0 select-text flex-col gap-2 p-3 text-xs'>
      {/* 1. The icon, the name, the state and the priority. */}
      <div className='flex min-w-0 items-center gap-2'>
        <SessionIcon row={row} size={22} />
        <span className='min-w-0 truncate font-semibold text-[13px]' title={aliasTip(row)}>
          {row.name}
        </span>
        <span className={cx('shrink-0', TONE_TEXT[stateTone(row)])}>{stateLabel(row.state)}</span>
        {/* A row with no priority shows nothing here. */}
        {row.priority && (
          <span className={cx('shrink-0', PRIO_TEXT[row.priority])} title='Priority'>
            {row.priority}
          </span>
        )}
        {/* The status icon shows only when a text exists. The tooltip shows all texts. */}
        {kind !== null && (
          <Tip label={statusText}>
            <button
              aria-label={statusText}
              className={cx(STATUS_BUTTON, kind === 'error' ? 'text-text-strong' : 'text-text-dim')}
              data-status-icon={kind}
              onClick={() => {
                if (kind !== 'error') return
                closeError()
                sendLine?.clearFailure()
              }}
              type='button'
            >
              {kind === 'error' ? (
                <CircleAlert aria-hidden={true} size={14} />
              ) : (
                <Info aria-hidden={true} size={14} />
              )}
            </button>
          </Tip>
        )}
        {/* A screen reader hears an error or a notice here. */}
        <span aria-live='polite' className='sr-only' data-status-live={true}>
          {statusText}
        </span>
      </div>
      {/* 2. The action buttons. */}
      <div className='flex gap-1' data-selected-actions={true}>
        {SELECTED_ITEM_ACTIONS.map(id => (
          <ActionButton action={id} key={id} sessionId={row.sessionId} />
        ))}
        {/* A watched row gets the Remove button. Any other row gets the Add button. */}
        <ActionButton action={row.watch ? 'watch-remove' : 'watch-add'} sessionId={row.sessionId} />
      </div>
      {/* 3. The project, the branch, the model with its context bar, and the cost. */}
      <dl className='grid min-w-0 grid-cols-[auto_1fr] gap-x-3 gap-y-0.5'>
        <dt className={LABEL}>Project</dt>
        <dd className='truncate' title={row.cwd}>
          {orDash(projectLabel(row.cwd))}
        </dd>
        <dt className={LABEL}>Branch</dt>
        <dd className='truncate'>{orDash(row.branch)}</dd>
        <dt className={LABEL}>Model</dt>
        <dd className='flex min-w-0 items-center gap-2'>
          {/* The model name keeps its width. It is cut off only when the row is too narrow. */}
          <span className='min-w-0 truncate' title={row.model}>
            {orDash(row.model)}
          </span>
          {/* The bar takes the free width. With no percent, the bar is empty. */}
          <div className='h-1 min-w-8 flex-1 bg-panel-edge' title='Context'>
            <div
              className={cx('h-full', band ? BAND_FILL[band] : 'bg-text-strong')}
              style={{ width: `${barFill(row.contextPercent)}%` }}
            />
          </div>
          <span className='shrink-0 whitespace-nowrap' title='Context'>
            {percent ? `${percent} context` : '-'}
          </span>
        </dd>
        <dt className={LABEL}>Cost</dt>
        <dd className='truncate'>{orDash(formatCost(row.costUsd))}</dd>
      </dl>
      {/* 4. The send box. */}
      <SendBox onLine={onLine} row={row} />
    </div>
  )
}

// With no selected session, the notice line and the error line show at the bottom.
function NoSelection(): React.JSX.Element {
  const { closeError, error, notice } = useActions()
  return (
    <>
      <div className='flex-1'>
        <p className='p-3 text-[13px] text-text-dim'>No session selected.</p>
      </div>
      <NoticeLine message={notice} />
      <ErrorLine message={error} onClose={closeError} />
    </>
  )
}

export default function SelectedItemPanel(): React.JSX.Element {
  const { rows, selectedId } = useRegistry()
  const row = selectedId === null ? undefined : rows.find(r => r.sessionId === selectedId)

  return (
    // The frame content area scrolls. The panel is at least as high as the area.
    // So the notice line and the error line are at the bottom.
    <div className='flex min-h-full min-w-0 flex-col' data-selected-item={row?.sessionId ?? ''}>
      {row ? (
        <div className='flex-1'>
          <Details row={row} />
        </div>
      ) : (
        <NoSelection />
      )}
    </div>
  )
}
