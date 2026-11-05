import { join } from 'node:path'
import { TERMINAL_ORDER } from '../../shared/terminal-order'
import type { ProjectApp, ProjectAppId } from '../../shared/types'

export interface InstalledApp extends ProjectApp {
  path: string
}

// A bundle name without a leading "/" is in /Applications or in <home>/Applications.
export const APP_CANDIDATES: { id: ProjectAppId; label: string; bundle: string }[] = [
  { bundle: '/System/Library/CoreServices/Finder.app', id: 'finder', label: 'Finder' },
  { bundle: 'Visual Studio Code.app', id: 'vscode', label: 'VS Code' },
  { bundle: 'Zed.app', id: 'zed', label: 'Zed' },
  { bundle: 'Warp.app', id: 'warp', label: 'Warp' },
  { bundle: 'Ghostty.app', id: 'ghostty', label: 'Ghostty' },
  { bundle: 'iTerm.app', id: 'iterm2', label: 'iTerm2' },
  { bundle: '/System/Applications/Utilities/Terminal.app', id: 'terminal', label: 'Terminal' },
]

export { TERMINAL_ORDER }

async function locate(
  bundle: string,
  home: string,
  exists: (path: string) => Promise<boolean>,
): Promise<string | null> {
  if (bundle.startsWith('/')) return (await exists(bundle)) ? bundle : null
  for (const dir of ['/Applications', join(home, 'Applications')]) {
    const path = join(dir, bundle)
    if (await exists(path)) return path
  }
  return null
}

// Return Finder, then VS Code and Zed if installed, then the first installed terminal app.
export async function findProjectApps(
  home: string,
  exists: (path: string) => Promise<boolean>,
): Promise<InstalledApp[]> {
  const found = new Map<ProjectAppId, InstalledApp>()
  for (const c of APP_CANDIDATES) {
    const path = await locate(c.bundle, home, exists)
    if (path) found.set(c.id, { id: c.id, label: c.label, path })
  }
  const terminal = TERMINAL_ORDER.find(id => found.has(id))
  return (['finder', 'vscode', 'zed'] as ProjectAppId[])
    .concat(terminal ? [terminal] : [])
    .flatMap(id => found.get(id) ?? [])
}
