// The check of one public status page (Atlassian Statuspage). The endpoints, the component
// filter and the rank rules are those of claude-statusline. The fetch is a parameter.
import type { Impact, Incident, ServiceId, ServiceLevel, ServiceStatus } from '../../shared/types'

export interface ServiceDef {
  id: ServiceId
  name: string
  base: string
  // A component or an incident of this kind is not shown. null means no filter.
  ignore: RegExp | null
}

export const SERVICES: readonly ServiceDef[] = [
  {
    base: 'https://status.claude.com',
    id: 'claude',
    ignore: /^Claude (Console|Cowork|for Government)/,
    name: 'Claude',
  },
  {
    base: 'https://www.githubstatus.com',
    id: 'github',
    ignore: /^(Copilot|Codespaces|Pages|Packages)/,
    name: 'GitHub',
  },
  { base: 'https://status.sentry.io', id: 'sentry', ignore: null, name: 'Sentry' },
]

export const FETCH_TIMEOUT_MS = 5000
export const NO_ANSWER = "The status page didn't answer."

export type FetchJson = (url: string) => Promise<unknown>

// The fetch of the main process (net.fetch). A test passes a fake.
export type FetchFn = (url: string, init: RequestInit) => Promise<Response>

// Bifrost reads at most this many bytes of one answer. A status page answer has a few kB.
export const MAX_BODY_BYTES = 1_000_000
const TOO_LARGE = 'The answer of the status page is too large.'

// Read the text of a body with the cap. A content-length over the cap stops before the read. A
// body that gets past the cap stops the read at once. Each stop rejects with the tooLarge text.
// The release notes source uses it too.
export async function cappedText(
  res: Response,
  max: number,
  tooLarge: string = TOO_LARGE,
): Promise<string> {
  const length = Number(res.headers.get('content-length'))
  if (Number.isFinite(length) && length > max) {
    await res.body?.cancel().catch(() => {})
    throw new Error(tooLarge)
  }
  if (res.body === null) return ''
  const reader = res.body.getReader()
  const chunks: Uint8Array[] = []
  let size = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    size += value.byteLength
    if (size > max) {
      await reader.cancel().catch(() => {})
      throw new Error(tooLarge)
    }
    chunks.push(value)
  }
  return Buffer.concat(chunks).toString('utf8')
}

// The fetchJson of the monitor. It asks for JSON, stops after FETCH_TIMEOUT_MS, and reads at most
// MAX_BODY_BYTES of the body. A bad answer rejects, and checkService then
// gives unknown.
export function createFetchJson(fetch: FetchFn): FetchJson {
  return async url => {
    const res = await fetch(url, {
      headers: { accept: 'application/json' },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    })
    if (!res.ok) {
      await res.body?.cancel().catch(() => {})
      throw new Error(`The status page answered ${res.status}.`)
    }
    return JSON.parse(await cappedText(res, MAX_BODY_BYTES))
  }
}

const INDICATORS: readonly string[] = ['none', 'minor', 'major', 'critical', 'maintenance']
const WORDS: readonly Impact[] = ['none', 'minor', 'major', 'critical']

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

// The weight of a level: minor 1, major 2, critical 3, each other value 0.
function rank(level: string): number {
  return level === 'minor' ? 1 : level === 'major' ? 2 : level === 'critical' ? 3 : 0
}

// The indicator of status.json, or null when the data is not a good answer.
export function indicatorOf(data: unknown): ServiceLevel | null {
  if (!isRecord(data) || !isRecord(data.status)) return null
  const indicator = data.status.indicator
  if (typeof indicator !== 'string' || !INDICATORS.includes(indicator)) return null
  return indicator as ServiceLevel
}

function statusWeight(status: unknown): number {
  if (status === 'degraded_performance') return 1
  if (status === 'partial_outage') return 2
  if (status === 'major_outage') return 3
  return 0
}

