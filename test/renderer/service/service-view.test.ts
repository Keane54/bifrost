import { describe, expect, it } from 'vitest'
import {
  checkedText,
  incidentLine,
  levelText,
  serviceView,
  sinceText,
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

describe('sinceText (final wave item 11)', () => {
  const now = Date.parse('2026-11-06T10:05:00Z')
  const today = Date.parse('2026-11-06T09:03:00Z')
  const before = Date.parse('2026-11-04T22:15:00Z')

  it('a level that is not ok shows the start of its incident', () => {
    expect(sinceText('major', today, now, 'UTC')).toBe('since 09:03')
    expect(sinceText('minor', today, now, 'UTC')).toBe('since 09:03')
    expect(sinceText('critical', before, now, 'UTC')).toBe('since Wed 22:15')
    expect(sinceText('maintenance', today, now, 'UTC')).toBe('since 09:03')
  })

  it('ok, No data and an unknown start show nothing', () => {
    expect(sinceText('none', today, now, 'UTC')).toBeNull()
    expect(sinceText('unknown', today, now, 'UTC')).toBeNull()
    expect(sinceText('major', null, now, 'UTC')).toBeNull()
  })
})

// User decision, 2026-11-06: three views of a service row by width. needs gives the width that the widest
// row needs in the full view, then without the text of the status page button.
describe('serviceView', () => {
  const NEEDS = [400, 290] as const

  it('gives the full view when the widest row fits', () => {
    expect(serviceView(520, NEEDS)).toBe(0)
    expect(serviceView(400, NEEDS)).toBe(0)
  })

  it('hides the button text when the full view does not fit, but that view does', () => {
    expect(serviceView(399, NEEDS)).toBe(1)
    expect(serviceView(290, NEEDS)).toBe(1)
  })

  it('also hides the level text when the view without button text does not fit', () => {
    expect(serviceView(289, NEEDS)).toBe(2)
    expect(serviceView(120, NEEDS)).toBe(2)
  })

  it('goes back to a fuller view when the panel gets wider again', () => {
    const views = [200, 300, 450].map(w => serviceView(w, NEEDS))
    expect(views).toEqual([2, 1, 0])
  })

  it('gives the full view for a panel with no rows', () => {
    expect(serviceView(100, [0, 0])).toBe(0)
  })
})
