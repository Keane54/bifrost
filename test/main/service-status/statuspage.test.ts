import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  checkService,
  combine,
  componentIndicator,
  type FetchJson,
  indicatorOf,
  parseIncidents,
  SERVICES,
} from '../../../src/main/service-status/statuspage'
import type { Incident } from '../../../src/shared/types'

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(join(__dirname, '../../fixtures/statuspage', name), 'utf8'))
}

const claude = SERVICES.find(s => s.id === 'claude')
const github = SERVICES.find(s => s.id === 'github')
const sentry = SERVICES.find(s => s.id === 'sentry')
if (!claude || !github || !sentry) throw new Error('A service is missing')
const GH = 'https://www.githubstatus.com/api/v2'

function incident(rank: number, startedAt: number | null, impact: Incident['impact']): Incident {
  return { impact, name: 'x', rank, startedAt, status: 'investigating' }
}

// A fake fetch. It records the URLs. A value of Error rejects.
function fake(map: Record<string, unknown>): { calls: string[]; fetchJson: FetchJson } {
  const calls: string[] = []
  const fetchJson: FetchJson = async url => {
    calls.push(url)
    const value = map[url]
    if (value === undefined || value instanceof Error) throw value ?? new Error('no route')
    return value
  }
  return { calls, fetchJson }
}

describe('indicatorOf', () => {
  it('indicatorOf reads the indicator and refuses other values', () => {
    expect(indicatorOf(fixture('status-none.json'))).toBe('none')
    expect(indicatorOf(fixture('status-minor.json'))).toBe('minor')
    expect(indicatorOf({ status: { indicator: 'maintenance' } })).toBe('maintenance')
    expect(indicatorOf({ status: { indicator: 'unknown' } })).toBeNull()
    expect(indicatorOf({ status: { indicator: 3 } })).toBeNull()
    expect(indicatorOf('<html></html>')).toBeNull()
    expect(indicatorOf(null)).toBeNull()
  })
})

describe('componentIndicator', () => {
  it('componentIndicator skips groups and the ignored components', () => {
    const ghIgnore = github.ignore
    const clIgnore = claude.ignore
    if (!ghIgnore || !clIgnore) throw new Error('ignore missing')
    expect(componentIndicator(fixture('components-github.json'), ghIgnore)).toBe('none')
    expect(componentIndicator(fixture('components-claude.json'), clIgnore)).toBe('minor')
    expect(componentIndicator({}, ghIgnore)).toBeNull()
  })

  it('componentIndicator gives maintenance when only maintenance remains', () => {
    const data = {
      components: [
        { name: 'API', status: 'under_maintenance' },
        { name: 'Web', status: 'operational' },
      ],
    }
    expect(componentIndicator(data, /^Copilot/)).toBe('maintenance')
    const worse = { components: [...data.components, { name: 'X', status: 'partial_outage' }] }
    expect(componentIndicator(worse, /^Copilot/)).toBe('major')
  })
})

describe('parseIncidents', () => {
  it('parseIncidents drops an incident whose components all match the ignore pattern', () => {
    const list = parseIncidents(fixture('incidents-github.json'), github.ignore)
    expect(list.map(i => i.name)).toEqual(['Slow webhooks', 'Git pushes fail'])
    expect(parseIncidents(fixture('incidents-github.json'), null)).toHaveLength(3)
    expect(parseIncidents('<html>', null)).toEqual([])
  })

  it('a monitoring incident counts as minor at most', () => {
    const list = parseIncidents(
      {
        incidents: [
          { impact: 'major', name: 'A', started_at: '2026-11-06T08:00:00Z', status: 'monitoring' },
          { impact: 'none', name: 'B', status: 'monitoring' },
        ],
      },
      null,
    )
    expect(list[0]).toMatchObject({
      impact: 'major',
      rank: 1,
      startedAt: Date.parse('2026-11-06T08:00:00Z'),
    })
    expect(list[1]).toMatchObject({ impact: 'none', rank: 0, startedAt: null })
  })

  it('uses the default name Incident', () => {
    expect(parseIncidents({ incidents: [{ impact: 'minor', status: 'x' }] }, null)[0]?.name).toBe(
      'Incident',
    )
  })
})

