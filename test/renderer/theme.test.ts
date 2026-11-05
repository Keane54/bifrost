import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

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
]

// The class parts that can use the light cyan accent (spec 8.10): the top border of a frame,
// its glow, and the press feedback of an active: state. The selected row gets the accent
// through the --color-select token in app.css.
const ACCENT_CLASSES = [
  /^border-t-accent$/,
  /^--color-accent-glow$/,
  /^border-t-accent\/35$/,
  /^shadow-\[0_0_14px_1px_var\(--color-accent-glow\)\]'?$/,
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
    // The glow is a shadow outside the frame edge.
    expect(frame).toContain('shadow-[0_0_14px_1px_var(--color-accent-glow)]')
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

  it('keeps the hover neutral: no variant uses bg-select', () => {
    const bad = FILES.filter(f => /[\w-]+:bg-select\b/.test(f.text)).map(f => f.path)
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
})
