import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  BACKGROUND_FIELDS,
  backgroundClass,
  backgroundMotion,
  windowActive,
} from '../../src/renderer/src/wm/background-style'
import { WATCH_COLOURS } from '../../src/shared/watch'
import { contrast, hex, luminance, mix } from '../helpers/colour'

// The repository has no DOM test. So the checks of the animated background read the source text
// of app.css, as the checks of the Take control loader do.
const SRC = join(__dirname, '../../src/renderer/src')
const CSS = readFileSync(join(SRC, 'styles/app.css'), 'utf8')
const APP = readFileSync(join(SRC, 'App.tsx'), 'utf8')
const VIEW = readFileSync(join(SRC, 'wm/Background.tsx'), 'utf8')
const WATCH = readFileSync(join(SRC, 'watch/watch-colours.ts'), 'utf8')

// The text between the brace that opens at or after the index and the brace that closes it.
function blockAt(css: string, index: number): string {
  const open = css.indexOf('{', index)
  if (open < 0) throw new Error('No block')
  let depth = 0
  for (let i = open; i < css.length; i++) {
    if (css[i] === '{') depth++
    if (css[i] === '}') depth--
    if (depth === 0) return css.slice(open + 1, i)
  }
  throw new Error('A block has no end')
}

// The body of the first rule or at-rule that starts with the head.
function block(css: string, head: string): string {
  const at = css.indexOf(head)
  if (at < 0) throw new Error(`No ${head}`)
  return blockAt(css, at)
}

// The declarations of a rule body, as property and value.
function declarations(body: string): [string, string][] {
  return [...body.matchAll(/([a-z-]+)\s*:\s*([^;{}]+);/g)].map(m => [m[1], m[2].trim()])
}

function value(body: string, property: string): string {
  const found = declarations(body).find(([name]) => name === property)
  if (!found) throw new Error(`No ${property}`)
  return found[1]
}

// The hex value of a colour token.
function token(name: string): string {
  const match = CSS.match(new RegExp(`--color-${name}:\\s*(#[0-9a-fA-F]{6})`))
  if (!match) throw new Error(`No hex token ${name}`)
  return match[1].toLowerCase()
}

// The grey level of an rgb() panel token, for example 24 for rgb(24 24 24 / ...).
function level(name: string): number {
  const match = CSS.match(new RegExp(`--color-${name}: rgb\\((\\d+) `))
  if (!match) throw new Error(`No rgb token ${name}`)
  return Number(match[1])
}

interface Field {
  index: number
  // The name of the icon token, for example icon-6.
  colour: string
  // The part of the glow strength, from 0 to 1.
  weight: number
  // The still position and the size, in percent of the window.
  left: number
  top: number
  width: number
  height: number
  keyframes: string
  // The animation cycle in seconds.
  cycle: number
  rule: string
}

function fields(css: string): Field[] {
  return [...css.matchAll(/\.background-field:nth-child\((\d+)\)\s*\{/g)].map(match => {
    const rule = blockAt(css, match.index)
    const animation = value(rule, 'animation').match(/^(background-drift-\d+) (\d+)s\b/)
    if (!animation) throw new Error(`Field ${match[1]} has no animation`)
    const percent = (property: string): number => {
      const text = value(rule, property)
      if (!/^-?[\d.]+%$/.test(text))
        throw new Error(`Field ${match[1]}: ${property} is not a percent`)
      return Number.parseFloat(text)
    }
    return {
      colour: value(rule, '--field-colour').match(/^var\(--color-(icon-\d)\)$/)?.[1] ?? '',
      cycle: Number(animation[2]),
      height: percent('height'),
      index: Number(match[1]),
      keyframes: block(css, `@keyframes ${animation[1]} `),
      left: percent('left'),
      rule,
      top: percent('top'),
      weight: Number(value(rule, '--field-weight')),
      width: percent('width'),
    }
  })
}

const FIELDS = fields(CSS)

function gcd(a: number, b: number): number {
  return b === 0 ? a : gcd(b, a % b)
}

// The steps of a keyframes block: the selector and the body.
function steps(keyframes: string): { at: string; body: string }[] {
  return [...keyframes.matchAll(/([\d%,\s]+|from|to)\{([^}]*)\}/g)].map(m => ({
    at: m[1].trim(),
    body: m[2],
  }))
}

