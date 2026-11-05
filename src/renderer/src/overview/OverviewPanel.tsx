// The Overview panel (spec 8.3): the tab row, then the header and the rows of the active tab.
import { useActions } from '../actions/actions-context'
import { useRegistry } from '../data/registry'
import { ErrorLine } from '../lib/ErrorLine'
import { activeTab } from './config'
import OverviewTable from './OverviewTable'
import OverviewTabs from './OverviewTabs'
import { useOverview } from './overviews-context'

// A change of the actions value renders only this component.
function ActionError(): React.JSX.Element {
  return <ErrorLine message={useActions().error} />
}

export default function OverviewPanel({ panelId }: { panelId: string }): React.JSX.Element {
  const { config, update } = useOverview(panelId)
  const { error } = useRegistry()

  return (
    <div className='flex h-full min-w-0 select-none flex-col' data-overview-id={panelId}>
      <OverviewTabs config={config} update={update} />
      <OverviewTable tab={activeTab(config)} update={update} />
      {/* An error of an action, and an error of the session list. */}
      <ActionError />
      <ErrorLine message={error} />
    </div>
  )
}