// The level of the components that the filter keeps, or null when the data is not a list.
export function componentIndicator(data: unknown, ignore: RegExp): ServiceLevel | null {
  if (!isRecord(data) || !Array.isArray(data.components)) return null
  let weight = 0
  let maintenance = false
  for (const c of data.components as unknown[]) {
    if (!isRecord(c) || c.group === true) continue
    if (typeof c.name === 'string' && ignore.test(c.name)) continue
    weight = Math.max(weight, statusWeight(c.status))
    if (c.status === 'under_maintenance') maintenance = true
  }
  if (weight > 0) return WORDS[weight] ?? 'none'
  return maintenance ? 'maintenance' : 'none'
}

function keeps(incident: Record<string, unknown>, ignore: RegExp | null): boolean {
  if (!ignore) return true
  const components = Array.isArray(incident.components) ? (incident.components as unknown[]) : []
  if (components.length === 0) return true
  return components.some(c => !isRecord(c) || typeof c.name !== 'string' || !ignore.test(c.name))
}

// The open incidents of unresolved.json that the filter keeps.
export function parseIncidents(data: unknown, ignore: RegExp | null): Incident[] {
  if (!isRecord(data) || !Array.isArray(data.incidents)) return []
  const list: Incident[] = []
  for (const raw of data.incidents as unknown[]) {
    if (!isRecord(raw) || !keeps(raw, ignore)) continue
    const weight = rank(typeof raw.impact === 'string' ? raw.impact : '')
    const status = typeof raw.status === 'string' ? raw.status : ''
    const started = typeof raw.started_at === 'string' ? Date.parse(raw.started_at) : Number.NaN
    list.push({
      impact: WORDS[weight] ?? 'none',
      name: typeof raw.name === 'string' ? raw.name : 'Incident',
      rank: status === 'monitoring' ? Math.min(weight, 1) : weight,
      startedAt: Number.isNaN(started) ? null : started,
      status,
    })
  }
  return list
}

function oldest(list: Incident[]): number | null {
  const times = list.flatMap(i => (i.startedAt === null ? [] : [i.startedAt]))
  return times.length === 0 ? null : Math.min(...times)
}

// The worse of the indicator and the incidents, and the start of the oldest incident at it.
export function combine(
  indicator: ServiceLevel,
  incidents: Incident[],
): { level: ServiceLevel; since: number | null } {
  const w = incidents.reduce((max, i) => Math.max(max, i.rank), 0)
  const level: ServiceLevel = w > rank(indicator) ? (WORDS[w] ?? indicator) : indicator
  const r = rank(level)
  const byRank = incidents.filter(i => i.rank >= r)
  const byImpact = incidents.filter(i => rank(i.impact) >= r)
  const since = oldest(byRank) ?? oldest(byImpact) ?? oldest(incidents)
  return { level, since }
}

async function tryFetch(fetchJson: FetchJson, url: string): Promise<unknown> {
  try {
    return await fetchJson(url)
  } catch {
    return null
  }
}

export async function checkService(
  def: ServiceDef,
  fetchJson: FetchJson,
  now: number,
): Promise<ServiceStatus> {
  const api = `${def.base}/api/v2`
  let indicator = indicatorOf(await tryFetch(fetchJson, `${api}/status.json`))
  if (indicator === null) {
    return {
      checkedAt: now,
      error: NO_ANSWER,
      id: def.id,
      incidents: [],
      level: 'unknown',
      name: def.name,
      since: null,
    }
  }
  if (def.ignore) {
    const fromComponents = componentIndicator(
      await tryFetch(fetchJson, `${api}/components.json`),
      def.ignore,
    )
    if (fromComponents !== null) indicator = fromComponents
  }
  const incidents = parseIncidents(
    await tryFetch(fetchJson, `${api}/incidents/unresolved.json`),
    def.ignore,
  ).sort(
    (a, b) =>
      b.rank - a.rank ||
      (a.startedAt ?? Number.POSITIVE_INFINITY) - (b.startedAt ?? Number.POSITIVE_INFINITY),
  )
  const { level, since } = combine(indicator, incidents)
  return { checkedAt: now, id: def.id, incidents, level, name: def.name, since }
}
