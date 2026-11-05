// The title and the content of each panel kind.
import { panelKind } from '../wm/state'
import IntegrationPanel from './IntegrationPanel'
import SelectedItemPanel from './SelectedItemPanel'
import SessionsPanel from './SessionsPanel'

export function panelTitle(panelId: string): string {
  switch (panelKind(panelId)) {
    case 'overview': {
      const n = panelId.slice('overview:'.length)
      return n === '1' ? 'Overview' : `Overview ${n}`
    }
    case 'selected-item':
      return 'Selected Item'
    case 'integration':
      return 'Integration'
    case 'chat':
      return 'Chat'
    default:
      return panelId
  }
}

export function PanelContent({ panelId }: { panelId: string }): React.JSX.Element {
  switch (panelKind(panelId)) {
    case 'overview':
      return <SessionsPanel />
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
