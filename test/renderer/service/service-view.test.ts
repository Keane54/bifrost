import { describe, expect, it } from 'vitest'
import {
  checkedText,
  incidentLine,
  levelText,
} from '../../../src/renderer/src/service/service-view'

describe('service view', () => {
  it('levelText gives the texts', () => {
    expect(levelText('none')).toBe('Operational')
    expect(levelText('minor')).toBe('Minor issue')
    expect(levelText('major')).toBe('Major outage')
    expect(levelText('critical')).toBe('Critical outage')
    expect(levelText('maintenance')).toBe('Maintenance')
    expect(levelText('unknown')).toBe('No data')
  })

  it('incidentLine gives the name, the impact, the status and the duration', () => {
    const now = Date.parse('2026-11-06T10:05:00Z')
    const base = { impact: 'major' as const, name: 'API errors', rank: 2, status: 'investigating' }
    expect(incidentLine({ ...base, startedAt: Date.parse('2026-11-06T09:03:00Z') }, now)).toBe(
      'API errors - major (investigating), for 1 h 02 min',
    )
    expect(incidentLine({ ...base, startedAt: null }, now)).toBe(
      'API errors - major (investigating)',
    )
  })

  it('checkedText gives Not checked yet for 0', () => {
    expect(checkedText(0, 5)).toBe('Not checked yet.')
    expect(checkedText(Date.parse('2026-11-06T09:07:00Z'), 0, 'UTC')).toBe('Checked at 09:07.')
  })
})
