// The reminder rules of the Daily update. All functions are pure and use local time.
import type { DailyUpdateSettings, WorkArea } from './daily-update'

export interface DayMarks {
  // Local date, YYYY-MM-DD.
  date: string
  skipped: boolean
  // Area id to the time of the send.
  sent: Record<string, number>
  firstShown: boolean
  secondShown: boolean
}

export type Reminder = 'first' | 'second' | 'late'

export type ScheduleAction =
  | { kind: 'none' }
  | { kind: 'run'; reminder: Reminder }
  | { kind: 'notify'; reminder: 'second' }

const SECOND_LEAD_MINUTES = 10
const LOOK_BACK_DAYS = 7
const DAY_MS = 24 * 60 * 60 * 1000

const pad = (n: number): string => String(n).padStart(2, '0')

export function localDate(now: Date): string {
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

export function freshMarks(date: string): DayMarks {
  return { date, firstShown: false, secondShown: false, sent: {}, skipped: false }
}

export function isDueDay(now: Date, days: readonly number[]): boolean {
  return days.includes(now.getDay())
}

export function allDone(marks: DayMarks, areas: readonly WorkArea[]): boolean {
  if (marks.skipped) return true
  return areas.filter(area => area.on).every(area => Object.hasOwn(marks.sent, area.id))
}

// Minutes of the local wall clock. This ignores the length of the day, so a time change is safe.
const clockMinutes = (now: Date): number => now.getHours() * 60 + now.getMinutes()

const timeMinutes = (time: string): number => Number(time.slice(0, 2)) * 60 + Number(time.slice(3))

const NONE: ScheduleAction = { kind: 'none' }

export function nextAction(now: Date, s: DailyUpdateSettings, marks: DayMarks): ScheduleAction {
  const today = localDate(now)
  const m = marks.date === today ? marks : freshMarks(today)
  if (!isDueDay(now, s.days) || !s.areas.some(a => a.on) || allDone(m, s.areas)) return NONE
  const t = clockMinutes(now)
  const draft = timeMinutes(s.draftTime)
  const deadline = timeMinutes(s.deadline)
  if (t < draft) return NONE
  if (t < deadline - SECOND_LEAD_MINUTES) {
    return m.firstShown ? NONE : { kind: 'run', reminder: 'first' }
  }
  if (t < deadline) {
    if (!m.firstShown && !m.secondShown) return { kind: 'run', reminder: 'second' }
    if (m.firstShown && !m.secondShown) return { kind: 'notify', reminder: 'second' }
    return NONE
  }
  return m.firstShown || m.secondShown ? NONE : { kind: 'run', reminder: 'late' }
}

export function showMarker(now: Date, s: DailyUpdateSettings, marks: DayMarks): boolean {
  const today = localDate(now)
  const m = marks.date === today ? marks : freshMarks(today)
  if (!isDueDay(now, s.days) || !s.areas.some(a => a.on) || allDone(m, s.areas)) return false
  return clockMinutes(now) >= timeMinutes(s.draftTime)
}

// The start of the period for a draft. Use the last send, or the start of the last due day.
export function sinceTime(
  now: Date,
  days: readonly number[],
  lastSentAt: number | undefined,
): number {
  if (lastSentAt !== undefined) return lastSentAt
  for (let back = 1; back <= LOOK_BACK_DAYS; back++) {
    const day = new Date(now.getFullYear(), now.getMonth(), now.getDate() - back)
    if (isDueDay(day, days)) return day.getTime()
  }
  return now.getTime() - DAY_MS
}
