import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { WATCH_COLOURS } from '../../src/shared/watch'

const WATCH_NAMES: readonly string[] = WATCH_COLOURS
// The Overview table sits on the panel. The row background is the watch colour over this.
// The unfocused panel is about rgb(24 24 24). The focused panel is rgb(8 8 8).
const PANELS = ['#181818', '#080808']

function token(name: string): string {
  const match = CSS.match(new RegExp(`--color-${name}:\\s*(#[0-9a-fA-F]{6})`))
  if (!match) throw new Error(`No hex token ${name}`)
  return match[1]
}

function rgb(hex: string): [number, number, number] {
  return [1, 3, 5].map(i => Number.parseInt(hex.slice(i, i + 2), 16)) as [number, number, number]
}

function hex(channels: number[]): string {
  return `#${channels.map(c => Math.round(c).toString(16).padStart(2, '0')).join('')}`
}

// The colour over the background at the opacity.
function mix(over: string, opacity: number, under: string): string {
  const a = rgb(over)
  const b = rgb(under)
  return hex(a.map((c, i) => c * opacity + b[i] * (1 - opacity)))
}

function hsl(colour: string): { h: number; l: number } {
  const [r, g, b] = rgb(colour).map(c => c / 255)
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  const d = max - min
  let h = 0
  if (d !== 0) {
    if (max === r) h = ((g - b) / d) % 6
    else if (max === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
  }
  return { h: (h * 60 + 360) % 360, l: ((max + min) / 2) * 100 }
}

function luminance(colour: string): number {
  const [r, g, b] = rgb(colour).map(c => {
    const v = c / 255
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
  })
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}

// The opacity of the row background, from the class names in watch-colours.ts.
function watchRowOpacity(): number {
  const found = [...source('watch/watch-colours.ts').matchAll(/bg-watch-[\w-]+\/(\d+)'/g)]
  const values = new Set(found.map(m => Number(m[1])))
  if (values.size !== 1) throw new Error('The watch row classes need one opacity')
  return [...values][0] / 100
}

const SRC = join(__dirname, '../../src/renderer/src')
const CSS = readFileSync(join(SRC, 'styles/app.css'), 'utf8')

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) return sourceFiles(path)
    return /\.tsx?$/.test(entry.name) ? [path] : []
  })
}

const FILES = sourceFiles(SRC).map(path => ({ path, text: readFileSync(path, 'utf8') }))

function source(name: string): string {
  const file = FILES.find(f => f.path.endsWith(name))
  if (!file) throw new Error(`No source file ${name}`)
  return file.text
}

const TOKENS = [
  'bg',
  'panel',
  'panel-edge',
  'title',
  'section',
  'text',
  'text-dim',
  'text-strong',
  'select',
  'hover',
  'snap',
  'accent',
  'accent-glow',
  'panel-focus',
  'watch-dark-red',
  'watch-red',
  'watch-amber',
  'watch-yellow',
  'watch-green',
  'watch-light-blue',
  'watch-dark-blue',
  'watch-white',
]

// The class parts that can use the light cyan accent (spec 8.10): the top border of a frame,
// its glow, and the press feedback of an active: state. The selected row gets the accent
// through the --color-select token in app.css.
const ACCENT_CLASSES = [
  /^border-t-accent$/,
  /^--color-accent-glow$/,
  /^border-t-accent\/35$/,
  /^shadow-\[0_-6px_12px_-6px_var\(--color-accent-glow\)\]'?$/,
  /^(?:[a-z-]+:)*active:bg-accent\/12$/,
]
const PRESS = /(?:^|\s|')(?:[a-z-]+:)*active:bg-accent\/12(?:\s|'|$)/

// The words that contain the part "accent", for example a class or a token name.
function accentParts(text: string): string[] {
  return text.match(/[\w:/.[\]-]*accent[\w:/.[\]-]*/gi) ?? []
}

