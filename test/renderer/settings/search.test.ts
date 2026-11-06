import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { keyGroups } from '../../../src/renderer/src/settings/key-editor'
import {
  GENERAL_LABELS,
  keyMatches,
  noMatchText,
  SECTION_TITLES,
  type SearchSection,
  searchEscape,
  searchSettings,
  searchShortcut,
  settingsIndex,
  textMatches,
} from '../../../src/renderer/src/settings/search'

const SETTINGS = join(__dirname, '../../../src/renderer/src/settings')

describe('textMatches', () => {
  it('matches each word of the query, case-insensitive, in any order', () => {
    expect(textMatches('Row flash', 'flash')).toBe(true)
    expect(textMatches('Row flash', 'FLASH row')).toBe(true)
    expect(textMatches('Sound for a red box', 'box  red')).toBe(true)
    expect(textMatches('Default app for "Open project"', 'open proj')).toBe(true)
    expect(textMatches('Row flash', 'flash sound')).toBe(false)
  })

  it('an empty query matches nothing', () => {
    expect(textMatches('Row flash', '   ')).toBe(false)
  })
})

describe('keyMatches', () => {
  it('matches the shown form, with or without spaces, in any order', () => {
    expect(keyMatches('Mod+Shift+T', '⇧ ⌘ T')).toBe(true)
    expect(keyMatches('Mod+Shift+T', '⌘⇧T')).toBe(true)
    expect(keyMatches('Mod+Alt+Shift+Backspace', '⌥ ⇧ ⌘ ⌫')).toBe(true)
    expect(keyMatches('Mod+Enter', '⌘↵')).toBe(true)
  })

  it('matches a typed form with spaces or with +', () => {
    expect(keyMatches('Mod+Shift+T', 'cmd shift t')).toBe(true)
    expect(keyMatches('Mod+Shift+T', 'cmd+shift+t')).toBe(true)
    expect(keyMatches('Mod+Shift+T', 'Command + Shift + T')).toBe(true)
    expect(keyMatches('Mod+,', 'cmd+,')).toBe(true)
    expect(keyMatches('Escape', 'esc')).toBe(true)
    expect(keyMatches('Enter', 'return')).toBe(true)
    expect(keyMatches('ArrowUp', 'up')).toBe(true)
  })

  it('matches one modifier alone, by its short name or its symbol', () => {
    expect(keyMatches('Mod+Control+1', 'ctrl')).toBe(true)
    expect(keyMatches('Mod+Control+1', '⌃')).toBe(true)
    expect(keyMatches('Mod+Alt+Shift+Backspace', 'opt')).toBe(true)
    expect(keyMatches('Mod+Alt+S', 'option')).toBe(true)
    expect(keyMatches('Mod+N', 'ctrl')).toBe(false)
  })

  it('a single letter must be the key itself, and a longer word can be the start of a name', () => {
    expect(keyMatches('Mod+Shift+Tab', 'cmd shift t')).toBe(false)
    expect(keyMatches('Mod+Shift+Tab', 'cmd shift ta')).toBe(true)
    expect(keyMatches('Mod+Shift+T', 'cmd shift ta')).toBe(false)
    expect(keyMatches('Mod+Shift+T', 'cmd shift r')).toBe(false)
    expect(keyMatches('Shift+Backspace', 'sh back')).toBe(true)
  })

  it('no key and an empty query never match', () => {
    expect(keyMatches(null, 'cmd')).toBe(false)
    expect(keyMatches('Mod+N', '  ')).toBe(false)
  })
})

describe('the index of all sections', () => {
  const index = settingsIndex({
    keys: keyGroups({}, 'plain'),
    live: ['Live details', 'Off.', 'Turn on', 'Remove'],
    slash: ['/compact', '/clear'],
  })

  it('has the four sections in the order of the tabs, with their titles', () => {
    expect(index.map(s => s.id)).toEqual(['general', 'slash', 'keys', 'live'])
    expect(index.map(s => s.title)).toEqual(['General', 'Slash commands', 'Keys', 'Live details'])
    expect(SECTION_TITLES.keys).toBe('Keys')
  })

  it('has a row for each General label, slash command and key slot, and one Live details row', () => {
    expect(index[0].rows.map(r => r.id)).toEqual([...GENERAL_LABELS])
    expect(index[1].rows.map(r => r.id)).toEqual(['/compact', '/clear'])
    expect(index[2].rows).toHaveLength(83)
    expect(index[2].rows.find(r => r.id === 'take-control:mod')).toEqual({
      binding: 'Mod+Shift+T',
      id: 'take-control:mod',
      text: 'Take control',
    })
    expect(index[3].rows).toEqual([{ id: 'live', text: 'Live details Off. Turn on Remove' }])
  })
})

