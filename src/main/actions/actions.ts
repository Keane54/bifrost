import type { ProjectApp, SessionRow } from '../../shared/types'
import type { ExecFn } from '../claude/cli'
import type { InstalledApp } from './project-apps'

export const OPEN = '/usr/bin/open'

export interface ActionDeps {
  rows(): SessionRow[]
  apps(): Promise<InstalledApp[]>
  exec: ExecFn
  writeClipboard(text: string): void
}

export interface Actions {
  listApps(): Promise<ProjectApp[]>
  openProject(sessionId: unknown, appId: unknown): Promise<void>
  copySessionId(sessionId: unknown): Promise<void>
}

// The renderer sends IDs only. This code finds the row and the app itself.
export function createActions(deps: ActionDeps): Actions {
  const find = (sessionId: unknown): SessionRow => {
    const row = deps.rows().find(r => r.sessionId === sessionId)
    if (!row) throw new Error('refused: unknown session')
    return row
  }
  return {
    async copySessionId(sessionId) {
      deps.writeClipboard(find(sessionId).sessionId)
    },
    async listApps() {
      return (await deps.apps()).map(({ id, label }) => ({ id, label }))
    },
    async openProject(sessionId, appId) {
      const row = find(sessionId)
      if (!row.cwd.startsWith('/')) throw new Error('refused: the project directory is not known')
      const app = (await deps.apps()).find(a => a.id === appId)
      if (!app) throw new Error('refused: unknown app')
      const result = await deps.exec(OPEN, ['-a', app.path, row.cwd], { timeoutMs: 10000 })
      if (result.code !== 0) throw new Error(result.stderr.trim() || 'open failed')
    },
  }
}
