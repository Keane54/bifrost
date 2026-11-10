// The animated background (spec 8.10). It is one layer behind all frames and the side bar. It
// holds a base gradient and soft colour fields of the app icon colours. Each is a canvas. This view
// draws each canvas one time from the colour tokens, at a part of the device pixels of its box,
// and CSS scales it up to its box (user decision, 2026-11-10). The CSS animations of app.css move
// the canvases. The view holds the animations and sets their time 30 times each second. The motion
// pauses while the window does not have the focus or the page is hidden, and when the Animated
// background setting goes off. With reduced motion, or with the setting off at the start, the
// fields stay at their still position.
import { type RefObject, useEffect, useRef, useState } from 'react'
import { useSettings } from '../settings/settings-context'
import {
  BASE_ANGLE,
  BASE_COLOURS,
  canvasSize,
  FIELD_FADE,
  gradientLine,
  hexColour,
  MOTION_STEP_MS,
  motionTime,
  type PixelSize,
  partOf,
  stopColour,
} from './background-paint'
import {
  BACKGROUND_FIELDS,
  type BackgroundMotion,
  backgroundClass,
  backgroundMotion,
  windowActive,
} from './background-style'

const FIELDS = Array.from({ length: BACKGROUND_FIELDS }, (_, i) => i)

const REDUCED_MOTION = '(prefers-reduced-motion: reduce)'

// The settings of the 2D context of each canvas.
const CONTEXT: CanvasRenderingContext2DSettings = { alpha: true }

// Set the size of the canvas and get its 2D context. A new size also clears the canvas.
function sizedContext(canvas: HTMLCanvasElement, size: PixelSize): CanvasRenderingContext2D | null {
  canvas.width = size.width
  canvas.height = size.height
  return canvas.getContext('2d', CONTEXT)
}

// Draw a colour field: an ellipse that touches the four sides of the canvas, as closest-side in
// CSS. The glow at the centre is the glow token times the weight of the field.
function drawField(canvas: HTMLCanvasElement, size: PixelSize): void {
  const style = getComputedStyle(canvas)
  const colour = hexColour(style.getPropertyValue('--field-colour'))
  const glow =
    partOf(style.getPropertyValue('--field-glow')) *
    partOf(style.getPropertyValue('--field-weight'))
  const ctx = sizedContext(canvas, size)
  if (!ctx || !colour) return
  // The transform changes the circle of radius 1 at the origin into the ellipse of the canvas.
  ctx.setTransform(size.width / 2, 0, 0, size.height / 2, size.width / 2, size.height / 2)
  const gradient = ctx.createRadialGradient(0, 0, 0, 0, 0, 1)
  for (const [at, part] of FIELD_FADE) gradient.addColorStop(at, stopColour(colour, glow * part))
  ctx.fillStyle = gradient
  ctx.fillRect(-1, -1, 2, 2)
}

// Draw the base: a linear gradient of the icon colours, each at the base alpha. The canvas mixes
// the stops in sRGB. CSS mixed them in OKLab. At the base alpha, the difference is less than one
// step of 8-bit colour.
function drawBase(canvas: HTMLCanvasElement, size: PixelSize): void {
  const style = getComputedStyle(canvas)
  const alpha = partOf(style.getPropertyValue('--base-alpha'))
  const colours = BASE_COLOURS.map(name => hexColour(style.getPropertyValue(`--color-${name}`)))
  const ctx = sizedContext(canvas, size)
  if (!ctx) return
  const gradient = ctx.createLinearGradient(...gradientLine(BASE_ANGLE, size.width, size.height))
  colours.forEach((colour, i) => {
    if (colour) gradient.addColorStop(i / (colours.length - 1), stopColour(colour, alpha))
  })
  ctx.fillStyle = gradient
  ctx.fillRect(0, 0, size.width, size.height)
}

