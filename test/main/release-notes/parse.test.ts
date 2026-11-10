import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  MAX_RELEASES,
  parseReleaseBody,
  parseReleases,
  SHOWN_SECTIONS,
  shownSections,
  splitBody,
} from '../../../src/main/release-notes/parse'

// The real v0.4.0 release of GitHub, with no summary.
const V040 = JSON.parse(
  readFileSync(join(__dirname, '../../fixtures/releases/v0.4.0.json'), 'utf8'),
) as Record<string, unknown> & { body: string }

const SUMMARY = [
  'Bifrost now warns you before you reach a usage limit,',
  'and the Performance panel has a Clear button.',
].join(' ')

const REPO = 'https://github.com/Keane54/bifrost'
const SHA = '89540644c324fa5286'

// A body as semantic-release writes it with a summary: the summary, a blank line, then the notes.
const WITH_SUMMARY = [
  SUMMARY,
  '',
  `## [0.5.0](${REPO}/compare/v0.4.0...v0.5.0) (2026-11-12)`,
  '',
  '### Features',
  '',
  `* **usage:** show a notification when a usage limit gets to 90% ([8954064](${REPO}/c/${SHA}))`,
  `* add the What's new view ([1234567](${REPO}/commit/1234567aaaa))`,
  '',
  '### Chores',
  '',
  `* **deps:** update electron ([abcdef0](${REPO}/commit/abcdef0))`,
  '',
].join('\n')

