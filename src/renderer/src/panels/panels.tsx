// The title and the content of each panel kind.
import type { SessionRow } from '../../../shared/types'
import { chatSessionId } from '../chat/views'
import { useRegistry } from '../data/registry'
import OverviewPanel from '../overview/OverviewPanel'
import { useOverview } from '../overview/overviews-context'
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

function ChatTitle({ panelId }: { panelId: string }): React.JSX.Element {
  const { rows } = useRegistry()
  return <>{panelTitle(panelId, rows)}</>
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

export function PanelContent({ panelId }: { panelId: string }): React.JSX.Element {
  switch (panelKind(panelId)) {
    case 'overview':
      return <OverviewPanel panelId={panelId} />
    case 'selected-item':
      return <SelectedItemPanel />
    case 'integration':
      return <IntegrationPanel />
    case 'chat':
      return <div className='p-3 text-[13px] text-text-dim'>Chat windows come in M3.</div>
    default:
      return <div className='p-3 text-[13px] text-text-dim'>This panel is not known.</div>
  }
}
