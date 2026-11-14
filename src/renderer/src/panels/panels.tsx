// The title and the content of each panel kind.
import type { ModuleRow } from '../../../shared/modules'
import type { SessionRow } from '../../../shared/types'
import ChatPanel from '../chat/ChatPanel'
import { chatSessionId } from '../chat/views'
import DailyUpdatePanel from '../daily-update/DailyUpdatePanel'
import { useRegistry } from '../data/registry'
import EventLogPanel from '../events/EventLogPanel'
import ShowInfoPanel from '../info/ShowInfoPanel'
import { showInfoSessionId } from '../info/show-info'
import { cx } from '../lib/cx'
import HeimdallPanel, { heimdallTitle } from '../modules/HeimdallPanel'
import { useHeimdallRequest } from '../modules/heimdall-key'
import ModulePanel, { ModulePanelTitle } from '../modules/ModulePanel'
import { modulePanelLabel, modulePanelOf } from '../modules/module-panels'
import { useModules } from '../modules/use-modules'
import { PRIO_TEXT, TONE_TEXT } from '../overview/cells'
import { stateLabel, stateTone } from '../overview/format'
import OverviewPanel from '../overview/OverviewPanel'
import OverviewSettingsPanel from '../overview/OverviewSettingsPanel'
import { useOverview } from '../overview/overviews-context'
import { SessionIcon } from '../overview/SessionIcon'
import PerformancePanel from '../performance/PerformancePanel'
import AnswerPanel from '../reviews/AnswerPanel'
import ReviewPanel, { ReviewTitle } from '../reviews/ReviewPanel'
import ReviewsPanel from '../reviews/ReviewsPanel'
import TrustPanel from '../reviews/TrustPanel'
import ServiceStatusPanel from '../service/ServiceStatusPanel'
import SettingsPanel from '../settings/SettingsPanel'
import UsagePanel from '../usage/UsagePanel'
import WatchlistPanel from '../watch/WatchlistPanel'
import { panelKind } from '../wm/state'
import SelectedItemPanel from './SelectedItemPanel'

