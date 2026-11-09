import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { PANEL_TRANSPARENCY_CHOICES } from '../../src/shared/settings'
import { WATCH_COLOURS } from '../../src/shared/watch'
import { contrast, hex, luminance, mix, rgb } from '../helpers/colour'

const WATCH_NAMES: readonly string[] = WATCH_COLOURS
// The Overview table sits on the panel. The row background is the watch colour over this.
// The unfocused panel is about rgb(24 24 24). The focused panel is rgb(8 8 8).
const PANELS = ['#181818', '#080808']

// The hex value of a token, in lower case. So a compare does not depend on the case in app.css.
function token(name: string): string {
  const match = CSS.match(new RegExp(`--color-${name}:\\s*(#[0-9a-fA-F]{6})`))
  if (!match) throw new Error(`No hex token ${name}`)
  return match[1].toLowerCase()
}

// The colour families that the hex check and the distance check read.
const FAMILIES = ['project', 'tab', 'watch', 'prio', 'svc', 'usage', 'ctx'] as const
const SVC_USAGE = [
  'svc-ok',
  'svc-minor',
  'svc-major',
  'svc-critical',
  'svc-maint',
  'usage',
  'usage-high',
]

// Each family with no token, each svc or usage token that is missing, and each token of a family
// that is not a hex colour. The hue and distance checks read only hex tokens. So a token in
// another form would skip them, and no test would fail (final review Minor 6).
function familyProblems(css: string): string[] {
  const problems: string[] = []
  for (const family of FAMILIES) {
    const all = [...css.matchAll(new RegExp(`--color-(${family}(?:-[\\w-]+)?):\\s*([^;]+);`, 'g'))]
    if (all.length === 0) problems.push(`no ${family} token`)
    for (const [, name, value] of all) {
      if (!/^#[0-9a-f]{6}$/i.test(value.trim())) problems.push(`${name} is not hex`)
    }
  }
  for (const name of SVC_USAGE) {
    if (!new RegExp(`--color-${name}:`).test(css)) problems.push(`no ${name}`)
  }
  return problems
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

// The hue ranges of HSL in degrees (user decision, 2026-11-06). The Overview check and the watch check
// share them. A hue is in a range when from <= hue < to. The pink range also takes its end, 345,
// as the Overview check did before.
const PURPLE_HUES = { from: 255, name: 'purple', to: 300 } as const
const PINK_HUES = { from: 300, name: 'pink', to: 345 } as const
type HueRange = typeof PURPLE_HUES | typeof PINK_HUES

function inHues(hue: number, range: HueRange): boolean {
  return hue >= range.from && (hue < range.to || (range === PINK_HUES && hue === range.to))
}

// The colour families of the Overview. They have no purple and no pink.
const OVERVIEW_FAMILIES = ['project', 'tab', 'prio'] as const

// The hex tokens of the families: the name and the value.
function familyTokens(css: string, families: readonly string[]): [string, string][] {
  const pattern = new RegExp(
    `--color-((?:${families.join('|')})-?[\\w-]*):\\s*(#[0-9a-fA-F]{6})`,
    'g',
  )
  return [...css.matchAll(pattern)].map(match => [match[1], match[2]])
}

// Each token of the families with a hue in one of the ranges, as "<name> is <range>".
function hueProblems(
  css: string,
  families: readonly string[],
  ranges: readonly HueRange[],
): string[] {
  return familyTokens(css, families).flatMap(([name, value]) => {
    const hue = hsl(value).h
    const range = ranges.find(r => inHues(hue, r))
    return range ? [`${name} is ${range.name}`] : []
  })
}

// The sRGB to OKLab conversion of Bjorn Ottosson.
function oklab(colour: string): [number, number, number] {
  const [r, g, b] = rgb(colour).map(c => {
    const v = c / 255
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
  })
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ]
}

function distance(a: string, b: string): number {
  const [x, y] = [oklab(a), oklab(b)]
  return Math.hypot(x[0] - y[0], x[1] - y[1], x[2] - y[2])
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
    if (path === join(SRC, 'styles/app.css')) return []
    return /\.(?:tsx?|css)$/.test(entry.name) ? [path] : []
  })
}

