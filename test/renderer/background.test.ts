import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  BACKGROUND_FIELDS,
  backgroundClass,
  backgroundMotion,
  windowActive,
} from '../../src/renderer/src/wm/background-style'
import { WATCH_COLOURS } from '../../src/shared/watch'
import { contrast, hex, luminance, mix, rgb } from '../helpers/colour'

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
  return [...body.matchAll(/([a-z-]+)\s*:\s*((?:"[^"]*"|[^;{}"])+);/g)].map(m => [
    m[1],
    m[2].trim(),
  ])
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

// A number token of the @theme block. A percent gives a part of 1.
function themeNumber(name: string): number {
  const match = CSS.match(new RegExp(`--${name}:\\s*([\\d.]+)(%?);`))
  if (!match) throw new Error(`No --${name} token`)
  return Number(match[1]) / (match[2] === '%' ? 100 : 1)
}

function percent(rule: string, property: string): number {
  const text = value(rule, property)
  if (!/^-?[\d.]+%$/.test(text)) throw new Error(`${property} is not a percent`)
  return Number.parseFloat(text)
}

// The name and the cycle in seconds of the animation of a rule.
function animationOf(rule: string): { name: string; cycle: number } {
  const match = value(rule, 'animation').match(/^([\w-]+) (\d+)s\b/)
  if (!match) throw new Error('No animation')
  return { cycle: Number(match[2]), name: match[1] }
}

// One layer of the background: the base layer or a colour field. The box is in percent of the
// window.
interface Layer {
  name: string
  left: number
  top: number
  width: number
  height: number
  keyframes: string
  cycle: number
  rule: string
  // The colour and the alpha at a point of the layer, before the opacity of its pose. The point
  // is in pixels from the centre of the layer, before the transform.
  paint(x: number, y: number, w: number, h: number): { colour: number[]; alpha: number }
}

