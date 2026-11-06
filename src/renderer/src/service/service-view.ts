// The texts of the Service status panel.
import type { Incident, ServiceLevel } from '../../../shared/types'
import { formatClock, formatDuration } from '../lib/time'

const LEVEL_TEXT: Record<ServiceLevel, string> = {
  critical: 'Critical outage',
  maintenance: 'Maintenance',
  major: 'Major outage',
  minor: 'Minor issue',
  none: 'Operational',
  unknown: 'No data',
}

export function levelText(level: ServiceLevel): string {
  return LEVEL_TEXT[level]
}

// "API errors - major (investigating), for 1 h 02 min"
export function incidentLine(incident: Incident, now: number): string {
  const base = `${incident.name} - ${incident.impact} (${incident.status})`
  return incident.startedAt === null
    ? base
    : `${base}, for ${formatDuration(now - incident.startedAt)}`
}

export function checkedText(checkedAt: number, _now: number, timeZone?: string): string {
  if (checkedAt === 0) return 'Not checked yet.'
  return `Checked at ${formatClock(checkedAt, timeZone)}.`
}