describe('searchSettings', () => {
  const sections: SearchSection[] = [
    {
      id: 'general',
      rows: [
        { id: 'Row flash', text: 'Row flash' },
        { id: 'Default app for "Open project"', text: 'Default app for "Open project"' },
      ],
      title: 'General',
    },
    { id: 'slash', rows: [{ id: '/compact', text: '/compact' }], title: 'Slash commands' },
    {
      id: 'keys',
      rows: [
        { binding: 'Mod+Enter', id: 'open:mod', text: 'Open' },
        { binding: 'Mod+Shift+T', id: 'take-control:mod', text: 'Take control' },
        { binding: null, id: 'copy-id:key', text: 'Copy session ID' },
      ],
      title: 'Keys',
    },
    {
      id: 'live',
      rows: [{ id: 'live', text: 'Live details On. Turn off' }],
      title: 'Live details',
    },
  ]

  it('gives null for an empty query, so the tabs show', () => {
    expect(searchSettings('', sections)).toBeNull()
    expect(searchSettings('   ', sections)).toBeNull()
  })

  it('groups the matches by section, in the order of the tabs, and hides a section with none', () => {
    expect(searchSettings('open', sections)).toEqual([
      { id: 'general', rows: ['Default app for "Open project"'], title: 'General', whole: false },
      { id: 'keys', rows: ['open:mod'], title: 'Keys', whole: false },
    ])
  })

  it('finds a key row by its key or by its command label', () => {
    expect(searchSettings('cmd shift t', sections)).toEqual([
      { id: 'keys', rows: ['take-control:mod'], title: 'Keys', whole: false },
    ])
    expect(searchSettings('control take', sections)?.[0]?.rows).toEqual(['take-control:mod'])
  })

  it('shows a whole section when the query matches its title', () => {
    const hits = searchSettings('slash', sections)
    expect(hits).toEqual([
      { id: 'slash', rows: ['/compact'], title: 'Slash commands', whole: true },
    ])
    expect(searchSettings('turn', sections)?.map(h => h.id)).toEqual(['live'])
  })

  it('gives an empty list when nothing matches', () => {
    expect(searchSettings('xyz', sections)).toEqual([])
  })
})

describe('the texts and the keys of the search field', () => {
  it('names the query in the no-match line', () => {
    expect(noMatchText('  xyz ')).toBe('No settings match "xyz".')
  })

  it('Esc clears a query first, and closes Settings from an empty field', () => {
    expect(searchEscape('flash')).toBe('clear')
    expect(searchEscape('')).toBe('close')
  })

  it('Cmd+F moves the focus to the search field while Settings has the focus', () => {
    const cmdF = { altKey: false, ctrlKey: false, key: 'f', metaKey: true, shiftKey: false }
    expect(searchShortcut(cmdF, 'settings', false)).toBe(true)
    expect(searchShortcut({ ...cmdF, key: 'F' }, 'settings', false)).toBe(true)
    // With no focus, Settings must be the front panel.
    expect(searchShortcut(cmdF, 'none', true)).toBe(true)
    expect(searchShortcut(cmdF, 'none', false)).toBe(false)
    expect(searchShortcut(cmdF, 'other', true)).toBe(false)
    expect(searchShortcut({ ...cmdF, shiftKey: true }, 'settings', false)).toBe(false)
    expect(searchShortcut({ ...cmdF, ctrlKey: true }, 'settings', false)).toBe(false)
    expect(searchShortcut({ ...cmdF, metaKey: false }, 'settings', false)).toBe(false)
    expect(searchShortcut({ ...cmdF, key: 'g' }, 'settings', false)).toBe(false)
  })
})

// The repository has no DOM test. So this check reads the source text: the search finds each
// row of Settings > General only when its label is in GENERAL_LABELS.
describe('GENERAL_LABELS', () => {
  it('has the label of each row of Settings > General, in order', () => {
    const labels: string[] = []
    for (const file of ['GeneralSection.tsx', 'IntroRow.tsx']) {
      const text = readFileSync(join(SETTINGS, file), 'utf8')
      const rows = text.matchAll(/<(?:SettingRow|CheckRow|NumberRow|SelectRow)\b/g)
      for (const row of rows) {
        const rest = text.slice(row.index)
        const label = rest.match(/(?<![\w-])label=(?:'([^']*)'|\{props\.label\})/)
        if (label?.[1] !== undefined) labels.push(label[1])
      }
    }
    expect(labels).toEqual([...GENERAL_LABELS])
  })
})
