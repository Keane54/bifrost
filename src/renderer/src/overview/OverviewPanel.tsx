// The Overview panel (spec 8.3): the tab row, then the header and the rows of the active tab.
import { useActions } from '../actions/actions-context'
import { friendlyError } from '../actions/errors'
import { useRegistry } from '../data/registry'
import { ErrorLine, NoticeLine } from '../lib/ErrorLine'
import { activeTab } from './config'
import OverviewTable from './OverviewTable'
import OverviewTabs from './OverviewTabs'
import { useOverview } from './overviews-context'

// A change of the actions value renders only this component.
function ActionLines(): React.JSX.Element {
  const { closeError, error, notice } = useActions()
  return (
    <>
      <NoticeLine message={notice} />
      <ErrorLine message={error} onClose={closeError} />
    </>
  )
}

export default function OverviewPanel({ panelId }: { panelId: string }): React.JSX.Element {
  const { config, update } = useOverview(panelId)
  const { error } = useRegistry()

  return (
    <div className='flex h-full min-w-0 select-none flex-col' data-overview-id={panelId}>
      <OverviewTabs config={config} update={update} />
      <OverviewTable tab={activeTab(config)} update={update} />
      {/* A notice and an error of an action, and an error of the session list. The error of the
          session list has no close button. The next good read removes it (Task 17 bug 4). */}
      <ActionLines />
      <ErrorLine message={error === null ? null : friendlyError(error)} />
    </div>
  )
}