function transformParts(transform: string): { name: string; args: string[] }[] {
  return [...transform.matchAll(/([a-zA-Z0-9]+)\(([^)]*)\)/g)].map(m => ({
    args: m[2].split(',').map(a => a.trim()),
    name: m[1],
  }))
}

// The strength of the colour fields: a percent token in app.css.
function glowStrength(): number {
  const match = CSS.match(/--background-glow:\s*([\d.]+)%;/)
  if (!match) throw new Error('No --background-glow token')
  return Number(match[1]) / 100
}

// The place, turn, size and opacity of a field at one step of its motion. The place is a part of
// the field size.
interface Pose {
  tx: number
  ty: number
  turn: number
  scale: number
  opacity: number
}

function pose(body: string): Pose {
  const result = { opacity: Number(value(body, 'opacity')), scale: 1, turn: 0, tx: 0, ty: 0 }
  for (const part of transformParts(value(body, 'transform'))) {
    const [a, b] = part.args.map(arg => Number.parseFloat(arg))
    if (part.name === 'translate') [result.tx, result.ty] = [a / 100, b / 100]
    if (part.name === 'rotate') result.turn = (a * Math.PI) / 180
    if (part.name === 'scale') result.scale = a
  }
  return result
}

// The poses along the path of a field: each step, and 16 poses between two steps. The browser
// moves each value of the transform in a straight line from one step to the next. The easing
// changes only the speed, not the path.
function path(field: Field): Pose[] {
  const keys = steps(field.keyframes).map(step => pose(step.body))
  const poses = [keys[0]]
  for (let i = 1; i < keys.length; i++) {
    for (let k = 1; k <= 16; k++) {
      const part = k / 16
      const between = (name: keyof Pose): number =>
        keys[i - 1][name] + (keys[i][name] - keys[i - 1][name]) * part
      poses.push({
        opacity: between('opacity'),
        scale: between('scale'),
        turn: between('turn'),
        tx: between('tx'),
        ty: between('ty'),
      })
    }
  }
  return poses
}

// The alpha steps of the gradient of a field: the place from the centre (0) to the edge (1), and
// the part of the glow.
function fadeSteps(): [number, number][] {
  const image = value(block(CSS, '.background-field {'), 'background-image')
  const result: [number, number][] = [[0, 1]]
  for (const m of image.matchAll(/var\(--field-glow\) \* ([\d.]+)\), transparent\) (\d+)%/g)) {
    result.push([Number(m[2]) / 100, Number(m[1])])
  }
  result.push([1, 0])
  return result
}

const FADE = fadeSteps()

function fadeAt(r: number): number {
  for (let i = 1; i < FADE.length; i++) {
    const [r0, a0] = FADE[i - 1]
    const [r1, a1] = FADE[i]
    if (r <= r1) return a0 + ((a1 - a0) * (r - r0)) / (r1 - r0)
  }
  return 0
}

// The alpha of a field at a point of a window of w by h pixels. The transform turns and scales the
// field about its centre. closest-side gives an ellipse that touches the four sides of the field.
function alphaAt(field: Field, at: Pose, x: number, y: number, w: number, h: number): number {
  const fw = (field.width / 100) * w
  const fh = (field.height / 100) * h
  const dx = x - ((field.left / 100) * w + fw / 2 + at.tx * fw)
  const dy = y - ((field.top / 100) * h + fh / 2 + at.ty * fh)
  const cos = Math.cos(at.turn)
  const sin = Math.sin(at.turn)
  const lx = (dx * cos + dy * sin) / at.scale
  const ly = (-dx * sin + dy * cos) / at.scale
  const r = Math.hypot(lx / (fw / 2), ly / (fh / 2))
  return glowStrength() * field.weight * at.opacity * fadeAt(r)
}

