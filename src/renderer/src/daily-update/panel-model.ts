// The texts and the rules of the Daily update panel (Daily update design, section 6.2). All
// functions are pure, so the tests need no DOM.
import { freshMarks, localDate } from '../../../shared/daily-schedule'
import {
  type AreaView,
  type DailyItem,
  type DailySnapshot,
  failureText,
} from '../../../shared/daily-state'

export const NOT_SENT = 'Not sent yet'
export const SENT = 'Sent'
export const SKIPPED = 'Skipped today'
export const NOTHING_DUE = 'Nothing due today'
export const REFRESHING = 'Refreshing…'
export const NOTHING_MOVED = 'Nothing moved since your last update.'
export const NEW_DRAFT = "There's a new draft."
export const REDO_CONFIRM = 'Replace your changes with a new draft?'
export const SEND_TIP = 'Sending comes with the Slack app. For now, copy the draft.'
export const SET_UP = 'Set up your work areas to get a daily update.'
// The text of the refusal 'refused: the work area has no draft' in actions/errors.ts.
export const NO_DRAFT = "This work area doesn't have a draft yet."
// The time that Copy shows "Copied".
export const COPIED_MS = 2000

const MOVED = 'Moved since your last update'
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
// A time more than this number of days ago also shows its date, because its day name repeats.
const DAY_NAME_DAYS = 6

const pad = (n: number): string => String(n).padStart(2, '0')

// A time as HH:MM, 24 hours, local time.
export function clockText(ms: number): string {
  const d = new Date(ms)
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`
}

// The number of local dates from the date of ms to the date of now. A time change does not count.
function daysBefore(ms: number, now: number): number {
  const a = new Date(ms)
  const b = new Date(now)
  const start = Date.UTC(a.getFullYear(), a.getMonth(), a.getDate())
  const end = Date.UTC(b.getFullYear(), b.getMonth(), b.getDate())
  return Math.round((end - start) / 86_400_000)
}

// The day name and the time, for example "Tue 09:31". A time more than 6 days ago also gets its
// date, for example "Mon 2 Nov 09:41".
function dayTimeText(ms: number, now: number): string {
  const d = new Date(ms)
  const day = DAYS[d.getDay()]
  if (daysBefore(ms, now) <= DAY_NAME_DAYS) return `${day} ${clockText(ms)}`
  return `${day} ${d.getDate()} ${MONTHS[d.getMonth()]} ${clockText(ms)}`
}

const isSent = (snap: DailySnapshot, id: string): boolean =>
  Object.hasOwn(snap.state.marks.sent, id)

export function statusText(snap: DailySnapshot, now: number): string {
  if (!snap.configured || !snap.due) return NOTHING_DUE
  // The main process sends a new snapshot after midnight. Until then, old marks do not count.
  const today = localDate(new Date(now))
  const marks = snap.state.marks.date === today ? snap.state.marks : freshMarks(today)
  if (marks.skipped) return SKIPPED
  return snap.areas.every(a => Object.hasOwn(marks.sent, a.id)) ? SENT : NOT_SENT
}

export function dueText(snap: DailySnapshot): string | null {
  return snap.due ? `Due ${snap.deadline}` : null
}

// A run of today shows only its time. An earlier run also shows its day.
export function refreshText(snap: DailySnapshot, now: number): string | null {
  if (snap.running) return REFRESHING
  const run = snap.state.lastRun
  if (run === null) return null
  const today = localDate(new Date(run.at)) === localDate(new Date(now))
  return `Refreshed ${today ? clockText(run.at) : dayTimeText(run.at, now)}`
}

// Skip today on a due day, and Undo after a skip.
export function skipButton(snap: DailySnapshot): 'skip' | 'undo' | null {
  if (!snap.due) return null
  return snap.state.marks.skipped ? 'undo' : 'skip'
}

export function unplacedText(count: number): string | null {
  if (count === 0) return null
  return count === 1 ? '1 ticket fits no area' : `${count} tickets fit no area`
}

// The first area in the order of the settings that is not sent, or null.
export function firstUnsentArea(snap: DailySnapshot): string | null {
  return snap.areas.find(a => !isSent(snap, a.id))?.id ?? null
}

export function tabMarker(snap: DailySnapshot, id: string): boolean {
  return snap.due && !snap.state.marks.skipped && !isSent(snap, id)
}

// The tab to show: the chosen tab of an area that is on, else the first unsent area, else the
// first area.
export function shownTab(snap: DailySnapshot, chosen: string | null): string | null {
  if (chosen !== null && snap.areas.some(a => a.id === chosen)) return chosen
  return firstUnsentArea(snap) ?? snap.areas[0]?.id ?? null
}

export function movedHeader(since: number | undefined, now: number): string {
  if (since === undefined) return MOVED
  return `${MOVED} (${dayTimeText(since, now)})`
}

// The change of state of an item, or null.
export function itemChange(item: DailyItem): string | null {
  if (item.from !== undefined && item.to !== undefined) return `${item.from} → ${item.to}`
  return item.to ?? item.from ?? null
}

// The view of the area. An inherited key such as "constructor" gives nothing.
export function areaView(snap: DailySnapshot, id: string): AreaView | undefined {
  return Object.hasOwn(snap.state.areas, id) ? snap.state.areas[id] : undefined
}

// The start of the items of the area: the start of the run that made them. A view with no start
// uses the start of "since your last update" of the snapshot.
export function areaSince(snap: DailySnapshot, id: string): number | undefined {
  const since = areaView(snap, id)?.since
  if (since !== undefined) return since
  return Object.hasOwn(snap.since, id) ? snap.since[id] : undefined
}

export function redoNeedsConfirm(view: AreaView | undefined): boolean {
  return view?.edited === true
}

export function sentText(snap: DailySnapshot, id: string): string | null {
  const at = isSent(snap, id) ? snap.state.marks.sent[id] : undefined
  return at === undefined ? null : `Sent at ${clockText(at)}`
}

export function sendText(channel: string): string {
  const name = channel.trim()
  return name === '' ? 'Send' : `Send to ${name}`
}

export function panelBody(snap: DailySnapshot | null): 'loading' | 'empty' | 'tabs' {
  if (snap === null) return 'loading'
  return snap.configured && snap.areas.length > 0 ? 'tabs' : 'empty'
}

// The reason of a failed last run. server is the name of the ticket source in the settings.
export function failureLine(snap: DailySnapshot, server: string | null): string | null {
  const run = snap.state.lastRun
  if (run === null || run.ok || run.failure === undefined) return null
  return failureText(run.failure, run.detail, server)
}
