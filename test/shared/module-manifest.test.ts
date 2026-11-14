import { describe, expect, it } from 'vitest'
import {
  MODULE_ICONS,
  moduleTier,
  PHASE2_PERMISSION_IDS,
  parseManifest,
  permissionDiff,
} from '../../src/shared/module-manifest'

// A loose type, so a test can change any field.
// biome-ignore lint/suspicious/noExplicitAny: test data
type Loose = Record<string, any>

function valid(): Record<string, unknown> {
  return {
    description: 'Shows the usage.',
    id: 'usage-board',
    minBifrost: '0.5.0',
    name: 'Usage board',
    panels: [{ entry: 'panels/main.html', icon: 'chart-bar', id: 'main', title: 'Usage' }],
    permissions: [{ id: 'read-usage', reason: 'To show the numbers.' }],
    suggests: { dailyCap: 20, model: 'sonnet' },
    version: '1.0.0',
  }
}

function refuses(change: (m: Loose) => void, reason?: string): void {
  const m = valid() as Loose
  change(m)
  const result = parseManifest(m)
  expect(result.ok).toBe(false)
  if (reason && !result.ok) expect(result.reason).toBe(reason)
}

describe('parseManifest', () => {
  it('accepts a full valid manifest', () => {
    const result = parseManifest(valid())
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.manifest.id).toBe('usage-board')
      expect(result.manifest.suggests).toEqual({ dailyCap: 20, model: 'sonnet' })
      expect(moduleTier(result.manifest)).toBe('standard')
    }
  })
  it('gives empty suggestions when the manifest has none', () => {
    const m = valid()
    delete m.suggests
    const result = parseManifest(m)
    expect(result.ok && result.manifest.suggests).toEqual({ dailyCap: null, model: null })
  })
  it('refuses data that is not an object', () => {
    expect(parseManifest(null).ok).toBe(false)
    expect(parseManifest([]).ok).toBe(false)
  })
  it.each(['A', 'a', '1ab', 'ab_c', `a${'b'.repeat(40)}`, ''])('refuses the id %s', id => {
    refuses(m => {
      m.id = id
    })
  })
  it('refuses a long name and a long description', () => {
    refuses(m => {
      m.name = 'n'.repeat(41)
    })
    refuses(m => {
      m.description = 'd'.repeat(201)
    })
  })
  it('refuses 0 panels and more than 8 panels', () => {
    refuses(m => {
      m.panels = []
    })
    refuses(m => {
      m.panels = Array.from({ length: 9 }, (_, i) => ({
        entry: `panels/p${i}.html`,
        icon: 'chart-bar',
        id: `p${i}`,
        title: 'P',
      }))
    })
  })
  it('refuses a bad panel id', () => {
    refuses(m => {
      m.panels[0].id = 'Main'
    })
  })
  it.each([
    '/panels/a.html',
    'panels/../a.html',
    'panels/./a.html',
    'panels//a.html',
    'other/a.html',
    'panels/a.js',
    'panels/',
  ])('refuses the entry %s', entry => {
    refuses(m => {
      m.panels[0].entry = entry
    })
  })
  it('accepts an entry in a folder under panels', () => {
    const m = valid() as Loose
    m.panels[0].entry = 'panels/sub/a.html'
    expect(parseManifest(m).ok).toBe(true)
  })
  it('refuses an unknown icon', () => {
    refuses(m => {
      m.panels[0].icon = 'skull-and-bones'
    })
    expect(MODULE_ICONS.length).toBeGreaterThanOrEqual(15)
  })
  it('refuses a bad reason', () => {
    refuses(m => {
      m.permissions[0].reason = ''
    })
    refuses(m => {
      m.permissions[0].reason = 'r'.repeat(201)
    })
  })
  it('refuses a duplicate and an unknown permission', () => {
    refuses(m => {
      m.permissions.push({ id: 'read-usage', reason: 'Again.' })
    })
    refuses(m => {
      m.permissions[0].id = 'root'
    })
  })
  it('refuses a Phase 2 id with the newer version reason', () => {
    for (const id of PHASE2_PERMISSION_IDS) {
      refuses(m => {
        m.permissions[0].id = id
      }, 'This module needs a newer version of Bifrost.')
    }
    expect(PHASE2_PERMISSION_IDS).toHaveLength(8)
  })
  it('refuses a daily cap outside 1 to 500', () => {
    for (const cap of [0, 501, 1.5, '5']) {
      refuses(m => {
        m.suggests.dailyCap = cap
      })
    }
  })
  it('refuses a bad suggested model', () => {
    refuses(m => {
      m.suggests.model = 'gpt'
    })
  })
  it('refuses extra keys at each level', () => {
    refuses(m => {
      m.extra = 1
    })
    refuses(m => {
      m.panels[0].extra = 1
    })
    refuses(m => {
      m.permissions[0].extra = 1
    })
    refuses(m => {
      m.suggests.extra = 1
    })
  })
  it('refuses a bad version', () => {
    refuses(m => {
      m.version = 'one'
    })
    refuses(m => {
      m.minBifrost = ''
    })
  })
})