// The window sizes of the check: the default, the smallest, a square and a wide screen.
const WINDOWS: [number, number][] = [
  [1440, 900],
  [800, 500],
  [1000, 1000],
  [3440, 1440],
]

// The brightest point of the background. The cycles have no common factor, so in time each field
// is at each pose of its path while the other fields are at each pose of their paths. So at each
// point of a grid, each field takes its highest alpha at that point. The fields then paint over
// --color-bg in the order of the page. The icon colours are brighter than this dark mix in each
// channel, so more alpha always gives a brighter colour.
function findBrightest(): string {
  const paths = FIELDS.map(path)
  let brightest = token('bg')
  for (const [w, h] of WINDOWS) {
    for (let i = 0; i <= 48; i++) {
      for (let j = 0; j <= 30; j++) {
        const [x, y] = [(i / 48) * w, (j / 30) * h]
        let colour = token('bg')
        FIELDS.forEach((field, n) => {
          const alpha = Math.max(...paths[n].map(at => alphaAt(field, at, x, y, w, h)))
          colour = mix(token(field.colour), alpha, colour)
        })
        if (luminance(colour) > luminance(brightest)) brightest = colour
      }
    }
  }
  return brightest
}

// The search takes about one second, so it runs one time.
let brightestCache: string | null = null

function brightestBackground(): string {
  brightestCache ??= findBrightest()
  return brightestCache
}

