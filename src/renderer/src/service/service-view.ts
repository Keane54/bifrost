// The texts of the Service status panel.
import type { Incident, ServiceLevel } from '../../../shared/types'
import { formatClock, formatDayClock, formatDuration, sameDay } from '../lib/time'

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

// "since 09:03" on the day of now, else "since Wed 22:15". Only a level that is not ok shows the
// start of its incident (ServiceStatus.since, final wave item 11).
export function sinceText(
  level: ServiceLevel,
  since: number | null,
  now: number,
  timeZone?: string,
): string | null {
  if (since === null || level === 'none' || level === 'unknown') return null
  const clock = sameDay(since, now, timeZone)
    ? formatClock(since, timeZone)
    : formatDayClock(since, timeZone)
  return `since ${clock}`
}
