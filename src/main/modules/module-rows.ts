// The rows of the modules for the page (plan Task 6, ruling P1). The page shows them in the side
// bar, the module panels and Settings. A packaged app treats a dev module as off, as Heimdall and
// the module protocol do, and the row gives the reason.
import type { ModuleManifest } from '../../shared/module-manifest'
import type { ModuleRow, ModulesSnapshot } from '../../shared/modules'
import type { ModuleEntry, ModuleSource, ModulesState } from './module-state'

export const DEV_OFF_REASON = 'This developer module runs only in a development build of Bifrost.'

export interface RowOptions {
  // False in a packaged app. Then a dev module is off.
  devAllowed: boolean
  // The local date (YYYY-MM-DD). Only the jobs of this day count.
  today: string
  // The count of the module jobs of a module that wait for Refresh (jobs.ts). Without it, the
  // count is 0.
  waiting?: (moduleId: string) => number
  // The home folder of the user. A source folder in it starts with ~ in the row.
  home?: string
}

// The source as text: the GitHub URL, or the folder with ~ for the home folder.
function sourceText(source: ModuleSource, home: string | undefined): string {
  if (source.kind === 'git') return source.url
  const base = home?.replace(/\/+$/, '')
  if (base === undefined || base === '') return source.path
  if (source.path === base) return '~'
  return source.path.startsWith(`${base}/`) ? `~${source.path.slice(base.length)}` : source.path
}

// The permissions of the next manifest that the current manifest does not have.
function addedPermissions(current: ModuleManifest, next: ModuleManifest): ModuleRow['requested'] {
  const have = new Set(current.permissions.map(p => p.id))
  return next.permissions.filter(p => !have.has(p.id)).map(p => ({ ...p }))
}

function rowOf(id: string, entry: ModuleEntry, opts: RowOptions): ModuleRow {
  const { manifest } = entry
  const devOff = entry.source.kind === 'dev' && !opts.devAllowed
  return {
    dailyCap: entry.dailyCap,
    description: manifest.description,
    dev: entry.source.kind === 'dev',
    enabled: entry.enabled && !devOff,
    granted: [...entry.granted],
    id,
    jobsToday: entry.jobs.day === opts.today ? entry.jobs.count : 0,
    model: entry.model,
    name: manifest.name,
    offReason: devOff ? DEV_OFF_REASON : null,
    panels: manifest.panels.map(p => ({ ...p })),
    pendingUpdate: entry.pendingUpdate
      ? {
          added: addedPermissions(manifest, entry.pendingUpdate.manifest),
          version: entry.pendingUpdate.manifest.version,
        }
      : null,
    requested: manifest.permissions.map(p => ({ ...p })),
    source: sourceText(entry.source, opts.home),
    sourceKind: entry.source.kind,
    // Phase 1 has only the permissions of the Standard tier (Modules design 8.2).
    tier: 'standard',
    version: manifest.version,
    // The module jobs that wait for Refresh. The title bar of a module panel shows the count.
    waitingJobs: opts.waiting?.(id) ?? 0,
  }
}

// One row for each module, by name and then by id.
export function modulesSnapshot(state: ModulesState, opts: RowOptions): ModulesSnapshot {
  const modules = Object.entries(state.modules).map(([id, entry]) => rowOf(id, entry, opts))
  modules.sort((a, b) => a.name.localeCompare(b.name) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
  return { modules }
}