interface Field extends Layer {
  index: number
  // The name of the icon token, for example icon-6.
  colour: string
  // The part of the glow strength, from 0 to 1.
  weight: number
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

function fields(css: string): Field[] {
  const glow = themeNumber('background-glow')
  return [...css.matchAll(/\.background-field:nth-child\((\d+)\)\s*\{/g)].map(match => {
    const rule = blockAt(css, match.index)
    const { cycle, name } = animationOf(rule)
    const colour = value(rule, '--field-colour').match(/^var\(--color-(icon-\d)\)$/)?.[1] ?? ''
    const weight = Number(value(rule, '--field-weight'))
    return {
      colour,
      cycle,
      height: percent(rule, 'height'),
      index: Number(match[1]),
      keyframes: block(css, `@keyframes ${name} `),
      left: percent(rule, 'left'),
      name: `field ${match[1]}`,
      // closest-side gives an ellipse that touches the four sides of the field.
      paint: (x, y, w, h) => ({
        alpha: glow * weight * fadeAt(Math.hypot(x / (w / 2), y / (h / 2))),
        colour: rgb(token(colour)),
      }),
      rule,
      top: percent(rule, 'top'),
      weight,
      width: percent(rule, 'width'),
    }
  })
}

const FIELDS = fields(CSS)
const BASE_RULE = block(CSS, '.background::before {')
const NOISE_RULE = block(CSS, '.background::after {')

// The colour stops of the base gradient: the icon tokens, each at the base strength.
function baseStops(): string[] {
  const image = value(BASE_RULE, 'background-image')
  return [
    ...image.matchAll(
      /color-mix\(in oklab, var\(--color-(icon-\d)\) var\(--background-base\), transparent\)/g,
    ),
  ].map(m => m[1])
}

// The angle of the base gradient in degrees.
function baseAngle(): number {
  const match = value(BASE_RULE, 'background-image').match(/^linear-gradient\(\s*(\d+)deg,/)
  if (!match) throw new Error('The base is not a linear gradient with an angle')
  return Number(match[1])
}

// The base layer: one large linear gradient of the icon colours. The browser mixes the stops in
// premultiplied sRGB. The stops have the same alpha, so the colour is a straight mix.
function baseLayer(): Layer {
  const { cycle, name } = animationOf(BASE_RULE)
  const stops = baseStops().map(name => rgb(token(name)))
  const strength = themeNumber('background-base')
  const turn = (baseAngle() * Math.PI) / 180
  return {
    cycle,
    height: percent(BASE_RULE, 'height'),
    keyframes: block(CSS, `@keyframes ${name} `),
    left: percent(BASE_RULE, 'left'),
    name: 'base',
    paint: (x, y, w, h) => {
      const length = Math.abs(w * Math.sin(turn)) + Math.abs(h * Math.cos(turn))
      const t = Math.min(1, Math.max(0, 0.5 + (x * Math.sin(turn) - y * Math.cos(turn)) / length))
      const at = t * (stops.length - 1)
      const i = Math.min(stops.length - 2, Math.floor(at))
      const part = at - i
      return {
        alpha: strength,
        colour: stops[i].map((c, k) => c + (stops[i + 1][k] - c) * part),
      }
    },
    rule: BASE_RULE,
    top: percent(BASE_RULE, 'top'),
    width: percent(BASE_RULE, 'width'),
  }
}

const BASE = baseLayer()
// The layers in the order of the page: the base under the fields.
const LAYERS: Layer[] = [BASE, ...FIELDS]

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

// The place, turn, size and opacity of a layer at one step of its motion. The place is a part of
// the layer size.
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

// The poses along the path of a layer: each step, and 12 poses between two steps. The browser
// moves each value of the transform in a straight line from one step to the next. The easing
// changes only the speed, not the path.
function path(layer: Layer): Pose[] {
  const keys = steps(layer.keyframes).map(step => pose(step.body))
  const poses = [keys[0]]
  for (let i = 1; i < keys.length; i++) {
    for (let k = 1; k <= 12; k++) {
      const part = k / 12
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

// The colour and alpha of a layer at a point of a window of w by h pixels, at one pose. The
// transform turns and scales the layer about its centre.
function layerAt(layer: Layer, at: Pose, x: number, y: number, w: number, h: number) {
  const lw = (layer.width / 100) * w
  const lh = (layer.height / 100) * h
  const dx = x - ((layer.left / 100) * w + lw / 2 + at.tx * lw)
  const dy = y - ((layer.top / 100) * h + lh / 2 + at.ty * lh)
  const cos = Math.cos(at.turn)
  const sin = Math.sin(at.turn)
  const lx = (dx * cos + dy * sin) / at.scale
  const ly = (-dx * sin + dy * cos) / at.scale
  const paint = layer.paint(lx, ly, lw, lh)
  return { alpha: paint.alpha * at.opacity, colour: paint.colour }
}

function over(colour: number[], alpha: number, under: number[]): number[] {
  return colour.map((c, i) => c * alpha + under[i] * (1 - alpha))
}

function lum(colour: number[]): number {
  return luminance(hex(colour))
}

// The noise layer adds its mean, a mid grey, at its opacity. A panel blur and the eye both
// average the fine noise.
const NOISE_MEAN = [128, 128, 128]

// The window sizes of the check: the default, the smallest, a square and a wide screen.
const WINDOWS: [number, number][] = [
  [1440, 900],
  [800, 500],
  [1000, 1000],
  [3440, 1440],
]

// The brightest and the darkest point of the background. The cycles have no common factor, so in
// time each layer is at each pose of its path while the other layers are at each pose of their
// paths. So at each point of a grid, each layer in turn takes the pose that makes the mix the
// brightest (or the darkest). The layers paint over --color-bg in the order of the page, and the
// noise comes last.
function findExtremes(): { brightest: string; darkest: string } {
  const paths = LAYERS.map(path)
  const noise = themeNumber('background-noise')
  let brightest = rgb(token('bg')) as number[]
  let darkest = [255, 255, 255]
  for (const [w, h] of WINDOWS) {
    for (let i = 0; i <= 32; i++) {
      for (let j = 0; j <= 20; j++) {
        const [x, y] = [(i / 32) * w, (j / 20) * h]
        for (const pick of [1, -1]) {
          let colour = rgb(token('bg')) as number[]
          LAYERS.forEach((layer, n) => {
            let best: number[] | null = null
            for (const at of paths[n]) {
              const paint = layerAt(layer, at, x, y, w, h)
              const next = over(paint.colour, paint.alpha, colour)
              if (best === null || pick * (lum(next) - lum(best)) > 0) best = next
            }
            colour = best ?? colour
          })
          colour = over(NOISE_MEAN, noise, colour)
          if (pick === 1 && lum(colour) > lum(brightest)) brightest = colour
          if (pick === -1 && lum(colour) < lum(darkest)) darkest = colour
        }
      }
    }
  }
  return { brightest: hex(brightest), darkest: hex(darkest) }
}

// The search takes a few seconds, so it runs one time.
let extremesCache: { brightest: string; darkest: string } | null = null

function extremes(): { brightest: string; darkest: string } {
  extremesCache ??= findExtremes()
  return extremesCache
}

// the user, 2026-11-06: no gaps. Each point of the window shows a colour of the mix at each time. The
// darkest point has a luminance of 0.008 or more (the base colour --color-bg has 0.003).
const DARKEST_LUMINANCE = 0.008

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
    const strength = themeNumber('background-glow')
    expect(strength).toBeGreaterThan(0)
    expect(strength).toBeLessThanOrEqual(0.3)
    for (const field of FIELDS) {
      expect(field.weight, field.name).toBeGreaterThan(0)
      expect(field.weight, field.name).toBeLessThanOrEqual(1)
    }
    const rule = block(CSS, '.background-field {')
    expect(value(rule, '--field-glow')).toBe('calc(var(--background-glow) * var(--field-weight))')
    expect(value(rule, 'background-image')).toContain(
      'color-mix(in oklab, var(--field-colour) var(--field-glow), transparent)',
    )
    // No colour value outside the tokens.
    const all = [block(CSS, '.background {'), rule, BASE_RULE, ...FIELDS.map(f => f.rule)]
    expect(all.join('\n')).not.toMatch(/#[0-9a-f]{3,8}\b|rgba?\(|hsla?\(/i)
  })

  // the user, 2026-11-06: no gaps between the fields. So each field is larger than the window.
  it('makes each field larger than the window: 120 to 160%, with a soft radial gradient', () => {
    for (const field of FIELDS) {
      for (const size of [field.width, field.height]) {
        expect(size, field.name).toBeGreaterThanOrEqual(120)
        expect(size, field.name).toBeLessThanOrEqual(160)
      }
    }
    const image = value(block(CSS, '.background-field {'), 'background-image')
    expect(image).toMatch(/^radial-gradient\(\s*closest-side,/)
    expect(image).toMatch(/transparent 100%\s*\)$/)
    expect(FADE.length).toBeGreaterThanOrEqual(6)
    for (let i = 1; i < FADE.length; i++) {
      expect(FADE[i][0]).toBeGreaterThan(FADE[i - 1][0])
      expect(FADE[i][1]).toBeLessThan(FADE[i - 1][1])
    }
    // The fade is almost zero before the edge of the field. So the edge of the ellipse does not
    // show as a line or a fringe of colour.
    expect(FADE[FADE.length - 2][1]).toBeLessThanOrEqual(0.05)
  })

  // A full-window layer of the icon colours under the fields. So no point is black.
  it('has a base layer: a large linear gradient of the icon colours, under the fields', () => {
    expect(value(BASE_RULE, 'content')).toBe('""')
    expect(value(BASE_RULE, 'position')).toBe('absolute')
    expect(value(BASE_RULE, 'will-change')).toBe('transform')
    // The layer is centred on the window and much larger, so its motion never shows an edge.
    expect(BASE.width).toBeGreaterThanOrEqual(180)
    expect(BASE.height).toBeGreaterThanOrEqual(180)
    expect(BASE.left).toBe(-(BASE.width - 100) / 2)
    expect(BASE.top).toBe(-(BASE.height - 100) / 2)
    const stops = baseStops()
    expect(stops.length).toBeGreaterThanOrEqual(4)
    expect(value(BASE_RULE, 'background-image').match(/color-mix\(/g)).toHaveLength(stops.length)
    const strength = themeNumber('background-base')
    expect(strength).toBeGreaterThan(0)
    expect(strength).toBeLessThanOrEqual(0.15)
  })

  // the user, 2026-11-06: some colour banding. A fixed, very fine noise on top hides the steps of
  // 8-bit colour (dither).
  it('has one fixed noise layer on top, at a few percent', () => {
    expect(value(NOISE_RULE, 'content')).toBe('""')
    expect(value(NOISE_RULE, 'position')).toBe('absolute')
    expect(value(NOISE_RULE, 'inset')).toBe('0')
    expect(value(NOISE_RULE, 'pointer-events')).toBe('none')
    expect(value(NOISE_RULE, 'opacity')).toBe('var(--background-noise)')
    const noise = themeNumber('background-noise')
    expect(noise).toBeGreaterThan(0)
    expect(noise).toBeLessThanOrEqual(0.05)
    const image = value(NOISE_RULE, 'background-image')
    expect(image).toMatch(/^url\("data:image\/svg\+xml,/)
    expect(image).toContain('feTurbulence')
  })

  it('keeps the noise layer static: no animation, transition or transform', () => {
    for (const property of ['animation', 'transition', 'transform', 'will-change']) {
      expect(declarations(NOISE_RULE).map(([name]) => name)).not.toContain(property)
    }
    // No other rule targets the noise layer.
    expect(CSS.match(/::after\s*[{,]/g)).toHaveLength(1)
  })
})

describe('the motion of the background', () => {
  // the user, 2026-11-06: the motion felt a little slow.
  it('gives each field its own cycle: 17 to 37 s, with no common factor below 5', () => {
    const cycles = FIELDS.map(f => f.cycle)
    expect(new Set(cycles).size).toBe(cycles.length)
    for (const cycle of cycles) {
      expect(cycle).toBeGreaterThanOrEqual(17)
      expect(cycle).toBeLessThanOrEqual(37)
    }
    const bad: string[] = []
    for (const a of [...cycles, BASE.cycle]) {
      for (const b of [...cycles, BASE.cycle]) {
        const shared = gcd(a, b)
        if (a < b && [2, 3, 4].some(f => shared % f === 0)) bad.push(`${a} and ${b}`)
      }
    }
    expect(bad).toEqual([])
  })

  it('moves the base layer more slowly than the fields', () => {
    expect(BASE.cycle).toBeGreaterThan(Math.max(...FIELDS.map(f => f.cycle)))
    expect(BASE.cycle).toBeLessThanOrEqual(60)
  })

  it('runs each cycle forwards and back, without end, with a soft ease', () => {
    for (const layer of LAYERS) {
      expect(value(layer.rule, 'animation'), layer.name).toMatch(
        /^background-[\w-]+ \d+s ease-in-out infinite alternate$/,
      )
    }
  })

  it('animates only transform and opacity, with no filter', () => {
    for (const layer of LAYERS) {
      const names = new Set(declarations(layer.keyframes).map(([name]) => name))
      expect([...names].sort(), layer.name).toEqual(['opacity', 'transform'])
      expect(layer.keyframes).not.toMatch(/filter/)
    }
  })

  it('makes each field drift, scale and turn, and the base drift and turn', () => {
    for (const layer of LAYERS) {
      const parts = steps(layer.keyframes).flatMap(s => transformParts(value(s.body, 'transform')))
      const moved = (name: string, still: number) =>
        parts.some(p => p.name === name && p.args.some(a => Number.parseFloat(a) !== still))
      expect(moved('translate', 0), `${layer.name} drifts`).toBe(true)
      expect(moved('rotate', 0), `${layer.name} turns`).toBe(true)
      if (layer !== BASE) expect(moved('scale', 1), `${layer.name} scales`).toBe(true)
    }
  })

  // the user: "not with the whole bubbles going up and down". The layers drift mostly to the side.
  it('moves no layer up or down far: no bubble rises or sinks', () => {
    for (const layer of LAYERS) {
      for (const step of steps(layer.keyframes)) {
        for (const part of transformParts(value(step.body, 'transform'))) {
          expect(['translate', 'rotate', 'scale'], layer.name).toContain(part.name)
          if (part.name !== 'translate') continue
          const [x, y] = part.args
          expect(x).toMatch(/^-?[\d.]+%$/)
          expect(y).toMatch(/^-?[\d.]+%$/)
          expect(Math.abs(Number.parseFloat(y)), layer.name).toBeLessThanOrEqual(10)
        }
      }
    }
  })

  // The first step is the still position. So a layer starts from where it stays with no motion.
  it('starts each cycle at the still position, and never fades a layer out', () => {
    for (const layer of LAYERS) {
      const all = steps(layer.keyframes)
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

  it('uses the compositor only: will-change transform and no blur or blend', () => {
    expect(value(block(CSS, '.background-field {'), 'will-change')).toBe('transform')
    const rules = [
      block(CSS, '.background-field {'),
      BASE_RULE,
      NOISE_RULE,
      ...FIELDS.map(f => f.rule),
    ]
    for (const rule of rules) {
      const names = declarations(rule).map(([name]) => name)
      for (const name of ['filter', 'backdrop-filter', 'mix-blend-mode']) {
        expect(names).not.toContain(name)
      }
    }
  })

  // The stop rules have the same specificity as the rules that they stop, and come after them.
  // The animation shorthand sets the play state to running, so the pause rule must come after
  // the layer rules too.
  it('stops the motion of each layer with reduced motion and with the setting off from the start', () => {
    const last = Math.max(
      CSS.lastIndexOf('.background-field:nth-child('),
      CSS.indexOf('.background::before {'),
    )
    const reduced = CSS.indexOf('@media (prefers-reduced-motion: reduce)', last)
    expect(reduced).toBeGreaterThan(last)
    expect(blockAt(CSS, reduced)).toMatch(
      /^\s*\.background \.background-field,\s*\.background::before\s*\{\s*animation:\s*none;\s*\}\s*$/,
    )
    const still = CSS.indexOf('.background-still .background-field,', last)
    expect(still).toBeGreaterThan(last)
    expect(CSS.slice(still, CSS.indexOf('{', still))).toMatch(/,\s*\.background-still::before\s*$/)
    expect(declarations(blockAt(CSS, still))).toEqual([['animation', 'none']])
  })

  it('pauses each layer where it is, with no jump', () => {
    const last = Math.max(
      CSS.lastIndexOf('.background-field:nth-child('),
      CSS.indexOf('.background::before {'),
    )
    const paused = CSS.indexOf('.background-paused .background-field,', last)
    expect(paused).toBeGreaterThan(last)
    expect(CSS.slice(paused, CSS.indexOf('{', paused))).toMatch(
      /,\s*\.background-paused::before\s*$/,
    )
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

// The brief of 2026-11-06: at the brightest and the darkest point of the background, under a
// panel at the default Panel transparency, the text stays readable and the boxes stay clearly
// visible.
describe('the cover and the contrast of the background', () => {
  const DEFAULT_TRANSPARENCY = 15
  const grey = (n: number): string => hex([n, n, n])
  const rowOpacity = (): number => {
    const values = new Set(
      [...WATCH.matchAll(/bg-watch-[\w-]+\/(\d+)'/g)].map(m => Number(m[1]) / 100),
    )
    if (values.size !== 1) throw new Error('The watch row classes need one opacity')
    return [...values][0]
  }

  // The panel and the focused panel over a background colour. The blur can only make the
  // background closer to its mean, so the extremes are the worst cases.
  function panels(back: string): [string, string][] {
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

  function backs(): [string, string][] {
    const { brightest, darkest } = extremes()
    return [
      ['brightest', brightest],
      ['darkest', darkest],
    ]
  }

  it('covers the whole window at all times: no point is near black', () => {
    const { darkest } = extremes()
    if (process.env.EXTREMES_OUT) {
      const { brightest } = extremes()
      writeFileSync(
        process.env.EXTREMES_OUT,
        `${brightest} ${luminance(brightest).toFixed(4)} ${contrast(brightest, token('bg')).toFixed(3)} | ${darkest} ${luminance(darkest).toFixed(4)}`,
      )
    }
    expect(luminance(darkest)).toBeGreaterThanOrEqual(DARKEST_LUMINANCE)
    // The darkest point is a colour of the mix, not a grey.
    const channels = rgb(darkest)
    expect(Math.max(...channels) - Math.min(...channels)).toBeGreaterThanOrEqual(4)
  })

  // A gentle glow, not a bright rainbow: the brightest point is only a little lighter than the
  // base colour, at less than 1.6:1.
  it('stays dark: the brightest point is a faint glow over --color-bg', () => {
    const { brightest } = extremes()
    expect(contrast(brightest, token('bg'))).toBeLessThan(1.6)
    // Guard: the search finds at least the centre of each field at its full glow.
    for (const field of FIELDS) {
      const centre = mix(
        token(field.colour),
        themeNumber('background-glow') * field.weight,
        token('bg'),
      )
      expect(luminance(brightest), field.colour).toBeGreaterThanOrEqual(luminance(centre))
    }
  })

  it('keeps the panel text at 4.5:1 or more on each row', () => {
    const bad: string[] = []
    for (const [where, back] of backs()) {
      for (const [panel, surface] of panels(back)) {
        // The dim text shows on the panel itself, for example the hints of Settings.
        const dim = contrast(token('text-dim'), surface)
        if (dim < 4.5) bad.push(`text-dim on ${panel} at the ${where} point: ${dim.toFixed(2)}`)
        for (const [row, background] of rows(surface)) {
          for (const text of ['text', 'text-strong']) {
            const ratio = contrast(token(text), background)
            if (ratio < 4.5) bad.push(`${text} on ${row} on ${panel} at the ${where} point`)
          }
        }
      }
    }
    expect(bad).toEqual([])
  })

  it('keeps the box red and the box yellow at 3:1 or more on each row', () => {
    const bad: string[] = []
    for (const [where, back] of backs()) {
      for (const [panel, surface] of panels(back)) {
        for (const [row, background] of rows(surface)) {
          for (const box of ['box-red', 'box-yellow']) {
            const ratio = contrast(token(box), background)
            if (ratio < 3) {
              bad.push(`${box} on ${row} on ${panel} at the ${where} point: ${ratio.toFixed(2)}`)
            }
          }
        }
      }
    }
    expect(bad).toEqual([])
  })
})