describe('theme', () => {
  it.each(TOKENS)('defines --color-%s', token => {
    expect(CSS).toMatch(new RegExp(`--color-${token}:`))
  })

  it('defines the light cyan accent and its glow', () => {
    expect(CSS).toContain('--color-accent: #8fdcec;')
    expect(CSS).toContain('--color-accent-glow: rgb(143 220 236 / 0.28);')
  })

  it('gives the selected row the accent at 15%', () => {
    expect(CSS).toContain(
      '--color-select: color-mix(in oklab, var(--color-accent) 15%, transparent);',
    )
  })

  it('has no hex colour or rgb( in a .ts or .tsx file', () => {
    const bad = FILES.filter(f => /#[0-9a-fA-F]{3,8}\b|rgba?\(/.test(f.text)).map(f => f.path)
    expect(bad).toEqual([])
  })

  it('uses the accent class part only for the top border, the glow and active: states', () => {
    const bad = FILES.flatMap(f =>
      accentParts(f.text)
        .filter(part => !ACCENT_CLASSES.some(allowed => allowed.test(part)))
        .map(part => `${f.path}: ${part}`),
    )
    expect(bad).toEqual([])
  })

  it('gives the frame the cyan top border and the glow', () => {
    const frame = source('wm/Frame.tsx')
    for (const part of ['border-t-accent', 'border-t-accent/35']) {
      expect(accentParts(frame)).toContain(part)
    }
    // The glow is a shadow above the top edge only (user decision, 2026-11-05).
    expect(frame).toContain('shadow-[0_-6px_12px_-6px_var(--color-accent-glow)]')
  })

  // Bug 8: the focused panel must be darker than the others, not lighter.
  it('makes the focused panel darker than the other panels', () => {
    expect(CSS).toContain('--color-panel: rgb(24 24 24 / var(--panel-alpha));')
    const level = (token: string): number => {
      const match = CSS.match(new RegExp(`--color-${token}: rgb\\((\\d+) `))
      return Number(match?.[1])
    }
    expect(level('panel-focus')).toBeLessThan(level('panel'))
  })

  // Bug 9: a focus ring is a square 1 px accent outline with no offset (spec 8.10).
  it('has one focus-visible rule: a 1 px accent outline with no offset', () => {
    const rules = [...CSS.matchAll(/:focus-visible\s*\{([^}]*)\}/g)]
    expect(rules).toHaveLength(1)
    const body = rules[0][1].replace(/\s+/g, ' ').trim()
    expect(body).toBe('outline: 1px solid var(--color-accent); outline-offset: 0;')
  })

  // The rule is in the base layer, so a utility like outline-none wins over it. So a focusable
  // field, the check box and the select button must not set their own outline.
  it('lets fields and the check box use the one focus ring', () => {
    const own = FILES.filter(f =>
      /border-panel-edge bg-bg[^']*outline-none|group-focus-visible:outline/.test(f.text),
    )
    expect(own.map(f => f.path)).toEqual([])
    expect(source('overview/OverviewSettingsPanel.tsx')).not.toMatch(/h-6[^']*outline-none/)
    expect(source('lib/CheckBox.tsx')).not.toMatch(/\boutline-none\b/)
  })

  it('makes the top frame less transparent, with a 250 ms change', () => {
    expect(CSS).toContain('--color-panel-focus: rgb(8 8 8 / calc(var(--panel-alpha) + 0.1));')
    const frame = source('wm/Frame.tsx')
    expect(frame).toMatch(/border-t-accent bg-panel-focus /)
    expect(frame).toMatch(/border-t-accent\/35 bg-panel'/)
    expect(frame).toContain('transition-[background-color,border-color,box-shadow] duration-250')
  })

  it.each([
    'wm/Frame.tsx',
    'wm/SideBar.tsx',
    'wm/LayoutMenu.tsx',
    'lib/menu.tsx',
    'actions/ActionButton.tsx',
    'overview/OverviewTabs.tsx',
    'overview/OverviewTable.tsx',
    'panels/IntegrationPanel.tsx',
  ])('%s gives a cyan tint on a press', name => {
    expect(source(name)).toMatch(PRESS)
  })

  // The only variant of bg-select that is allowed is *:bg-select (the cells) in the Overview
  // table. A watched row has its watch colour on the row, so the selection goes on the cells
  // to show on top of it. Any other variant, hover: included, is not allowed.
  it('keeps the hover neutral: no variant uses bg-select, except *:bg-select in the Overview table', () => {
    const bad = FILES.flatMap(f =>
      (f.text.match(/(?:[\w-]+|\*):bg-select\b/g) ?? [])
        .filter(use => !(use === '*:bg-select' && f.path.endsWith('overview/OverviewTable.tsx')))
        .map(use => `${f.path}: ${use}`),
    )
    expect(bad).toEqual([])
  })

  it('uses square corners: no rounded class and no border-radius style', () => {
    const bad = FILES.filter(f =>
      /\brounded\b|rounded-[a-z0-9]+|border-radius|borderRadius/.test(f.text),
    )
    expect(bad.map(f => f.path)).toEqual([])
  })

  it('sets every --radius-* token to 0', () => {
    const tokens = [...CSS.matchAll(/--radius-[\w-]+:\s*([^;]+);/g)]
    expect(tokens.length).toBeGreaterThan(0)
    for (const token of tokens) expect(token[1].trim()).toBe('0')
  })

  it('uses Geist Mono as the UI font', () => {
    expect(CSS).toContain('--font-ui: "Geist Mono", ui-monospace, "SF Mono", Menlo, monospace;')
    expect(CSS).not.toMatch(/saira|font-narrow/i)
  })

  it('the Overview colour tokens have no purple or pink', () => {
    const tokens = [
      ...CSS.matchAll(/--color-((?:project|tab|watch|prio)-[\w-]+):\s*(#[0-9a-fA-F]{6})/g),
    ]
    expect(tokens.length).toBeGreaterThanOrEqual(27)
    const bad = tokens
      .filter(([, , hex]) => {
        const hue = hsl(hex).h
        return hue >= 255 && hue <= 345
      })
      .map(([, name]) => name)
    expect(bad).toEqual([])
  })

  // the user, 2026-11-05: the yellow box and the red box stay clearly visible on every watched row.
  it('the boxes stay clearly visible on each watched row', () => {
    const rowOpacity = watchRowOpacity()
    const surfaces: [string, string][] = []
    for (const panel of PANELS) {
      for (const name of WATCH_NAMES) {
        const plain = mix(token(`watch-${name}`), rowOpacity, panel)
        surfaces.push([`${name} plain on ${panel}`, plain])
        surfaces.push([`${name} selected on ${panel}`, mix(token('accent'), 0.15, plain)])
        // The hover and the open state: --color-hover (white at 5%) over the tinted row.
        surfaces.push([`${name} hover on ${panel}`, mix('#ffffff', 0.05, plain)])
      }
    }
    const bad = surfaces.flatMap(([label, background]) =>
      ['box-yellow', 'box-red']
        .filter(box => contrast(token(box), background) < 3)
        .map(box => `${box} on ${label}: ${contrast(token(box), background).toFixed(2)}`),
    )
    expect(bad).toEqual([])
  })

  it('the watch red and yellow differ from the box colours', () => {
    const light = (name: string): number => hsl(token(name)).l
    for (const [watch, box] of [
      ['watch-red', 'box-red'],
      ['watch-yellow', 'box-yellow'],
    ]) {
      expect(Math.abs(light(watch) - light(box)), `${watch} and ${box}`).toBeGreaterThanOrEqual(15)
    }
  })

  // the user, 2026-11-05: dark red was too close to red (Task 17, contrast 1.34:1).
  it('the stripes of dark red and red differ clearly', () => {
    expect(token('watch-dark-red')).toBe('#7f1d1d')
    expect(contrast(token('watch-dark-red'), token('watch-red'))).toBeGreaterThanOrEqual(2)
  })

  // The tint is faint, so the full colour shows in a 3 px stripe at the left edge of the row.
  it('has a stripe class for each watch colour', () => {
    const text = source('watch/watch-colours.ts')
    for (const name of WATCH_NAMES) {
      expect(text, name).toContain(`shadow-[inset_3px_0_0_var(--color-watch-${name})]`)
    }
  })

  it('shows the stripe in the Overview and in the Watchlist panel', () => {
    expect(source('overview/OverviewTable.tsx')).toContain('WATCH_STRIPE[row.watch.colour]')
    expect(source('watch/WatchlistPanel.tsx')).toContain('WATCH_SWATCH[row.watch.colour]')
  })
})
