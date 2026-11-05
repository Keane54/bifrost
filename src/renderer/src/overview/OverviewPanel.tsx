// The Overview panel (spec 8.3): the tab row, then the header and the rows of the active tab.
import { useRegistry } from '../data/registry'
import { activeTab } from './config'
import OverviewTable from './OverviewTable'
import OverviewTabs from './OverviewTabs'
import { useOverview } from './overviews-context'

export default function OverviewPanel({ panelId }: { panelId: string }): React.JSX.Element {
  const { config, update } = useOverview(panelId)
  const { error } = useRegistry()

  return (
    <div className='flex h-full min-w-0 select-none flex-col' data-overview-id={panelId}>
      <OverviewTabs config={config} update={update} />
      <OverviewTable tab={activeTab(config)} update={update} />
      {/* An error of the session list. Red is only for the red box (spec 8.10). */}
      {error && (
        <p
          className='shrink-0 truncate border-panel-edge border-t px-2 text-text text-xs'
          title={error}
        >
          Error: {error}
        </p>
      )}
    </div>
  )
}