describe('splitBody', () => {
  it('reads each section and item of the real v0.4.0 body', () => {
    const { summary, sections } = splitBody(V040.body)
    expect(summary).toBe('')
    expect(sections.map(s => [s.title, s.items.length])).toEqual([
      ['Features', 7],
      ['Bug Fixes', 5],
      ['Documentation', 1],
      ['Code Refactoring', 2],
      ['Tests', 3],
    ])
    expect(sections[0]?.items[0]).toEqual({
      scope: 'overview',
      text: 'show the approximate mark on the session cost',
    })
    expect(sections[1]?.items[4]).toEqual({
      scope: 'usage',
      text: 'keep a known extra usage flag of the account values',
    })
  })

  it('keeps no commit hash and no link of an item', () => {
    const { sections } = splitBody(V040.body)
    for (const item of sections.flatMap(s => s.items)) {
      expect(item.text).not.toMatch(/github\.com|\]\(|\(\[|[0-9a-f]{7}/)
    }
  })

  it('reads the summary before the first heading, and an item with no scope', () => {
    const { summary, sections } = splitBody(WITH_SUMMARY)
    expect(summary).toBe(SUMMARY)
    expect(sections[0]?.items[1]).toEqual({ scope: null, text: "add the What's new view" })
  })

  it('reads a summary of more lines, with Windows line ends, up to a ### heading', () => {
    const body =
      'First line.\r\nSecond line.\r\n\r\n### Bug Fixes\r\n\r\n* fix a thing ([abc1234](u))\r\n'
    expect(splitBody(body)).toEqual({
      sections: [{ items: [{ scope: null, text: 'fix a thing' }], title: 'Bug Fixes' }],
      summary: 'First line.\nSecond line.',
    })
  })

  it('drops the closes part after the commit link, and keeps an item with no link', () => {
    const body = [
      '### Bug Fixes',
      '* **chat:** keep the scroll ([abc1234](https://x/c/abc1234)), closes [#12](https://x/12)',
      '- a line with a dash and no link',
    ].join('\n')
    expect(splitBody(body).sections[0]?.items).toEqual([
      { scope: 'chat', text: 'keep the scroll' },
      { scope: null, text: 'a line with a dash and no link' },
    ])
  })

  it('ignores the text of a section that is not an item, and an empty item', () => {
    const body = '### Features\n\nSome text.\n*  \n  * an indented line\n* real item\n'
    expect(splitBody(body).sections).toEqual([
      { items: [{ scope: null, text: 'real item' }], title: 'Features' },
    ])
  })

  it('gives an empty result for an empty body', () => {
    expect(splitBody('')).toEqual({ sections: [], summary: '' })
  })
})

describe('shownSections', () => {
  it('shows the five sections with their friendly names, breaking changes first', () => {
    expect(SHOWN_SECTIONS).toEqual({
      'BREAKING CHANGES': 'Changed',
      'Bug Fixes': 'Fixed',
      Features: 'New',
      'Performance Improvements': 'Faster',
      Reverts: 'Reverted',
      '⚠ BREAKING CHANGES': 'Changed',
    })
    const item = { scope: null, text: 'x' }
    const all = [
      'Features',
      'Bug Fixes',
      'Performance Improvements',
      'Reverts',
      'Documentation',
      'Code Refactoring',
      'Tests',
      'Chores',
      'Miscellaneous',
      'Continuous Integration',
      'Build System',
      'Styles',
      '⚠ BREAKING CHANGES',
      'Something else',
    ].map(title => ({ items: [item], title }))
    expect(shownSections(all).map(s => s.title)).toEqual([
      'Changed',
      'New',
      'Fixed',
      'Faster',
      'Reverted',
    ])
  })

  it('shows a BREAKING CHANGES section with no sign as Changed too', () => {
    const item = { scope: null, text: 'x' }
    const sections = ['Bug Fixes', 'BREAKING CHANGES'].map(title => ({ items: [item], title }))
    expect(shownSections(sections).map(s => s.title)).toEqual(['Changed', 'Fixed'])
  })

  it('hides a shown section with no item', () => {
    expect(shownSections([{ items: [], title: 'Features' }])).toEqual([])
  })
})

describe('parseReleaseBody', () => {
  it('gives the summary and only the shown sections of the real v0.4.0 body', () => {
    const notes = parseReleaseBody(V040.body)
    expect(notes.summary).toBe('')
    expect(notes.sections.map(s => [s.title, s.items.length])).toEqual([
      ['New', 7],
      ['Fixed', 5],
    ])
  })

  it('shows the breaking changes of a body as Changed, before New and Fixed', () => {
    // The conventionalcommits preset writes a breaking change with no commit link.
    const body = [
      `## [1.0.0](${REPO}/compare/v0.5.0...v1.0.0) (2026-11-12)`,
      '',
      '### Features',
      '',
      `* **sessions:** add the new list ([1234567](${REPO}/c/1234567))`,
      '',
      '### ⚠ BREAKING CHANGES',
      '',
      '* **sessions:** Bifrost now needs Claude Code 2.2 or later.',
      '',
      '### Bug Fixes',
      '',
      `* keep the panel open ([2345678](${REPO}/c/2345678))`,
      '',
    ].join('\n')
    expect(parseReleaseBody(body).sections).toEqual([
      {
        items: [{ scope: 'sessions', text: 'Bifrost now needs Claude Code 2.2 or later.' }],
        title: 'Changed',
      },
      { items: [{ scope: 'sessions', text: 'add the new list' }], title: 'New' },
      { items: [{ scope: null, text: 'keep the panel open' }], title: 'Fixed' },
    ])
  })

  it('gives the summary and the shown sections of a body with a summary', () => {
    expect(parseReleaseBody(WITH_SUMMARY)).toEqual({
      sections: [
        {
          items: [
            { scope: 'usage', text: 'show a notification when a usage limit gets to 90%' },
            { scope: null, text: "add the What's new view" },
          ],
          title: 'New',
        },
      ],
      summary: SUMMARY,
    })
  })
})

describe('parseReleases', () => {
  const entry = (tag: string, more: Record<string, unknown> = {}): Record<string, unknown> => ({
    body: '### Bug Fixes\n\n* fix ([abc1234](u))\n',
    draft: false,
    html_url: `https://github.com/Keane54/bifrost/releases/tag/${tag}`,
    prerelease: false,
    published_at: '2026-11-10T18:10:26Z',
    tag_name: tag,
    ...more,
  })

  it('reads the real v0.4.0 release', () => {
    expect(parseReleases([V040])).toEqual([
      {
        date: '2026-11-10T18:10:26Z',
        sections: parseReleaseBody(V040.body).sections,
        summary: '',
        url: 'https://github.com/Keane54/bifrost/releases/tag/v0.4.0',
        version: '0.4.0',
      },
    ])
  })

  it('gives null for an answer that is not a list', () => {
    for (const bad of [null, undefined, {}, 'x', 7, { releases: [] }]) {
      expect(parseReleases(bad)).toBeNull()
    }
  })

  it('skips drafts, prereleases and entries that it cannot read', () => {
    const list = parseReleases([
      entry('v0.5.0', { draft: true }),
      entry('v0.4.2', { prerelease: true }),
      entry('v0.4.1-beta.1'),
      entry('latest'),
      entry('v0.4.0', { published_at: 'not a date' }),
      entry('v0.3.0', { html_url: 'https://example.com/releases/tag/v0.3.0' }),
      entry('v0.2.0', { html_url: 'https://github.com/someone/else/releases/tag/v0.2.0' }),
      entry('v0.1.0', { tag_name: 7 }),
      null,
      'x',
      entry('v0.0.9'),
    ])
    expect(list?.map(r => r.version)).toEqual(['0.0.9'])
  })

  it('reads a null body as an empty body', () => {
    expect(parseReleases([entry('v0.1.0', { body: null })])?.[0]).toMatchObject({
      sections: [],
      summary: '',
    })
  })

  it('puts the newest version first and keeps at most 10 releases', () => {
    const tags = Array.from({ length: 12 }, (_, i) => `v0.${i}.0`)
    const list = parseReleases(tags.map(tag => entry(tag)))
    expect(MAX_RELEASES).toBe(10)
    expect(list?.map(r => r.version)).toEqual(Array.from({ length: 10 }, (_, i) => `0.${11 - i}.0`))
  })
})
