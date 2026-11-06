import { join } from 'node:path'
import type { TerminalAppId } from '../../shared/settings'
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

async function findInstalled(
  home: string,
  exists: (path: string) => Promise<boolean>,
): Promise<Map<ProjectAppId, InstalledApp>> {
  const found = new Map<ProjectAppId, InstalledApp>()
  for (const c of APP_CANDIDATES) {
    const path = await locate(c.bundle, home, exists)
    if (path) found.set(c.id, { id: c.id, label: c.label, path })
  }
  return found
}

// Return each installed terminal app, in the order of TERMINAL_ORDER. A test gives another order.
export async function findTerminalApps(
  home: string,
  exists: (path: string) => Promise<boolean>,
  order: readonly ProjectAppId[] = TERMINAL_ORDER,
): Promise<InstalledApp[]> {
  const found = await findInstalled(home, exists)
  return order.flatMap(id => found.get(id) ?? [])
}

// Return Finder, then VS Code and Zed if installed, then one terminal app.
// The terminal app is the chosen one when it is installed, else the first installed one.
export async function findProjectApps(
  home: string,
  exists: (path: string) => Promise<boolean>,
  terminal: TerminalAppId | null = null,
): Promise<InstalledApp[]> {
  const found = await findInstalled(home, exists)
  const chosen =
    terminal !== null && found.has(terminal) ? terminal : TERMINAL_ORDER.find(id => found.has(id))
  return (['finder', 'vscode', 'zed'] as ProjectAppId[])
    .concat(chosen ? [chosen] : [])
    .flatMap(id => found.get(id) ?? [])
}
