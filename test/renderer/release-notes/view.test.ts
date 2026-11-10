import { describe, expect, it } from 'vitest'
import {
  formatReleaseDate,
  internalOnly,
  type ReleaseNotesView,
  viewReleases,
  viewTitle,
  whatsNewMayOpen,
} from '../../../src/renderer/src/release-notes/view'
import type { Release } from '../../../src/shared/release-notes'

function release(version: string, more: Partial<Release> = {}): Release {
  return {
    date: '2026-11-10T18:10:26Z',
    sections: [{ items: [{ scope: null, text: 'x' }], title: 'New' }],
    summary: '',
    url: `https://github.com/Keane54/bifrost/releases/tag/v${version}`,
    version,
    ...more,
  }
}

const ALL: ReleaseNotesView = { kind: 'all' }
const WHATS_NEW: ReleaseNotesView = {
  kind: 'whats-new',
  start: { since: '0.4.0', version: '0.5.1' },
}

describe('viewTitle', () => {
  it("names the view What's new when it opens by itself, and Release notes else", () => {
    expect(viewTitle(WHATS_NEW)).toBe("What's new")
    expect(viewTitle(ALL)).toBe('Release notes')
  })
})

describe('viewReleases', () => {
  const list = ['0.6.0', '0.5.1', '0.5.0', '0.4.0', '0.3.0'].map(v => release(v))

  it("gives the releases after the last seen version in What's new", () => {
    expect(viewReleases(WHATS_NEW, list).map(r => r.version)).toEqual(['0.5.1', '0.5.0'])
  })

  it('gives at most 10 releases in Release notes', () => {
    const many = Array.from({ length: 12 }, (_, i) => release(`0.${12 - i}.0`))
    expect(viewReleases(ALL, many)).toHaveLength(10)
    expect(viewReleases(ALL, list)).toEqual(list)
  })
})

describe('internalOnly', () => {
  it('is true for a release with no summary and no shown section', () => {
    expect(internalOnly(release('0.4.0', { sections: [] }))).toBe(true)
    expect(internalOnly(release('0.4.0', { sections: [], summary: 'Hi.' }))).toBe(false)
    expect(internalOnly(release('0.4.0'))).toBe(false)
  })
})

describe('formatReleaseDate', () => {
  it('gives the day, the month and the year', () => {
    expect(formatReleaseDate('2026-11-10T18:10:26Z', 'UTC')).toBe('10 Nov 2026')
    expect(formatReleaseDate('2026-11-10T23:30:00Z', 'Asia/Tokyo')).toBe('11 Nov 2026')
  })

  it('gives an empty text for a date that it cannot read', () => {
    expect(formatReleaseDate('not a date', 'UTC')).toBe('')
  })
})

describe('whatsNewMayOpen', () => {
  it('waits for the settings and for the end of the setup dialog', () => {
    expect(whatsNewMayOpen(false, true)).toBe(false)
    expect(whatsNewMayOpen(true, false)).toBe(false)
    expect(whatsNewMayOpen(true, true)).toBe(true)
  })
})
