// The content of a module panel (plan Task 6). An enabled module shows its sandboxed frame. A
// module that is off, removed or without the panel shows a notice (Review Focus 3). The frame then
// goes away, and its bridge closes.
import type { ModuleRow } from '../../../shared/modules'
import { cx } from '../lib/cx'
import { ModuleFrame } from './ModuleFrame'
import { modulePanelOf } from './module-panels'
import { useModules, useModulesLoaded } from './use-modules'

export const MODULE_OFF_NOTICE = 'This module is off or no longer installed.'

export interface ModulePanelViewProps {
  panelId: string
  modules: readonly ModuleRow[]
  // False before the first rows come. Then the panel shows nothing.
  loaded: boolean
}

// The title bar of a module panel: the panel title, then the module name in a dim colour. A
// module that is gone shows "Module".
export function ModulePanelTitle({
  modules,
  panelId,
}: {
  panelId: string
  modules: readonly ModuleRow[]
}): React.JSX.Element {
  const found = modulePanelOf(modules, panelId)
  if (found === null) return <>Module</>
  return (
    <>
      {found.panel.title}
      <span className={cx('text-text-dim')} data-module-name={true}>
        {` · ${found.row.name}`}
      </span>
    </>
  )
}

export function ModulePanelView({
  loaded,
  modules,
  panelId,
}: ModulePanelViewProps): React.JSX.Element | null {
  if (!loaded) return null
  const found = modulePanelOf(modules, panelId)
  if (found === null || !found.row.enabled) {
    return (
      <div className={cx('p-3 text-[13px] text-text-dim')} data-module-notice={true}>
        {MODULE_OFF_NOTICE}
      </div>
    )
  }
  return <ModuleFrame entry={found.panel.entry} moduleId={found.row.id} panelId={found.panel.id} />
}

export default function ModulePanel({ panelId }: { panelId: string }): React.JSX.Element | null {
  const { modules } = useModules()
  const loaded = useModulesLoaded()
  return <ModulePanelView loaded={loaded} modules={modules} panelId={panelId} />
}
