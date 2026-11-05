// The title and the content of each panel kind.
import type { SessionRow } from '../../../shared/types'
import ChatPanel from '../chat/ChatPanel'
import { chatSessionId } from '../chat/views'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { PRIO_TEXT, TONE_TEXT } from '../overview/cells'
import { stateTone } from '../overview/format'
import OverviewPanel from '../overview/OverviewPanel'
import { useOverview } from '../overview/overviews-context'
import { SessionIcon } from '../overview/SessionIcon'
import { panelKind } from '../wm/state'
import IntegrationPanel from './IntegrationPanel'
import SelectedItemPanel from './SelectedItemPanel'

// The title as plain text. A chat panel with a row gives the name of the row.
export function panelTitle(panelId: string, rows?: SessionRow[]): string {
  switch (panelKind(panelId)) {
    case 'overview': {
      const n = panelId.slice('overview:'.length)
      return n === '1' ? 'Overview' : `Overview ${n}`
    }
    case 'selected-item':
      return 'Selected Item'
    case 'integration':
      return 'Integration'
    case 'chat': {
      const id = chatSessionId(panelId)
      return rows?.find(r => r.sessionId === id)?.name ?? 'Chat'
    }
    default:
      return panelId
  }
}

// An Overview title also shows the name of its tab set.
function OverviewTitle({ panelId }: { panelId: string }): React.JSX.Element {
  const { config } = useOverview(panelId)
  return (
    <>
      {panelTitle(panelId)}
      <span className='text-text-dim'> ({config.name})</span>
    </>
  )
}

// A chat title shows the session icon, the name in the state colour and the priority (spec 8.5).
// The state colour is the tone of the State column of the Overview.
function ChatTitle({ panelId }: { panelId: string }): React.JSX.Element {
  const { rows } = useRegistry()
  const id = chatSessionId(panelId)
  const row = rows.find(r => r.sessionId === id)
  return (
    <span className='inline-flex max-w-full items-center gap-1.5'>
      {row && <SessionIcon row={row} size={16} />}
      <span className={cx('min-w-0 truncate', row && TONE_TEXT[stateTone(row)])}>
        {panelTitle(panelId, rows)}
      </span>
      {row?.priority && (
        <span className={cx('shrink-0', PRIO_TEXT[row.priority])}>{row.priority}</span>
      )}
    </span>
  )
}

// The title content with live data. It renders when its data changes, not with its frame.
export function PanelTitle({ panelId }: { panelId: string }): React.JSX.Element {
  switch (panelKind(panelId)) {
    case 'overview':
      return <OverviewTitle panelId={panelId} />
    case 'chat':
      return <ChatTitle panelId={panelId} />
    default:
      return <>{panelTitle(panelId)}</>
  }
}

// The content area of the frame scrolls, except for a chat panel. Its terminal fills the area.
export function panelScrolls(panelId: string): boolean {
  return panelKind(panelId) !== 'chat'
}

export function PanelContent({ panelId }: { panelId: string }): React.JSX.Element {
  switch (panelKind(panelId)) {
    case 'overview':
      return <OverviewPanel panelId={panelId} />
    case 'selected-item':
      return <SelectedItemPanel />
    case 'integration':
      return <IntegrationPanel />
    case 'chat':
      return <ChatPanel panelId={panelId} />
    default:
      return <div className='p-3 text-[13px] text-text-dim'>This panel is not known.</div>
  }
}