// Draw each canvas when its size in device pixels changes: at the start, when the window changes
// size, and when the window goes to a display with a different scale.
function useCanvases(root: RefObject<HTMLDivElement | null>): void {
  useEffect(() => {
    const element = root.current
    if (!element) return
    const observer = new ResizeObserver(entries => {
      for (const entry of entries) {
        const canvas = entry.target as HTMLCanvasElement
        const box = entry.devicePixelContentBoxSize?.[0]
        const device = box
          ? { height: box.blockSize, width: box.inlineSize }
          : {
              height: entry.contentRect.height * window.devicePixelRatio,
              width: entry.contentRect.width * window.devicePixelRatio,
            }
        const size = canvasSize(device)
        if (canvas.classList.contains('background-base')) drawBase(canvas, size)
        else drawField(canvas, size)
      }
    })
    for (const canvas of element.querySelectorAll('canvas')) {
      observer.observe(canvas, { box: 'device-pixel-content-box' })
    }
    return () => observer.disconnect()
  }, [root])
}

// Move the layers 30 times each second while the motion is on (user decision, 2026-11-10). The
// view holds the CSS animations of the layers and sets their time from one clock. So the
// compositor makes a new frame of the background only at each step, not at each refresh of the
// display. The cleanup stops the timer. So no timer runs while the motion is paused or still.
function useSteppedMotion(root: RefObject<HTMLDivElement | null>, motion: BackgroundMotion): void {
  useEffect(() => {
    const element = root.current
    if (!element || motion !== 'moving') return
    const animations = element.getAnimations({ subtree: true })
    if (animations.length === 0) return
    // The clock continues from the time of the layers: the paused time after a pause, or 0 for
    // new animations. The layers always have the same time.
    const from = Math.max(0, ...animations.map(a => Number(a.currentTime) || 0))
    const startedAt = performance.now()
    const step = (): void => {
      const time = motionTime(from, startedAt, performance.now())
      for (const animation of animations) {
        // A style change can remove an animation, for example reduced motion. A new time would
        // start a removed animation again.
        if (animation.playState !== 'idle') animation.currentTime = time
      }
    }
    for (const animation of animations) animation.pause()
    step()
    const timer = window.setInterval(step, MOTION_STEP_MS)
    return () => window.clearInterval(timer)
  }, [root, motion])
}

// True while the window has the focus and the page is visible. The window focus and blur events
// follow the key window of macOS in Electron. No main process message is necessary.
function useWindowActive(): boolean {
  const [active, setActive] = useState(() => windowActive(document))
  useEffect(() => {
    const update = (): void => setActive(windowActive(document))
    window.addEventListener('focus', update)
    window.addEventListener('blur', update)
    document.addEventListener('visibilitychange', update)
    update()
    return () => {
      window.removeEventListener('focus', update)
      window.removeEventListener('blur', update)
      document.removeEventListener('visibilitychange', update)
    }
  }, [])
  return active
}

// True while the system asks for reduced motion.
function useReducedMotion(): boolean {
  const [reduced, setReduced] = useState(() => window.matchMedia(REDUCED_MOTION).matches)
  useEffect(() => {
    const query = window.matchMedia(REDUCED_MOTION)
    const update = (): void => setReduced(query.matches)
    query.addEventListener('change', update)
    update()
    return () => query.removeEventListener('change', update)
  }, [])
  return reduced
}

export default function Background(): React.JSX.Element {
  const { settings, ready } = useSettings()
  // The settings are the defaults until the first get resolves. So a setting that is off at the
  // start does not count as a change from on to off.
  const animated = ready && settings.animatedBackground
  const [ran, setRan] = useState(false)
  useEffect(() => {
    if (animated) setRan(true)
  }, [animated])
  const active = useWindowActive()
  const reduced = useReducedMotion()
  const motion = backgroundMotion({ active, animated, ran: ran || animated, reduced })
  const rootRef = useRef<HTMLDivElement>(null)
  useCanvases(rootRef)
  useSteppedMotion(rootRef, motion)
  return (
    <div aria-hidden={true} className={backgroundClass(motion)} ref={rootRef}>
      {FIELDS.map(i => (
        <canvas className='background-field' key={i} />
      ))}
      <canvas className='background-base' />
    </div>
  )
}
