// The title bar extras of a module panel (plan Task 8): the tier badge and the Refresh button.
// Both belong to Bifrost, not to the module: the page of the module never makes them or changes
// their text. The button shows for an enabled module with the claude-jobs grant, in both run
// modes (design 8.5). A click sends the refresh event to the module and runs each waiting module
// job. The count of waiting jobs shows only when it is more than 0.
import { RefreshCw } from 'lucide-react'
import { useCallback } from 'react'
import type { ModuleRow } from '../../../shared/modules'
import { cx } from '../lib/cx'
import { modulePanelOf } from './module-panels'
import { useModules } from './use-modules'

export const MODULE_REFRESH_TIP = 'Run the waiting module jobs'

export interface ModuleRefreshTarget {
  moduleId: string
  waiting: number
}

// The module of a panel that needs the button, or null.
export function moduleRefreshTarget(
  modules: readonly ModuleRow[],
  panelId: string,
): ModuleRefreshTarget | null {
  const found = modulePanelOf(modules, panelId)
  if (found === null) return null
  const { row } = found
  if (!row.enabled || !row.granted.includes('claude-jobs')) return null
  return { moduleId: row.id, waiting: Math.max(row.waitingJobs, 0) }
}

export function moduleTierLabel(tier: ModuleRow['tier']): string {
  return tier === 'permissive' ? 'Permissive' : 'Standard'
}

// Ask the main process to refresh the module. A refusal goes to the log with a short text.
export function refreshModule(
  api: { refresh(moduleId: string): Promise<void> },
  moduleId: string,
  log: (message: string, error: unknown) => void,
): void {
  api.refresh(moduleId).catch(error => log('Bifrost cannot refresh the module.', error))
}

export function ModuleRefreshView({
  moduleId,
  onRefresh,
  waiting,
}: {
  moduleId: string
  onRefresh: () => void
  waiting: number
}): React.JSX.Element {
  return (
    <button
      className={cx(
        'relative z-10 flex h-6 shrink-0 items-center gap-1 px-1.5 text-xs text-text-dim',
        'transition-colors duration-150 hover:bg-panel hover:text-text active:bg-accent/12',
      )}
      data-module-refresh={moduleId}
      onClick={onRefresh}
      title={MODULE_REFRESH_TIP}
      type='button'
    >
      <RefreshCw aria-hidden='true' className='size-3.5' />
      <span>Refresh</span>
      {waiting > 0 && <span data-module-waiting={true}>{` · ${waiting} waiting`}</span>}
    </button>
  )
}

// The badge and the button of the panel in a title bar. A module that is gone gets nothing.
export default function ModuleRefresh({ panelId }: { panelId: string }): React.JSX.Element | null {
  const { modules } = useModules()
  const found = modulePanelOf(modules, panelId)
  const target = moduleRefreshTarget(modules, panelId)
  const moduleId = target?.moduleId
  const refresh = useCallback(() => {
    if (moduleId !== undefined) {
      refreshModule(window.bifrost.modules, moduleId, (message, error) =>
        console.error(message, error),
      )
    }
  }, [moduleId])
  if (found === null) return null
  return (
    <>
      <span
        className={cx('shrink-0 px-1.5 text-[11px] text-text-dim')}
        data-module-tier={found.row.tier}
      >
        {moduleTierLabel(found.row.tier)}
      </span>
      {target !== null && (
        <ModuleRefreshView
          moduleId={target.moduleId}
          onRefresh={refresh}
          waiting={target.waiting}
        />
      )}
    </>
  )
}
