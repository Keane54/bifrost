// The module panels of the window system (plan Task 6). The panel ID is
// module:<module id>:<panel id>, and the rows of the main process give the manifest of each module.
import type { ModuleIcon, ModulePanel } from '../../../shared/module-manifest'
import type { ModuleRow } from '../../../shared/modules'
import { MODULE_PANEL, modulePanelId } from '../../../shared/view-id'

// The row and the manifest panel of a module panel ID, or null when no row has that panel. The
// module can be off.
export function modulePanelOf(
  modules: readonly ModuleRow[],
  panelId: string,
): { row: ModuleRow; panel: ModulePanel } | null {
  const match = MODULE_PANEL.exec(panelId)
  if (match === null) return null
  const [, moduleId, id] = match
  const row = modules.find(m => m.id === moduleId)
  const panel = row?.panels.find(p => p.id === id)
  return row && panel ? { panel, row } : null
}

// The label of a module panel in Bifrost's side bar: the panel title and the module name. So a
// panel that copies the title of a Bifrost panel, or of a panel of another module, still shows
// which module it comes from.
export function modulePanelLabel(row: ModuleRow, panel: ModulePanel): string {
  return `${panel.title} (${row.name})`
}

export interface ModuleSideButton {
  panelId: string
  label: string
  icon: ModuleIcon
}

// One side bar button for each panel of each enabled module, in the order of the rows.
// A module that is off gets no button.
export function moduleSideButtons(modules: readonly ModuleRow[]): ModuleSideButton[] {
  return modules
    .filter(m => m.enabled)
    .flatMap(m =>
      m.panels.map(p => ({
        icon: p.icon,
        label: modulePanelLabel(m, p),
        panelId: modulePanelId(m.id, p.id),
      })),
    )
}
