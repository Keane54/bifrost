// Time texts for the panels and the notifications. All use a 24-hour clock and no comma.
// A time zone argument is for tests. Without it, the zone of the computer applies.

interface Parts {
  weekday: string
  day: string
  month: string
  year: string
  hour: string
  minute: string
  second: string
}

const formatters = new Map<string, Intl.DateTimeFormat>()

function formatterFor(timeZone: string | undefined): Intl.DateTimeFormat {
  const key = timeZone ?? ''
  let f = formatters.get(key)
  if (!f) {
    f = new Intl.DateTimeFormat('en-GB', {
      day: 'numeric',
      hour: '2-digit',
      hourCycle: 'h23',
      minute: '2-digit',
      month: 'short',
      second: '2-digit',
      timeZone,
      weekday: 'short',
      year: 'numeric',
    })
    formatters.set(key, f)
  }
  return f
}

// The parts of a time in the time zone.
export function timeParts(ms: number, timeZone?: string): Parts {
  const parts: Parts = {
    day: '',
    hour: '',
    minute: '',
    month: '',
    second: '',
    weekday: '',
    year: '',
  }
  for (const p of formatterFor(timeZone).formatToParts(ms)) {
    if (p.type in parts) parts[p.type as keyof Parts] = p.value
  }
  return parts
}

// True when the two times have the same date in the time zone.
export function sameDay(a: number, b: number, timeZone?: string): boolean {
  const x = timeParts(a, timeZone)
  const y = timeParts(b, timeZone)
  return x.day === y.day && x.month === y.month && x.year === y.year
}

// 09:07
export function formatClock(ms: number, timeZone?: string): string {
  const p = timeParts(ms, timeZone)
  return `${p.hour}:${p.minute}`
}

// Thu 14:03
export function formatDayClock(ms: number, timeZone?: string): string {
  const p = timeParts(ms, timeZone)
  return `${p.weekday} ${p.hour}:${p.minute}`
}

// HH:MM on the day of now, else Ddd HH:MM. The Usage HUD and the usage notification use it.
export function formatClockOrDay(ms: number, now: number, timeZone?: string): string {
  return sameDay(ms, now, timeZone) ? formatClock(ms, timeZone) : formatDayClock(ms, timeZone)
}

// 09:07:03.045
export function formatClockMs(ms: number, timeZone?: string): string {
  const p = timeParts(ms, timeZone)
  const millis = String(Math.floor(((ms % 1000) + 1000) % 1000)).padStart(3, '0')
  return `${p.hour}:${p.minute}:${p.second}.${millis}`
}

// A length of time: "less than 1 min", "59 min", "1 h 02 min", "1 d 1 h".
export function formatDuration(ms: number): string {
  const minutes = Math.floor(Math.max(0, ms) / 60_000)
  if (minutes < 1) return 'less than 1 min'
  if (minutes < 60) return `${minutes} min`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} h ${String(minutes % 60).padStart(2, '0')} min`
  return `${Math.floor(hours / 24)} d ${hours % 24} h`
}