describe('the background layer', () => {
  it('fills the window behind all frames and the side bar, over --color-bg', () => {
    const rule = block(CSS, '.background {')
    expect(value(rule, 'position')).toBe('fixed')
    expect(value(rule, 'inset')).toBe('0')
    expect(value(rule, 'z-index')).toBe('-1')
    expect(value(rule, 'pointer-events')).toBe('none')
    expect(value(rule, 'overflow')).toBe('hidden')
    expect(value(rule, 'background-color')).toBe('var(--color-bg)')
    // The app renders the layer before the window manager, in the settings provider.
    expect(APP).toMatch(/<SettingsProvider>\s*<Background \/>\s*<WindowManager \/>/)
    expect(VIEW).toContain('aria-hidden={true}')
  })

  it('keeps the window background colour, so the first paint has no flash', () => {
    expect(token('bg')).toBe('#0a0a0a')
  })

  it('has five or six colour fields, and the view renders each one', () => {
    expect(BACKGROUND_FIELDS).toBeGreaterThanOrEqual(5)
    expect(BACKGROUND_FIELDS).toBeLessThanOrEqual(6)
    expect(FIELDS.map(f => f.index)).toEqual(
      Array.from({ length: BACKGROUND_FIELDS }, (_, i) => i + 1),
    )
    expect(VIEW).toContain('length: BACKGROUND_FIELDS')
    expect(VIEW).toContain("className='background-field'")
  })

  it('gives each field its own icon colour, at a part of the strength of one token', () => {
    const colours = FIELDS.map(f => f.colour)
    expect(new Set(colours).size).toBe(FIELDS.length)
    for (const colour of colours) expect(colour).toMatch(/^icon-[1-6]$/)
    const strength = glowStrength()
    expect(strength).toBeGreaterThan(0)
    expect(strength).toBeLessThanOrEqual(0.3)
    for (const field of FIELDS) {
      expect(field.weight, `field ${field.index}`).toBeGreaterThan(0)
      expect(field.weight, `field ${field.index}`).toBeLessThanOrEqual(1)
    }
    const rule = block(CSS, '.background-field {')
    expect(value(rule, '--field-glow')).toBe('calc(var(--background-glow) * var(--field-weight))')
    expect(value(rule, 'background-image')).toContain(
      'color-mix(in oklab, var(--field-colour) var(--field-glow), transparent)',
    )
    // No colour value outside the tokens.
    const all = [block(CSS, '.background {'), rule, ...FIELDS.map(f => f.rule)].join('\n')
    expect(all).not.toMatch(/#[0-9a-f]{3,8}\b|rgba?\(|hsla?\(/i)
  })

  it('makes each field large and soft: 50 to 90% of the window, a radial gradient', () => {
    for (const field of FIELDS) {
      for (const size of [field.width, field.height]) {
        expect(size, `field ${field.index}`).toBeGreaterThanOrEqual(50)
        expect(size, `field ${field.index}`).toBeLessThanOrEqual(90)
      }
    }
    const image = value(block(CSS, '.background-field {'), 'background-image')
    expect(image).toMatch(/^radial-gradient\(/)
    // The gradient fades out in several steps, to transparent at its edge.
    expect(image).toMatch(/transparent 100%\s*\)$/)
    expect(FADE.length).toBeGreaterThanOrEqual(6)
    for (let i = 1; i < FADE.length; i++) {
      expect(FADE[i][0]).toBeGreaterThan(FADE[i - 1][0])
      expect(FADE[i][1]).toBeLessThan(FADE[i - 1][1])
    }
  })
})

describe('the motion of the background', () => {
  it('gives each field its own slow cycle: 40 to 90 s, with no common factor below 5', () => {
    const cycles = FIELDS.map(f => f.cycle)
    expect(new Set(cycles).size).toBe(cycles.length)
    for (const cycle of cycles) {
      expect(cycle).toBeGreaterThanOrEqual(40)
      expect(cycle).toBeLessThanOrEqual(90)
    }
    const bad: string[] = []
    for (const a of cycles) {
      for (const b of cycles) {
        const shared = gcd(a, b)
        if (a < b && [2, 3, 4].some(f => shared % f === 0)) bad.push(`${a} and ${b}`)
      }
    }
    expect(bad).toEqual([])
  })

  it('runs each cycle forwards and back, without end, with a soft ease', () => {
    for (const field of FIELDS) {
      expect(value(field.rule, 'animation')).toMatch(
        /^background-drift-\d+ \d+s ease-in-out infinite alternate$/,
      )
    }
  })

  it('animates only transform and opacity, with no filter', () => {
    for (const field of FIELDS) {
      const names = new Set(declarations(field.keyframes).map(([name]) => name))
      expect([...names].sort(), `field ${field.index}`).toEqual(['opacity', 'transform'])
      expect(field.keyframes).not.toMatch(/filter/)
    }
  })

  it('makes each field drift, scale and turn', () => {
    for (const field of FIELDS) {
      const parts = steps(field.keyframes).flatMap(s => transformParts(value(s.body, 'transform')))
      const moved = (name: string, still: string) =>
        parts.some(
          p =>
            p.name === name && p.args.some(a => Number.parseFloat(a) !== Number.parseFloat(still)),
        )
      expect(moved('translate', '0'), `field ${field.index} drifts`).toBe(true)
      expect(moved('scale', '1'), `field ${field.index} scales`).toBe(true)
      expect(moved('rotate', '0'), `field ${field.index} turns`).toBe(true)
    }
  })

  // the user: "not with the whole bubbles going up and down". The fields drift mostly to the side.
  it('moves no field up or down far: no bubble rises or sinks', () => {
    for (const field of FIELDS) {
      for (const step of steps(field.keyframes)) {
        for (const part of transformParts(value(step.body, 'transform'))) {
          expect(['translate', 'rotate', 'scale'], `field ${field.index}`).toContain(part.name)
          if (part.name !== 'translate') continue
          const [x, y] = part.args
          expect(x).toMatch(/^-?[\d.]+%$/)
          expect(y).toMatch(/^-?[\d.]+%$/)
          expect(Math.abs(Number.parseFloat(y)), `field ${field.index}`).toBeLessThanOrEqual(10)
        }
      }
    }
  })

  // The first step is the still position. So a field starts from where it stays with no motion.
  it('starts each cycle at the still position, and never fades a field out', () => {
    for (const field of FIELDS) {
      const all = steps(field.keyframes)
      expect(all[0].at).toBe('0%')
      expect(value(all[0].body, 'transform')).toBe('none')
      expect(value(all[0].body, 'opacity')).toBe('1')
      for (const step of all) {
        const opacity = Number(value(step.body, 'opacity'))
        expect(opacity).toBeGreaterThanOrEqual(0.5)
        expect(opacity).toBeLessThanOrEqual(1)
      }
    }
  })

  it('uses the compositor only: will-change transform and no blur or blend on a field', () => {
    const rule = block(CSS, '.background-field {')
    expect(value(rule, 'will-change')).toBe('transform')
    for (const body of [rule, ...FIELDS.map(f => f.rule)]) {
      expect(body).not.toMatch(/filter|mix-blend-mode/)
    }
  })

  it('stops the motion with reduced motion and with the setting off from the start', () => {
    const lastField = CSS.lastIndexOf('.background-field:nth-child(')
    const reduced = CSS.indexOf('@media (prefers-reduced-motion: reduce)', lastField)
    expect(reduced).toBeGreaterThan(lastField)
    // Two classes: the same specificity as a field rule, and later, so the stop rule wins.
    expect(blockAt(CSS, reduced)).toMatch(
      /^\s*\.background \.background-field\s*\{\s*animation:\s*none;\s*\}\s*$/,
    )
    const still = CSS.indexOf('.background-still .background-field {', lastField)
    expect(still).toBeGreaterThan(lastField)
    expect(declarations(blockAt(CSS, still))).toEqual([['animation', 'none']])
  })

  // The field rules set the animation shorthand, and the shorthand sets the play state to running.
  // So the pause rule must come after them.
  it('pauses the fields where they are, with no jump', () => {
    const lastField = CSS.lastIndexOf('.background-field:nth-child(')
    const paused = CSS.indexOf('.background-paused .background-field {', lastField)
    expect(paused).toBeGreaterThan(lastField)
    expect(declarations(blockAt(CSS, paused))).toEqual([['animation-play-state', 'paused']])
  })
})

describe('the state of the motion', () => {
  const ON = { active: true, animated: true, ran: true }

  it('moves only with the setting on and an active window', () => {
    expect(backgroundMotion(ON)).toBe('moving')
    expect(backgroundMotion({ ...ON, ran: false })).toBe('moving')
  })

  // The coordinator, 2026-11-06: no motion while the window does not have the focus or the page
  // is hidden. The fields stay where they are and continue from there.
  it('pauses in place while the window is not active', () => {
    expect(backgroundMotion({ ...ON, active: false })).toBe('paused')
    expect(backgroundMotion({ ...ON, active: false, ran: false })).toBe('paused')
  })

  it('pauses in place when the setting goes off after the fields moved', () => {
    expect(backgroundMotion({ ...ON, animated: false })).toBe('paused')
    expect(backgroundMotion({ active: false, animated: false, ran: true })).toBe('paused')
  })

  it('keeps the still position when the setting is off from the start', () => {
    expect(backgroundMotion({ active: true, animated: false, ran: false })).toBe('still')
    expect(backgroundMotion({ active: false, animated: false, ran: false })).toBe('still')
  })

  it('makes the window active only with the focus and a visible page', () => {
    const page = (focus: boolean, visibilityState: DocumentVisibilityState) => ({
      hasFocus: () => focus,
      visibilityState,
    })
    expect(windowActive(page(true, 'visible'))).toBe(true)
    expect(windowActive(page(false, 'visible'))).toBe(false)
    expect(windowActive(page(true, 'hidden'))).toBe(false)
    expect(windowActive(page(false, 'hidden'))).toBe(false)
  })
})

describe('the Animated background setting', () => {
  it('gives each motion its class', () => {
    expect(backgroundClass('moving')).toBe('background')
    expect(backgroundClass('paused')).toBe('background background-paused')
    expect(backgroundClass('still')).toBe('background background-still')
  })

  // The settings are the defaults until the first get resolves. So the view waits for them,
  // and a setting that is off at the start gives the still position.
  it('reads the setting after the settings load, and follows the focus and the page', () => {
    expect(VIEW).toContain('ready && settings.animatedBackground')
    expect(VIEW).toContain('backgroundClass(backgroundMotion(')
    expect(VIEW).toContain('windowActive(document)')
    for (const event of ["window.addEventListener('focus'", "window.addEventListener('blur'"]) {
      expect(VIEW).toContain(event)
    }
    expect(VIEW).toContain("document.addEventListener('visibilitychange'")
  })
})

// The brief of 2026-11-06: at the brightest point of the background, under a panel at the default
// Panel transparency, the text stays readable and the boxes stay clearly visible.
describe('the contrast over the background', () => {
  const DEFAULT_TRANSPARENCY = 15
  const grey = (n: number): string => hex([n, n, n])
  const rowOpacity = (): number => {
    const values = new Set(
      [...WATCH.matchAll(/bg-watch-[\w-]+\/(\d+)'/g)].map(m => Number(m[1]) / 100),
    )
    if (values.size !== 1) throw new Error('The watch row classes need one opacity')
    return [...values][0]
  }

  // The panel and the focused panel over the brightest point. The blur can only make the
  // background darker than its brightest point.
  function panels(): [string, string][] {
    const back = brightestBackground()
    const alpha = 1 - DEFAULT_TRANSPARENCY / 100
    return [
      ['panel', mix(grey(level('panel')), alpha, back)],
      ['focused panel', mix(grey(level('panel-focus')), Math.min(1, alpha + 0.1), back)],
    ]
  }

  // Each row on a panel: plain, selected, hover, and each watch colour with its own three.
  function rows(panel: string): [string, string][] {
    const plain: [string, string][] = [['plain', panel]]
    for (const name of WATCH_COLOURS) {
      plain.push([`watch ${name}`, mix(token(`watch-${name}`), rowOpacity(), panel)])
    }
    return plain.flatMap(([name, surface]) => [
      [name, surface],
      [`${name} selected`, mix(token('accent'), 0.15, surface)],
      [`${name} hover`, mix('#ffffff', 0.05, surface)],
    ])
  }

  // A gentle glow, not a bright rainbow: the brightest point is only a little lighter than the
  // base colour, at less than 1.5:1.
  it('stays dark: the brightest point is a faint glow over --color-bg', () => {
    const brightest = brightestBackground()
    expect(contrast(brightest, token('bg'))).toBeLessThan(1.5)
    // Guard: the search finds at least the centre of each field at its full glow.
    for (const field of FIELDS) {
      const centre = mix(token(field.colour), glowStrength() * field.weight, token('bg'))
      expect(luminance(brightest), field.colour).toBeGreaterThanOrEqual(luminance(centre))
    }
  })

  it('keeps the panel text at 4.5:1 or more on each row', () => {
    const bad: string[] = []
    for (const [panel, surface] of panels()) {
      // The dim text shows on the panel itself, for example the hints of Settings.
      if (contrast(token('text-dim'), surface) < 4.5) bad.push(`text-dim on ${panel}`)
      for (const [row, background] of rows(surface)) {
        for (const text of ['text', 'text-strong']) {
          const ratio = contrast(token(text), background)
          if (ratio < 4.5) bad.push(`${text} on ${row} on ${panel}: ${ratio.toFixed(2)}`)
        }
      }
    }
    expect(bad).toEqual([])
  })

  it('keeps the box red and the box yellow at 3:1 or more on each row', () => {
    const bad: string[] = []
    for (const [panel, surface] of panels()) {
      for (const [row, background] of rows(surface)) {
        for (const box of ['box-red', 'box-yellow']) {
          const ratio = contrast(token(box), background)
          if (ratio < 3) bad.push(`${box} on ${row} on ${panel}: ${ratio.toFixed(2)}`)
        }
      }
    }
    expect(bad).toEqual([])
  })
})
