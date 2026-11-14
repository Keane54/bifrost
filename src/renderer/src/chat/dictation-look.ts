// The look of a chat window while it dictates (dictation design, section 6). This module reads no
// DOM. The level goes from 0 to 1, and e = level^0.8.
import type { CSSProperties } from 'react'
import type { DictationPhase } from './dictation-session'

// The width of the level bar in the header, in pixels.
export const BAR_WIDTH = 44
// The time constants of the smoothing, in seconds.
const ATTACK_S = 0.06
const RELEASE_S = 0.22
// The green of the look is the token --color-watch-green, the green of the mocks. A
// code file holds no colour value, so each alpha is a mix of the token with nothing.
export const GREEN_VAR = 'var(--color-watch-green)'

// The green with an alpha from 0 to 1.
export function greenAlpha(alpha: number): string {
  return `color-mix(in srgb, ${GREEN_VAR} ${(alpha * 100).toFixed(1)}%, transparent)`
}

export interface Look {
  // The alpha of the green top border.
  borderAlpha: number
  // The blur radius and the alpha of the shadow of the top border.
  borderShadowBlur: number
  borderShadowAlpha: number
  glowHeight: number
  glowAlpha: number
  glowBlur: number
  barWidth: number
}

function clamp(level: number): number {
  return Number.isFinite(level) ? Math.min(1, Math.max(0, level)) : 0
}

export function lookOf(level: number): Look {
  const l = clamp(level)
  const e = l ** 0.8
  return {
    barWidth: BAR_WIDTH * l,
    borderAlpha: 0.35 + 0.65 * e,
    borderShadowAlpha: 0.25 + 0.6 * e,
    borderShadowBlur: 2 + 10 * e,
    glowAlpha: 0.05 + 0.6 * e,
    glowBlur: 3.5 + 8.8 * e,
    glowHeight: 3.5 + 61.5 * e,
  }
}

// One step of the smoothing. The level rises fast and falls slower.
export function smoothLevel(current: number, target: number, dtSeconds: number): number {
  if (!(dtSeconds > 0)) return current
  const tau = target > current ? ATTACK_S : RELEASE_S
  return current + (target - current) * (1 - Math.exp(-dtSeconds / tau))
}

// The green look shows only while the microphone is open. A model download shows no green look.
export function dictationShows(phase: DictationPhase): boolean {
  return phase === 'listening'
}

// The glow falls down from the top line into the window (option B of the approved mock).
export const GLOW_CLASS = 'pointer-events-none absolute z-[2]'

export function glowStyleOf(look: Look): CSSProperties {
  const a = look.glowAlpha
  return {
    background:
      `radial-gradient(ellipse 67% 100% at 50% 0%, ${greenAlpha(a)} 0%, ` +
      `${greenAlpha(a * 0.35)} 45%, ${greenAlpha(0)} 75%)`,
    filter: `blur(${look.glowBlur.toFixed(1)}px)`,
    height: `${look.glowHeight.toFixed(1)}px`,
    left: '3%',
    pointerEvents: 'none',
    right: '3%',
    top: '1px',
  }
}

// The top line is one 2 px bar: the 1 px top border of the frame and this 1 px edge inside it.
export const EDGE_CLASS = 'pointer-events-none absolute inset-x-0 top-0 z-[2] h-px'

export function edgeStyleOf(look: Look): CSSProperties {
  return { background: greenAlpha(look.borderAlpha) }
}

// The border and the shadow of the frame itself. A shadow of the frame is not clipped by its
// overflow, so the shadow of the top line shows above the frame too.
export function frameEdgeStyleOf(look: Look): CSSProperties {
  // A spread of minus the blur pulls the shadow in at all sides. The offset of minus the blur
  // then puts it above the top edge only, so no haze shows at the sides or the bottom.
  const b = look.borderShadowBlur.toFixed(1)
  return {
    borderTopColor: greenAlpha(look.borderAlpha),
    boxShadow: `0 -${b}px ${b}px -${b}px ${greenAlpha(look.borderShadowAlpha)}`,
  }
}
