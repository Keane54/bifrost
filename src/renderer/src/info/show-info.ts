// The values of the Show Info panel (spec 8.6). The module is pure.

import type { PrInfo, RateWindow, SessionRow } from '../../../shared/types'
import { worktreeOf } from '../../../shared/worktree'
import { formatClock, formatDuration, timeParts } from '../lib/time'
import { formatCost, formatPercent } from '../overview/format'

export { formatDuration }

const PREFIX = 'show-info:'

export function showInfoPanelId(sessionId: string): string {
  return `${PREFIX}${sessionId}`
}

export function showInfoSessionId(panelId: string): string | null {
  return panelId.startsWith(PREFIX) && panelId.length > PREFIX.length
    ? panelId.slice(PREFIX.length)
    : null
}

export interface InfoItem {
  label: string
  value: string
  mono?: true
}

export interface InfoSection {
  title: string
  items: InfoItem[]
}

// 1.5M, 200k, 999
export function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${Number((n / 1_000_000).toFixed(1))}M`
  if (n >= 1_000) return `${Number((n / 1_000).toFixed(1))}k`
  return String(n)
}

// The same day gives HH:MM. Another day gives "Thu 5 Nov 14:03".
export function formatWhen(ms: number, now: number, timeZone?: string): string {
  const p = timeParts(ms, timeZone)
  const q = timeParts(now, timeZone)
  if (p.year === q.year && p.month === q.month && p.day === q.day) return formatClock(ms, timeZone)
  return `${p.weekday} ${p.day} ${p.month} ${p.hour}:${p.minute}`
}

// An empty or missing value shows "-".
const dash = (text: string | undefined): string => (text ? text : '-')

function prText(pr: PrInfo | null): string {
  if (pr === null) return 'Loading...'
  if (pr.kind === 'pr') return `#${pr.number} ${pr.title} (${pr.state.toLowerCase()})`
  return pr.kind === 'none' ? 'None' : pr.reason
}

function limitText(window: RateWindow | undefined, now: number, timeZone?: string): string {
  if (!window) return '-'
  return `${formatPercent(window.usedPercent)}, resets ${formatWhen(window.resetsAt, now, timeZone)}`
}

function durationText(row: SessionRow, now: number): string {
  if (row.state === 'parked') return 'Parked'
  return row.startedAt > 0 ? formatDuration(now - row.startedAt) : '-'
}

export function infoSections(
  row: SessionRow,
  now: number,
  pr: PrInfo | null,
  timeZone?: string,
): InfoSection[] {
  const kind =
    row.kind === 'owned' ? 'Owned' : `External${row.terminalApp ? ` (${row.terminalApp})` : ''}`
  return [
    {
      items: [
        { label: 'Name', value: dash(row.name) },
        { label: 'Session ID', mono: true, value: dash(row.sessionId) },
        { label: 'Short ID', mono: true, value: dash(row.shortId) },
        { label: 'Kind', value: kind },
        { label: 'PID', value: row.pid === undefined ? '-' : String(row.pid) },
      ],
      title: 'Session',
    },
    {
      items: [
        { label: 'Project folder', mono: true, value: dash(row.cwd) },
        { label: 'Transcript', mono: true, value: dash(row.transcriptPath) },
      ],
      title: 'Files',
    },
    {
      items: [
        { label: 'Branch', value: dash(row.branch) },
        { label: 'PR', value: prText(pr) },
        { label: 'Worktree', value: worktreeOf(row) ?? 'None' },
      ],
      title: 'Git',
    },
    {
      items: [
        { label: 'Model', value: dash(row.model) },
        { label: 'Effort', value: dash(row.effort) },
        { label: 'Permission mode', value: dash(row.permissionMode) },
      ],
      title: 'Model',
    },
    {
      items: [
        {
          label: 'Started',
          value: row.startedAt > 0 ? formatWhen(row.startedAt, now, timeZone) : '-',
        },
        { label: 'Duration', value: durationText(row, now) },
      ],
      title: 'Time',
    },
    {
      items: [
        { label: 'Cost', value: dash(formatCost(row.costUsd)) },
        {
          label: 'Context window',
          value:
            row.contextWindowSize === undefined
              ? '-'
              : `${formatTokens(row.contextWindowSize)} tokens`,
        },
        { label: 'Context use', value: dash(formatPercent(row.contextPercent)) },
      ],
      title: 'Cost and context',
    },
    {
      items: [
        { label: '5-hour limit', value: limitText(row.rateLimits?.fiveHour, now, timeZone) },
        { label: '7-day limit', value: limitText(row.rateLimits?.sevenDay, now, timeZone) },
        { label: 'Claude Code version', value: dash(row.claudeVersion) },
      ],
      title: 'Limits and version',
    },
  ]
}