describe('combine', () => {
  it('combine takes the worse of the indicator and the incidents', () => {
    expect(combine('none', [incident(3, 1, 'critical')]).level).toBe('critical')
    expect(combine('major', [incident(1, 1, 'minor')]).level).toBe('major')
    expect(combine('none', []).level).toBe('none')
    expect(combine('maintenance', []).level).toBe('maintenance')
  })

  it('combine gives the oldest start of the incidents at the shown level', () => {
    const list = [
      incident(2, 500, 'major'),
      incident(3, 900, 'critical'),
      incident(3, 700, 'critical'),
    ]
    expect(combine('none', list)).toEqual({ level: 'critical', since: 700 })
    // The shown level major comes from the indicator: the incidents at major or more count.
    expect(combine('major', [incident(1, 100, 'minor'), incident(2, 400, 'major')]).since).toBe(400)
    // No incident reaches the level by rank: use the impact, then all incidents.
    expect(
      combine('major', [{ ...incident(1, 300, 'major') }, incident(1, 200, 'minor')]).since,
    ).toBe(300)
    expect(combine('major', [incident(1, 200, 'minor')]).since).toBe(200)
    expect(combine('none', [incident(0, null, 'none')]).since).toBeNull()
    expect(combine('none', []).since).toBeNull()
  })
})

describe('checkService', () => {
  it('checkService fetches status, components and incidents in this order', async () => {
    const { calls, fetchJson } = fake({
      [`${GH}/components.json`]: fixture('components-github.json'),
      [`${GH}/incidents/unresolved.json`]: fixture('incidents-github.json'),
      [`${GH}/status.json`]: fixture('status-none.json'),
    })
    const result = await checkService(github, fetchJson, 5000)
    expect(calls).toEqual([
      `${GH}/status.json`,
      `${GH}/components.json`,
      `${GH}/incidents/unresolved.json`,
    ])
    expect(result).toMatchObject({
      checkedAt: 5000,
      id: 'github',
      level: 'critical',
      name: 'GitHub',
    })
    expect(result.incidents.map(i => i.name)).toEqual(['Git pushes fail', 'Slow webhooks'])
    expect(result.since).toBe(Date.parse('2026-11-06T09:00:00.000Z'))
    expect(result.error).toBeUndefined()
  })

  it('checkService for Sentry fetches no components', async () => {
    const base = 'https://status.sentry.io/api/v2'
    const { calls, fetchJson } = fake({
      [`${base}/incidents/unresolved.json`]: fixture('incidents-empty.json'),
      [`${base}/status.json`]: fixture('status-none.json'),
    })
    const result = await checkService(sentry, fetchJson, 1)
    expect(calls).toEqual([`${base}/status.json`, `${base}/incidents/unresolved.json`])
    expect(result.level).toBe('none')
  })

  it('checkService gives unknown when status.json fails or is not JSON', async () => {
    for (const value of [new Error('offline'), '<html>portal</html>']) {
      const { calls, fetchJson } = fake({ [`${GH}/status.json`]: value })
      const result = await checkService(github, fetchJson, 9)
      expect(result).toMatchObject({
        error: "The status page didn't answer.",
        incidents: [],
        level: 'unknown',
        since: null,
      })
      expect(calls).toEqual([`${GH}/status.json`])
    }
  })

  it('a failed incident list keeps the indicator', async () => {
    const { fetchJson } = fake({
      [`${GH}/components.json`]: fixture('components-github.json'),
      [`${GH}/status.json`]: fixture('status-minor.json'),
    })
    const result = await checkService(github, fetchJson, 1)
    expect(result).toMatchObject({ incidents: [], level: 'none' })
    // A failed components list keeps the indicator of status.json.
    const second = await checkService(
      github,
      fake({ [`${GH}/status.json`]: fixture('status-minor.json') }).fetchJson,
      1,
    )
    expect(second.level).toBe('minor')
  })
})
