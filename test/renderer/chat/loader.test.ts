import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { type LoaderState, loaderStep, loaderText } from '../../../src/renderer/src/chat/loader'

// The repository has no DOM test. So the gradient checks read the source text.
const SRC = join(__dirname, '../../../src/renderer/src')
const CSS = readFileSync(join(SRC, 'styles/app.css'), 'utf8')
const LOADER = readFileSync(join(SRC, 'chat/TakeControlLoader.tsx'), 'utf8')
const PANEL = readFileSync(join(SRC, 'chat/ChatPanel.tsx'), 'utf8')

// The CSS rule of the rainbow, without its comments.
function rainbowRule(): string {
  const match = CSS.match(/\.loader-rainbow\s*\{([^}]*)\}/)
  if (!match) throw new Error('No .loader-rainbow rule')
  return match[1]
}

describe('loaderText', () => {
  it('names the session, or says only that Take control runs', () => {
    expect(loaderText('smoke-alpha')).toBe('Taking control of smoke-alpha...')
    expect(loaderText(null)).toBe('Taking control...')
    expect(loaderText('')).toBe('Taking control...')
  })
})

describe('loaderStep', () => {
  const RUNNING: LoaderState = { running: true, shown: false }

  it('start shows the loader while Take control runs', () => {
    expect(loaderStep(null, 'start')).toEqual(RUNNING)
  })

  it('stays until Take control worked and the terminal shows Claude, in either order', () => {
    const finished = loaderStep(RUNNING, 'finish')
    expect(finished).toEqual({ running: false, shown: false })
    expect(loaderStep(finished, 'shown')).toBeNull()
    const shown = loaderStep(RUNNING, 'shown')
    expect(shown).toEqual({ running: true, shown: true })
    expect(loaderStep(shown, 'finish')).toBeNull()
  })

  it('stop removes the loader, for example after a failure', () => {
    expect(loaderStep(RUNNING, 'stop')).toBeNull()
    expect(loaderStep({ running: true, shown: true }, 'stop')).toBeNull()
  })

  it('a session with no loader stays with no loader', () => {
    expect(loaderStep(null, 'finish')).toBeNull()
    expect(loaderStep(null, 'shown')).toBeNull()
    expect(loaderStep(null, 'stop')).toBeNull()
  })
})

// the user, 2026-11-06: no spaceship. A soft rainbow of the app icon colours fills the bottom third.
describe('the rainbow of the loader', () => {
  it('uses the six icon tokens and adds no colour token of its own', () => {
    const rule = rainbowRule()
    for (let i = 1; i <= 6; i++) expect(rule).toContain(`var(--color-icon-${i})`)
    // The mask holds only alpha steps (black at an alpha), not a colour that shows.
    const colours = rule.replace(/mask-image:[^;]*;/, '')
    expect(colours).not.toMatch(/#[0-9a-f]{3,8}\b|rgba?\(|hsla?\(/i)
    expect(CSS).not.toMatch(/--color-loader/)
  })

  it('fades in from transparent at its top edge, so it has no hard line', () => {
    expect(rainbowRule()).toMatch(/mask-image:\s*linear-gradient\(\s*to bottom,\s*transparent/)
  })

  // the user (2026-11-06): the fade was too harsh. The mask now eases in over the whole height: it
  // has many steps, the upper half stays faint, and it is at full strength only at the bottom.
  it('fades in gradually over the whole height, with an eased curve', () => {
    const mask = rainbowRule().match(/mask-image:\s*linear-gradient\(([^;]*)\);/)?.[1] ?? ''
    const alphas = [...mask.matchAll(/rgb\(0 0 0 \/ ([\d.]+)\) (\d+)%/g)].map(m => ({
      alpha: Number(m[1]),
      at: Number(m[2]),
    }))
    expect(alphas.length).toBeGreaterThanOrEqual(5)
    for (const step of alphas.filter(s => s.at <= 50)) expect(step.alpha).toBeLessThanOrEqual(0.25)
    expect(mask).toMatch(/black 100%\s*$/)
  })

  it('moves slowly, and does not move with reduced motion', () => {
    const animation = CSS.match(/--animate-loader-shift:\s*loader-shift\s+(\d+)s/)
    expect(Number(animation?.[1])).toBeGreaterThanOrEqual(8)
    expect(CSS).toMatch(/@keyframes loader-shift/)
    expect(LOADER).toContain('animate-loader-shift')
    expect(LOADER).toContain('motion-reduce:animate-none')
  })

  it('fills only the bottom third, softly, and draws no canvas', () => {
    expect(LOADER).toMatch(/bottom-0[^']*h-1\/3|h-1\/3[^']*bottom-0/)
    expect(LOADER).toMatch(/loader-rainbow[^']*opacity-(\d+)|opacity-(\d+)[^']*loader-rainbow/)
    const opacity = Number(LOADER.match(/opacity-(\d+)/)?.[1])
    expect(opacity).toBeLessThanOrEqual(25)
    expect(LOADER).not.toContain('<canvas')
    expect(LOADER).not.toContain('requestAnimationFrame')
  })

  it('hides the terminal while the loader shows, so the panel background shows', () => {
    expect(PANEL).toContain("loading && 'opacity-0'")
  })
})