// The title as plain text. A chat panel with a row gives the name of the row. A module panel gives
// the title of its manifest and the module name, also while the module is off.
export function panelTitle(
  panelId: string,
  rows?: SessionRow[],
  modules?: readonly ModuleRow[],
): string {
  switch (panelKind(panelId)) {
    case 'overview': {
      const n = panelId.slice('overview:'.length)
      return n === '1' ? 'Overview' : `Overview ${n}`
    }
    case 'overview-settings': {
      const n = panelId.slice('overview-settings:'.length)
      return n === '1' ? 'Overview Settings' : `Overview ${n} Settings`
    }
    case 'selected-item':
      return 'Selected Item'
    case 'settings':
      return 'Settings'
    case 'watchlist':
      return 'Watchlist'
    case 'chat': {
      const id = chatSessionId(panelId)
      return rows?.find(r => r.sessionId === id)?.name ?? 'Chat'
    }
    case 'event-log':
      return 'Event log'
    case 'usage-hud':
      return 'Usage HUD'
    case 'service-status':
      return 'Service status'
    case 'reviews':
      return 'Reviews'
    case 'performance':
      return 'Performance'
    case 'daily-update':
      return 'Daily update'
    case 'trust':
      return 'Trust a repository'
    case 'answer':
      return 'Answer Claude'
    case 'review-draft':
      return 'Review'
    case 'show-info': {
      const id = showInfoSessionId(panelId)
      const name = rows?.find(r => r.sessionId === id)?.name
      return name === undefined ? 'Show Info' : `Show Info: ${name}`
    }
    case 'module': {
      const found = modulePanelOf(modules ?? [], panelId)
      return found ? modulePanelLabel(found.row, found.panel) : 'Module'
    }
    case 'heimdall':
      return 'Heimdall'
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

// A chat title shows the session icon, a state dot, the name and the priority (spec 8.5).
// The dot has the tone of the State column of the Overview. The name has no colour of its own.
// So it follows the tab rule of the frame: white in the active tab, dim in another tab.
function ChatTitle({ panelId }: { panelId: string }): React.JSX.Element {
  const { rows } = useRegistry()
  const id = chatSessionId(panelId)
  const row = rows.find(r => r.sessionId === id)
  return (
    <span className='inline-flex max-w-full items-center gap-1.5'>
      {row && <SessionIcon row={row} size={16} />}
      {row && (
        <span
          className={cx('size-1.5 shrink-0 bg-current', TONE_TEXT[stateTone(row)])}
          data-state-dot={row.state}
          title={stateLabel(row.state)}
        />
      )}
      <span className='min-w-0 truncate'>{panelTitle(panelId, rows)}</span>
      {row?.priority && (
        <span className={cx('shrink-0', PRIO_TEXT[row.priority])}>{row.priority}</span>
      )}
    </span>
  )
}

// The Show Info title follows the name of the row.
function ShowInfoTitle({ panelId }: { panelId: string }): React.JSX.Element {
  const { rows } = useRegistry()
  return <>{panelTitle(panelId, rows)}</>
}

// The module title follows the rows of the modules.
function ModuleTitle({ panelId }: { panelId: string }): React.JSX.Element {
  const { modules } = useModules()
  return <ModulePanelTitle modules={modules} panelId={panelId} />
}

// Heimdall's title: its name in purple, then the module of the request. Only Bifrost writes it.
function HeimdallTitle(): React.JSX.Element {
  const request = useHeimdallRequest()
  return (
    <span className={cx('inline-flex max-w-full min-w-0 items-center')}>
      <span className={cx('shrink-0 text-heimdall')}>◆ Heimdall</span>
      {request !== null && (
        <span className={cx('min-w-0 truncate')}>{` · ${heimdallTitle(request)}`}</span>
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
    case 'show-info':
      return <ShowInfoTitle panelId={panelId} />
    case 'review-draft':
      return <ReviewTitle />
    case 'module':
      return <ModuleTitle panelId={panelId} />
    case 'heimdall':
      return <HeimdallTitle />
    default:
      return <>{panelTitle(panelId)}</>
  }
}

// The content area of the frame scrolls, except for a chat panel. Its terminal fills the area.
export function panelScrolls(panelId: string): boolean {
  // The Event log has its own scroll area for the virtual list. The frame of a module panel fills
  // the area, and the module page scrolls in its frame.
  const kind = panelKind(panelId)
  return kind !== 'chat' && kind !== 'event-log' && kind !== 'module'
}

export function PanelContent({ panelId }: { panelId: string }): React.JSX.Element {
  switch (panelKind(panelId)) {
    case 'overview':
      return <OverviewPanel panelId={panelId} />
    case 'overview-settings':
      return <OverviewSettingsPanel panelId={panelId} />
    case 'selected-item':
      return <SelectedItemPanel />
    case 'settings':
      return <SettingsPanel />
    case 'watchlist':
      return <WatchlistPanel />
    case 'chat':
      return <ChatPanel panelId={panelId} />
    case 'show-info':
      return <ShowInfoPanel panelId={panelId} />
    case 'event-log':
      return <EventLogPanel />
    case 'usage-hud':
      return <UsagePanel />
    case 'service-status':
      return <ServiceStatusPanel />
    case 'reviews':
      return <ReviewsPanel />
    case 'performance':
      return <PerformancePanel />
    case 'daily-update':
      return <DailyUpdatePanel />
    case 'trust':
      return <TrustPanel />
    case 'answer':
      return <AnswerPanel />
    case 'review-draft':
      return <ReviewPanel />
    case 'module':
      return <ModulePanel panelId={panelId} />
    case 'heimdall':
      return <HeimdallPanel />
    default:
      return <div className='p-3 text-[13px] text-text-dim'>This panel is not known.</div>
  }
}
