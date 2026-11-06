import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { GENERAL_ROWS } from '../../../src/renderer/src/settings/general-rows'
import { keyGroups } from '../../../src/renderer/src/settings/key-editor'
import {
  focusLost,
  GENERAL_LABELS,
  keyMatches,
  noMatchText,
  resultCountText,
  SECTION_TITLES,
  type SearchHit,
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

  // Review Minor 3: the list shows Ctrl as ⌃, which looks like the caret ^ of the keyboard.
  it('finds a Ctrl key by the caret ^', () => {
    expect(keyMatches('Mod+Control+1', '^ ⌘ 1')).toBe(true)
    expect(keyMatches('Mod+Control+1', '^1')).toBe(true)
    expect(keyMatches('Mod+Control+F', '^')).toBe(true)
    expect(keyMatches('Mod+N', '^')).toBe(false)
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

  // Review Minor 4: each word can match the section title, the row label or the key.
  it('finds a row by a mix of the section title, the label and the key', () => {
    expect(searchSettings('keys take', sections)).toEqual([
      { id: 'keys', rows: ['take-control:mod'], title: 'Keys', whole: false },
    ])
    expect(searchSettings('general flash', sections)?.[0]?.rows).toEqual(['Row flash'])
    expect(searchSettings('take cmd', sections)?.[0]?.rows).toEqual(['take-control:mod'])
    expect(searchSettings('keys flash', sections)).toEqual([])
  })

  it('in a mix, a word of one character must be a key name, so a key search stays exact', () => {
    const keys: SearchSection[] = [
      {
        id: 'keys',
        rows: [
          { binding: 'Mod+Shift+T', id: 'take-control:mod', text: 'Take control' },
          {
            binding: 'Mod+Shift+O',
            id: 'open-project:mod',
            text: 'Open project in the default app',
          },
        ],
        title: 'Keys',
      },
    ]
    expect(searchSettings('cmd shift t', keys)?.[0]?.rows).toEqual(['take-control:mod'])
    expect(searchSettings('project cmd o', keys)?.[0]?.rows).toEqual(['open-project:mod'])
  })

  it('gives an empty list when nothing matches', () => {
    expect(searchSettings('xyz', sections)).toEqual([])
  })
})

describe('the texts and the keys of the search field', () => {
  // Review Minor 5: a live line tells a screen reader the number of matches.
  it('gives the count of the matching rows for a screen reader', () => {
    const hit = (rows: string[]): SearchHit => ({ id: 'keys', rows, title: 'Keys', whole: false })
    expect(resultCountText(null, '')).toBe('')
    expect(resultCountText([], 'xyz')).toBe('No settings match "xyz".')
    expect(resultCountText([hit(['a'])], 'a')).toBe('1 setting matches.')
    expect(resultCountText([hit(['a', 'b']), hit(['c'])], 'a')).toBe('3 settings match.')
  })

  // Review Minor 6: a change of a setting can remove the result that has the focus.
  it('the focus needs a new place only when the last focused result went away', () => {
    const body = { isConnected: true }
    const removed = { isConnected: false }
    const present = { isConnected: true }
    expect(focusLost(removed, body, body)).toBe(true)
    expect(focusLost(removed, null, body)).toBe(true)
    // The focus is already in another place.
    expect(focusLost(removed, present, body)).toBe(false)
    expect(focusLost(present, body, body)).toBe(false)
    expect(focusLost(null, body, body)).toBe(false)
  })

  it('names the query in the no-match line', () => {
    expect(noMatchText('  xyz ')).toBe('No settings match "xyz".')
  })

  it('Esc clears a query first, and closes Settings from an empty field', () => {
    expect(searchEscape('flash', false)).toBe('clear')
    expect(searchEscape('', false)).toBe('close')
  })

  // Review Minor 2: during an IME composition, Esc cancels the composition only.
  it('Esc does nothing more during an IME composition', () => {
    expect(searchEscape('flash', true)).toBe('ignore')
    expect(searchEscape('', true)).toBe('ignore')
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

// Review Important 1: the labels of Settings > General have one source, GENERAL_ROWS. The
// repository has no DOM test, so this check reads the source text of Settings > General and of
// each local file that it imports, at each depth. Each tag whose name ends with "Row" must have
// the label GENERAL_ROWS.<name>, or pass on props.label in a row component. The check fails on
// each other form. So a new row needs one line in GENERAL_ROWS, or this test fails.
describe('GENERAL_ROWS', () => {
  // The source files of Settings > General: GeneralSection.tsx and its local imports.
  function generalFiles(): { name: string; text: string }[] {
    const files: { name: string; text: string }[] = []
    const queue = ['GeneralSection']
    const seen = new Set<string>()
    while (queue.length > 0) {
      const base = queue.shift() as string
      if (seen.has(base)) continue
      seen.add(base)
      const path = ['.tsx', '.ts'].map(ext => join(SETTINGS, base + ext)).find(existsSync)
      if (path === undefined) throw new Error(`No source file for ./${base}`)
      const text = readFileSync(path, 'utf8')
      files.push({ name: base, text })
      for (const match of text.matchAll(/from '\.\/([\w-]+)'/g)) queue.push(match[1])
    }
    return files
  }

  // The text of each JSX tag whose name ends with "Row". The scan skips braces and quotes, so an
  // arrow function in a prop does not end the tag.
  function rowTags(text: string): { name: string; tag: string }[] {
    const tags: { name: string; tag: string }[] = []
    for (const match of text.matchAll(/<([A-Z]\w*Row)\b/g)) {
      let depth = 0
      let quote: string | null = null
      let i = match.index + match[0].length
      for (; i < text.length; i++) {
        const c = text[i]
        if (quote !== null) {
          if (c === quote) quote = null
        } else if (c === "'" || c === '"' || c === '`') {
          quote = c
        } else if (c === '{') {
          depth++
        } else if (c === '}') {
          depth--
        } else if (c === '>' && depth === 0) {
          break
        }
      }
      tags.push({ name: match[1], tag: text.slice(match.index, i + 1) })
    }
    return tags
  }

  // The names of the GENERAL_ROWS constants that the rows use, and each row tag that breaks the
  // rule.
  function readRows(files: { name: string; text: string }[]): { used: string[]; bad: string[] } {
    const used: string[] = []
    const bad: string[] = []
    const components = new Set(
      files.flatMap(f => [...f.text.matchAll(/function ([A-Z]\w*Row)\b/g)].map(m => m[1])),
    )
    for (const file of files) {
      for (const { name, tag } of rowTags(file.text)) {
        const label = tag.match(/(?<![\w-])label=(\{[^}]*\}|'[^']*'|"[^"]*")/)
        if (label === null) {
          // A row component with no label prop has its rows in a scanned file.
          if (!components.has(name) && !files.some(f => f.name === name)) {
            bad.push(`${file.name}: ${name} has no label`)
          }
          continue
        }
        const constant = label[1].match(/^\{GENERAL_ROWS\.(\w+)\}$/)
        if (constant !== null) used.push(constant[1])
        else if (label[1] !== '{props.label}') bad.push(`${file.name}: ${name} label=${label[1]}`)
      }
    }
    return { bad, used }
  }

  it('each row of Settings > General has its label from GENERAL_ROWS', () => {
    const { bad, used } = readRows(generalFiles())
    expect(bad).toEqual([])
    expect(new Set(used)).toEqual(new Set(Object.keys(GENERAL_ROWS)))
    expect([...GENERAL_LABELS].sort()).toEqual(Object.values(GENERAL_ROWS).sort())
    expect(GENERAL_LABELS).toHaveLength(15)
  })

  it('fails on a row label in another form, also in a row of a new file (guard)', () => {
    const main = {
      name: 'GeneralSection',
      text: '<CheckRow label={GENERAL_ROWS.rowFlash} save={value => update({ a: value })} />',
    }
    expect(readRows([main]).bad).toEqual([])
    const literal = { ...main, text: "<ToggleRow label='Animated background' />" }
    expect(readRows([literal]).bad).toEqual([
      "GeneralSection: ToggleRow label='Animated background'",
    ])
    const constant = { ...main, text: '<SettingRow label={USAGE_LABEL}>' }
    expect(readRows([constant]).bad).toEqual(['GeneralSection: SettingRow label={USAGE_LABEL}'])
    const usage = { name: 'UsageRow', text: "<SettingRow label='Account usage from Anthropic'>" }
    const withFile = [{ ...main, text: '<UsageRow />' }, usage]
    expect(readRows(withFile).bad).toEqual([
      "UsageRow: SettingRow label='Account usage from Anthropic'",
    ])
    expect(readRows([{ ...main, text: '<UsageRow />' }]).bad).toEqual([
      'GeneralSection: UsageRow has no label',
    ])
  })
})