// A manifest text shows in Bifrost's own windows. A hidden or control character could hide or
// change the text that the user reads (fix round 1 of Task 6).
describe('hidden and control characters in a manifest text', () => {
  const HIDDEN = 'A text in the manifest has hidden or control characters.'
  const FIELDS: [string, (m: Loose, text: string) => void][] = [
    ['name', (m, t) => (m.name = t)],
    ['description', (m, t) => (m.description = t)],
    ['panel title', (m, t) => (m.panels[0].title = t)],
    ['permission reason', (m, t) => (m.permissions[0].reason = t)],
  ]
  const BAD: [string, string][] = [
    ['NUL (Cc)', '\u0000'],
    ['a bell (Cc)', '\u0007'],
    ['a new line (Cc)', '\n'],
    ['a carriage return (Cc)', '\r'],
    ['a tab (Cc)', '\t'],
    ['DEL (Cc)', '\u007f'],
    ['a C1 control (Cc)', '\u0085'],
    ['a soft hyphen (Cf)', '\u00ad'],
    ['a zero-width space (Cf)', '\u200b'],
    ['a zero-width joiner (Cf)', '\u200d'],
    ['a left-to-right mark (Cf)', '\u200e'],
    ['a right-to-left mark (Cf)', '\u200f'],
    ['a bidi embedding (Cf)', '\u202a'],
    ['a bidi override (Cf)', '\u202e'],
    ['a bidi isolate (Cf)', '\u2066'],
    ['a pop directional isolate (Cf)', '\u2069'],
    ['a word joiner (Cf)', '\u2060'],
    ['a byte order mark (Cf)', '\ufeff'],
    ['the tag U+E0000', '\u{e0000}'],
    ['a tag character (Cf)', '\u{e0041}'],
    ['the cancel tag (Cf)', '\u{e007f}'],
    ['a line separator', '\u2028'],
    ['a paragraph separator', '\u2029'],
    // These are not format characters, but they show as nothing (review of Task 10).
    ['a combining grapheme joiner', String.fromCodePoint(0x034f)],
    ['a Hangul choseong filler', String.fromCodePoint(0x115f)],
    ['a Hangul jungseong filler', String.fromCodePoint(0x1160)],
    ['a Hangul filler', String.fromCodePoint(0x3164)],
    ['a halfwidth Hangul filler', String.fromCodePoint(0xffa0)],
  ]
  for (const [field, set] of FIELDS) {
    it.each(BAD)(`refuses %s in the ${field}`, (_kind, char) => {
      refuses(m => set(m, `Board${char}x`), HIDDEN)
    })
  }
  it('refuses a name that has only Hangul fillers, so it cannot look empty', () => {
    refuses(m => {
      m.name = String.fromCodePoint(0x3164, 0x3164)
    }, HIDDEN)
  })

  it('accepts an emoji with a variation selector', () => {
    const m = valid() as Loose
    m.name = `Star ${String.fromCodePoint(0x2b50, 0xfe0f)} board`
    expect(parseManifest(m).ok).toBe(true)
  })

  it('accepts normal text, accents, emoji and a non-breaking space', () => {
    for (const [, set] of FIELDS) {
      const m = valid() as Loose
      set(m, 'Café board 📊 for teams\u00a0now')
      expect(parseManifest(m).ok).toBe(true)
    }
  })
})

describe('permissionDiff', () => {
  it('gives the added and removed ids', () => {
    const a = parseManifest(valid())
    const m = valid() as Loose
    m.permissions = [
      { id: 'notify', reason: 'To tell you.' },
      { id: 'discuss', reason: 'To talk.' },
    ]
    const b = parseManifest(m)
    if (!a.ok || !b.ok) throw new Error('bad fixture')
    const diff = permissionDiff(a.manifest, b.manifest)
    expect(diff.added.map(p => p.id)).toEqual(['notify', 'discuss'])
    expect(diff.removed).toEqual(['read-usage'])
  })
})
