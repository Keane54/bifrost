// The workspace trust of Claude Code for a clone. Bifrost reads ~/.claude.json only to see the
// trust flag. It never writes the file, never logs its content and never accepts a trust prompt.
// The trust terminal runs claude in the clone, so that the user accepts the prompt there.

import { realpath } from 'node:fs/promises'
import { dirname } from 'node:path'
import type { PtyManager } from '../pty/pty-manager'
import { readClaudeJson } from '../usage-alerts/claude-json'

export const TRUST_VIEW = 'trust'
export const TRUST_POLL_MS = 2000
export const TRUST_SIZE = { cols: 100, rows: 30 }

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

// True when projects[p].hasTrustDialogAccepted is true for dir or for a parent folder of dir.
export function trustedIn(data: unknown, dir: string): boolean {
  if (!isRecord(data) || !isRecord(data.projects)) return false
  const projects = data.projects
  let p = dir
  for (;;) {
    if (Object.hasOwn(projects, p)) {
      const entry = projects[p]
      if (isRecord(entry) && entry.hasTrustDialogAccepted === true) return true
    }
    const up = dirname(p)
    if (up === p) return false
    p = up
  }
}

// The dirs (as given) that Claude Code trusts. One read of the file. A failed read gives an
// empty set.
export async function trustedDirs(file: string, dirs: readonly string[]): Promise<Set<string>> {
  const out = new Set<string>()
  const data = await readClaudeJson(file)
  if (data === null) return out
  for (const dir of dirs) {
    // Claude Code can write the key as given or as the real path. A match on either counts.
    if (trustedIn(data, dir)) {
      out.add(dir)
      continue
    }
    try {
      if (trustedIn(data, await realpath(dir))) out.add(dir)
    } catch {
      // A folder that is not there is not trusted.
    }
  }
  return out
}

export interface TrustWindow {
  open(repo: string, cwd: string): Promise<void>
  write(data: string): void
  resize(cols: number, rows: number): void
  close(): void
  current(): string | null
  exited(): void
}

export function createTrustWindow(deps: {
  pty(): Promise<Pick<PtyManager, 'open' | 'write' | 'resize' | 'close'> | null>
  isTrusted(dir: string): Promise<boolean>
  onEnd(end: { repo: string; trusted: boolean }): void
}): TrustWindow {
  let repo: string | null = null
  let timer: ReturnType<typeof setTimeout> | null = null
  // Each open gets a new token. A late check of an old window sees a different token and stops.
  let token = 0
  let manager: Pick<PtyManager, 'open' | 'write' | 'resize' | 'close'> | null = null

  function stop(): void {
    token += 1
    if (timer) clearTimeout(timer)
    timer = null
    if (repo !== null) manager?.close(TRUST_VIEW)
    repo = null
  }

  function schedule(mine: number, cwd: string): void {
    timer = setTimeout(() => {
      timer = null
      void check(mine, cwd)
    }, TRUST_POLL_MS)
  }

  async function check(mine: number, cwd: string): Promise<void> {
    let trusted = false
    try {
      trusted = await deps.isTrusted(cwd)
    } catch {
      trusted = false
    }
    if (mine !== token || repo === null) return
    if (!trusted) {
      schedule(mine, cwd)
      return
    }
    const done = repo
    stop()
    deps.onEnd({ repo: done, trusted: true })
  }

  return {
    close: stop,
    current: () => repo,
    exited() {
      if (repo === null) return
      const done = repo
      token += 1
      if (timer) clearTimeout(timer)
      timer = null
      repo = null
      deps.onEnd({ repo: done, trusted: false })
    },
    async open(name, cwd) {
      stop()
      const mine = token
      const m = await deps.pty()
      // Another open or a close can come while the manager loads.
      if (!m || mine !== token) return
      manager = m
      repo = name
      m.open(TRUST_VIEW, [], { cwd, ...TRUST_SIZE })
      schedule(mine, cwd)
    },
    resize(cols, rows) {
      if (repo !== null) manager?.resize(TRUST_VIEW, cols, rows)
    },
    write(data) {
      if (repo !== null) manager?.write(TRUST_VIEW, data)
    },
  }
}
