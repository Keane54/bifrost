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

// The view of the service rows (spec 8.11). 0: the full row. 1: the status page button shows
// only its icon. 2: the level square also shows without its text.
export type ServiceView = 0 | 1 | 2

// Choose the view from the width of a row and the widths that the widest row needs: needs[0] in
// the full view, needs[1] without the text of the status page button. A text that does not fit
// is cut off. So the first view where the widest row fits wins. The needs come from the full
// row, not from the view on the screen, so a wider panel gives a fuller view again.
export function serviceView(available: number, needs: readonly [number, number]): ServiceView {
  if (available >= needs[0]) return 0
  return available >= needs[1] ? 1 : 2
}