const FILES = sourceFiles(SRC).map(path => ({ path, text: readFileSync(path, 'utf8') }))
const MAIN_INDEX = readFileSync(join(__dirname, '../../src/main/index.ts'), 'utf8')

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

  // A file that needs a colour in code reads a token at run time, for example with
  // getComputedStyle(document.documentElement).getPropertyValue('--color-...').
  it('has no hex colour, rgb( or hsl( in a .ts, .tsx or .css file except app.css', () => {
    const bad = FILES.filter(f => /#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(/.test(f.text)).map(
      f => f.path,
    )
    expect(bad).toEqual([])
  })

  it('the window background equals --color-bg', () => {
    const match = MAIN_INDEX.match(/backgroundColor:\s*'(#[0-9a-fA-F]{6})'/)
    expect(match?.[1]).toBe(token('bg'))
  })

  // The box and parked tokens mean a box or a parked row. Check each new file that uses them.
  it('only box and parked files use the box and parked tokens', () => {
    const allowed = [
      'overview/SessionIcon.tsx',
      'overview/cells.tsx',
      'overview/OverviewTable.tsx',
      'reviews/ReviewRow.tsx',
      'reviews/ReviewsPanel.tsx',
      'watch/WatchlistPanel.tsx',
    ]
    const bad = FILES.filter(f => /-box-yellow|-box-red|-parked/.test(f.text))
      .map(f => f.path)
      .filter(path => !allowed.some(name => path.endsWith(name)))
    expect(bad).toEqual([])
  })

  // User decision, 2026-11-06: each frame very slightly blurs the animated background behind it. A chat
  // window and the other panels use the same light blur.
  it('gives each frame one light backdrop blur of 6 to 8 px', () => {
    expect(source('wm/Frame.tsx').match(/backdrop-blur-[\w[\]-]+/g)).toEqual([
      'backdrop-blur-panel',
    ])
    const blur = Number(CSS.match(/--blur-panel:\s*([\d.]+)px;/)?.[1])
    expect(blur).toBeGreaterThanOrEqual(6)
    expect(blur).toBeLessThanOrEqual(8)
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
    'settings/SettingsPanel.tsx',
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

  // User decision, 2026-11-06: purple and pink must not show on the Overview. Other panels may use them.
  // So this check covers only the families that the Overview uses.
  it('the project, tab and prio tokens have no purple or pink', () => {
    // Each token of the families is hex, so the check reads all of them.
    const all = [...CSS.matchAll(/--color-(?:project|tab|prio)[\w-]*:/g)]
    expect(familyTokens(CSS, OVERVIEW_FAMILIES).length).toBe(all.length)
    expect(all.length).toBeGreaterThanOrEqual(25)
    expect(hueProblems(CSS, OVERVIEW_FAMILIES, [PURPLE_HUES, PINK_HUES])).toEqual([])
  })

  // User decision, 2026-11-06: the watch colours tint and stripe Overview rows. So they have no purple.
  // Pink is allowed for them.
  it('the watch tokens have no purple, and may have pink', () => {
    const all = [...CSS.matchAll(/--color-watch[\w-]*:/g)]
    expect(familyTokens(CSS, ['watch']).length).toBe(all.length)
    expect(all.length).toBe(WATCH_NAMES.length)
    expect(hueProblems(CSS, ['watch'], [PURPLE_HUES])).toEqual([])
  })

  it('the hue checks find a purple or a pink token (guard)', () => {
    const violet = CSS.replace('--color-watch-white: #f2f2f2;', '--color-watch-white: #9b80e6;')
    expect(hueProblems(violet, ['watch'], [PURPLE_HUES])).toEqual(['watch-white is purple'])
    const pinkWatch = CSS.replace('--color-watch-white: #f2f2f2;', '--color-watch-white: #ec4899;')
    expect(hueProblems(pinkWatch, ['watch'], [PURPLE_HUES])).toEqual([])
    const pinkTab = CSS.replace('--color-tab-1: #7cc4d6;', '--color-tab-1: #ec4899;')
    expect(hueProblems(pinkTab, OVERVIEW_FAMILIES, [PURPLE_HUES, PINK_HUES])).toEqual([
      'tab-1 is pink',
    ])
  })

  it('each colour family is there, with the svc and usage tokens, all in hex (count guard)', () => {
    expect(familyProblems(CSS)).toEqual([])
    // The guard finds a token in another form, a missing family and a missing token.
    const rgbHigh = CSS.replace('--color-usage-high: #d4730a;', '--color-usage-high: rgb(1 2 3);')
    expect(familyProblems(rgbHigh)).toEqual(['usage-high is not hex'])
    expect(familyProblems(CSS.replaceAll('--color-svc-', '--color-x-'))).toContain('no svc token')
    expect(familyProblems(CSS.replace('--color-svc-maint:', '--color-svc-other:'))).toEqual([
      'no svc-maint',
    ])
  })

  // User decision, 2026-11-05: the yellow box and the red box stay clearly visible on every watched row.
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

  // User decision, 2026-11-05: dark red was too close to red (Task 17, contrast 1.34:1).
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

  // User decision, 2026-11-05: reds, ambers and yellows can be Overview colours. The box red and the box
  // yellow stay reserved shades.
  it('each project, tab, watch, prio, svc, usage and ctx colour differs clearly from the box colours', () => {
    const tokens = [
      ...CSS.matchAll(
        /--color-((?:tab|prio|project|watch|svc|usage|ctx)-?[\w-]*):\s*(#[0-9a-fA-F]{6})/g,
      ),
    ]
    expect(tokens.map(t => t[1])).toEqual(
      expect.arrayContaining(['ctx-low', 'ctx-mid', 'ctx-high']),
    )
    const bad = tokens.flatMap(([, name, value]) =>
      ['box-red', 'box-yellow']
        .map(box => ({ box, d: distance(value, token(box)) }))
        .filter(({ d }) => d < 0.1)
        .map(({ box, d }) => `${name} to ${box}: ${d.toFixed(3)}`),
    )
    expect(bad).toEqual([])
  })

  it('each tab colour is readable on both panels', () => {
    for (let i = 1; i <= 12; i++) {
      for (const panel of PANELS) {
        expect(contrast(token(`tab-${i}`), panel), `tab-${i} on ${panel}`).toBeGreaterThanOrEqual(4)
      }
    }
  })

  it('defines the three context bar colours: green, amber and red', () => {
    expect(token('ctx-low')).toBe('#22c55e')
    expect(token('ctx-mid')).toBe('#d4730a')
    expect(token('ctx-high')).toBe('#dc2626')
  })

  it('defines 12 tab colours', () => {
    for (let i = 1; i <= 12; i++) expect(CSS).toMatch(new RegExp(`--color-tab-${i}:`))
  })
})

// Ruling R4: the Service status colours are greens, teals, blues and amber. They stay clear of
// the box colours and of each other.
describe('the Service status tokens', () => {
  const NAMES = ['ok', 'minor', 'major', 'critical', 'maint'].map(n => `svc-${n}`)

  // The distance to the box colours is checked for all families above. The purple and pink check
  // covers the Overview families, and the purple check covers the watch family.
  it('are not yellow or red', () => {
    for (const name of NAMES) {
      const { h } = hsl(token(name))
      expect(h >= 330 || h < 20 || (h >= 40 && h < 80), `${name} is red or yellow`).toBe(false)
    }
  })

  it('differ from each other', () => {
    for (const a of NAMES) {
      for (const b of NAMES) {
        if (a < b) expect(distance(token(a), token(b)), `${a} to ${b}`).toBeGreaterThanOrEqual(0.1)
      }
    }
  })
})

// The surfaces under the text of a chat terminal: the panel colour at each transparency, over each
// backdrop (review Minor 4). The light blur spreads the backdrops:
// - blurred text of another panel: a quarter of the text colour over the panel colour,
// - the brightest watch row tint (white, at the row opacity) over the panel colour,
// - a selected row: the accent at 15% over the panel colour,
// - the rainbow of another loader at its full strength: the brightest icon colour at 25%.
// Each item is a label and the colour of the surface.
function terminalSurfaces(): [string, string][] {
  const level = (name: string): number => {
    const match = CSS.match(new RegExp(`--color-${name}: rgb\\((\\d+) `))
    return Number(match?.[1])
  }
  const grey = (n: number): string => hex([n, n, n])
  const panel = grey(level('panel'))
  const icons = [1, 2, 3, 4, 5, 6].map(n => token(`icon-${n}`))
  const brightest = icons.reduce((a, b) => (luminance(b) > luminance(a) ? b : a))
  const backdrops: [string, string][] = [
    ['blurred text', mix(token('text'), 0.25, panel)],
    ['a white watch row', mix(token('watch-white'), watchRowOpacity(), panel)],
    ['a selected row', mix(token('accent'), 0.15, panel)],
    ['a loader rainbow', mix(brightest, 0.25, panel)],
  ]
  const surfaces: [string, string][] = []
  for (const [where, backdrop] of backdrops) {
    for (const percent of PANEL_TRANSPARENCY_CHOICES) {
      const alpha = 1 - percent / 100
      const panels = [
        ['panel', mix(panel, alpha, backdrop)],
        ['focused panel', mix(grey(level('panel-focus')), Math.min(1, alpha + 0.1), backdrop)],
      ]
      for (const [name, surface] of panels) {
        surfaces.push([`on ${name} at ${percent}% over ${where}`, surface])
      }
    }
  }
  return surfaces
}

// User decision, 2026-11-06: the chat terminal has no black background. The frame colour and its blur show
// through, so the Panel transparency setting applies to chat windows too.
describe('the chat terminal background', () => {
  // The default text colour of xterm.js, and a mid grey as the dim text of Claude Code.
  const TEXT = '#ffffff'
  const DIM = '#999999'

  // xterm.css paints the viewport element black and gives it a native scroll bar, outside a layer.
  // So the override must be outside a layer too, after the last layer block.
  it('replaces the black viewport and its native scroll bar of xterm.css, outside a layer', () => {
    const rule =
      '[data-chat-terminal] .xterm .xterm-viewport {\n  background-color: var(--color-terminal-bg);\n  scrollbar-width: none;\n}'
    const at = CSS.indexOf(rule)
    expect(at).toBeGreaterThan(-1)
    const lastLayer = CSS.lastIndexOf('@layer')
    const layerEnd = CSS.indexOf('\n}\n', lastLayer)
    expect(at).toBeGreaterThan(layerEnd)
  })

  it('is fully transparent', () => {
    const match = CSS.match(/--color-terminal-bg:\s*(#[0-9a-fA-F]{8});/)
    expect(match?.[1].toLowerCase()).toBe('#00000000')
  })

  it('keeps the text easy to read on the panel at each transparency, over bright backdrops', () => {
    const bad: string[] = []
    for (const [label, surface] of terminalSurfaces()) {
      if (contrast(TEXT, surface) < 7) bad.push(`text ${label}`)
      if (contrast(DIM, surface) < 4.5) bad.push(`dim text ${label}`)
    }
    expect(bad).toEqual([])
  })
})

// User decision, 2026-11-09: the scroll bar of a chat window is clearly visible. xterm.js reads the slider
// colours of its theme from these tokens. It reads a colour with an alpha only as hex or as
// rgba() with commas, so the tokens are hex.
describe('the chat terminal scroll bar', () => {
  const NAMES = ['terminal-slider', 'terminal-slider-hover', 'terminal-slider-active']

  // The colour and the alpha of a slider token.
  function slider(name: string): { colour: string; alpha: number } {
    const match = CSS.match(new RegExp(`--color-${name}:\\s*#([0-9a-fA-F]{6})([0-9a-fA-F]{2});`))
    if (!match) throw new Error(`No hex token ${name} with an alpha`)
    return { alpha: Number.parseInt(match[2], 16) / 255, colour: `#${match[1].toLowerCase()}` }
  }

  it.each(NAMES)('defines --color-%s in hex with an alpha', name => {
    expect(() => slider(name)).not.toThrow()
  })

  it('makes the slider stronger under the pointer, and stronger again during a drag', () => {
    const [rest, hover, active] = NAMES.map(name => slider(name).alpha)
    expect(hover).toBeGreaterThan(rest)
    expect(active).toBeGreaterThan(hover)
  })

  // A part of the interface needs a contrast of 3:1 or more (WCAG 1.4.11). The xterm.js default
  // is white at 20%, which gives less than 2:1 on the panel.
  it('shows the slider at rest clearly on the panel at each transparency, over bright backdrops', () => {
    const { alpha, colour } = slider('terminal-slider')
    const bad = terminalSurfaces()
      .map(([label, surface]): [string, number] => [
        label,
        contrast(mix(colour, alpha, surface), surface),
      ])
      .filter(([, ratio]) => ratio < 3)
      .map(([label, ratio]) => `${label}: ${ratio.toFixed(2)}`)
    expect(bad).toEqual([])
  })
})
