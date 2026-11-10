// The animated background (spec 8.10). It is one layer behind all frames and the side bar. It
// holds a base gradient and soft colour fields of the app icon colours. Each is a canvas. This view
// draws each canvas from the colour tokens, at a part of the device pixels of its box, and CSS
// scales it up to its box (user decision, 2026-11-10). After a change of size, the view first
// draws a plain gradient. When the size stays the same for a short time, it paints the gradient
// again with a fine dither. The CSS animations of app.css move the canvases. The view holds the
// animations and sets their time 30 times each second. The motion pauses while the window does
// not have the focus or the page is hidden, and when the Animated background setting goes off.
// With reduced motion, or with the setting off at the start, the fields stay at their still
// position.
import { type RefObject, useEffect, useRef, useState } from 'react'
import { useSettings } from '../settings/settings-context'
import {
  BASE_ANGLE,
  BASE_COLOURS,
  basePainter,
  canvasSize,
  FIELD_FADE,
  fieldPainter,
  gradientLine,
  hexColour,
  MOTION_STEP_MS,
  motionTime,
  type Painter,
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

// The time in milliseconds that the size of the canvases must stay the same before the view
// paints the dither. A window that changes size gets only the plain draw, which is fast.
const DITHER_DELAY_MS = 300

// The longest time in milliseconds of one task of the dither paint. Between two tasks, the page
// can do other work, for example a step of the motion.
const DITHER_SLICE_MS = 8

// The largest number of bytes of one write of the dither paint to a canvas.
const UPLOAD_BYTES = 1 << 20

// The colour and the glow of a field, from its tokens. The glow at the centre is the glow token
// times the weight of the field.
function fieldTokens(canvas: HTMLCanvasElement): { colour: number[] | null; glow: number } {
  const style = getComputedStyle(canvas)
  return {
    colour: hexColour(style.getPropertyValue('--field-colour')),
    glow:
      partOf(style.getPropertyValue('--field-glow')) *
      partOf(style.getPropertyValue('--field-weight')),
  }
}

// The alpha and the stops of the base, from its tokens. The stops are equally spaced on the
// gradient line. A token that is not a colour gives no stop.
function baseTokens(canvas: HTMLCanvasElement): {
  alpha: number
  stops: [number, number[]][]
} {
  const style = getComputedStyle(canvas)
  const stops: [number, number[]][] = []
  BASE_COLOURS.forEach((name, i) => {
    const colour = hexColour(style.getPropertyValue(`--color-${name}`))
    if (colour) stops.push([i / (BASE_COLOURS.length - 1), colour])
  })
  return { alpha: partOf(style.getPropertyValue('--base-alpha')), stops }
}

// Draw a colour field: an ellipse that touches the four sides of the canvas, as closest-side in
// CSS.
function drawField(canvas: HTMLCanvasElement, size: PixelSize): void {
  const { colour, glow } = fieldTokens(canvas)
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
  const { alpha, stops } = baseTokens(canvas)
  const ctx = sizedContext(canvas, size)
  if (!ctx) return
  const gradient = ctx.createLinearGradient(...gradientLine(BASE_ANGLE, size.width, size.height))
  for (const [at, colour] of stops) gradient.addColorStop(at, stopColour(colour, alpha))
  ctx.fillStyle = gradient
  ctx.fillRect(0, 0, size.width, size.height)
}

// The paint of the same gradient as drawField or drawBase, with the dither. Each canvas has its
// own seed, so two layers that overlap do not have the same grain.
function painterOf(canvas: HTMLCanvasElement, size: PixelSize, seed: number): Painter | null {
  if (canvas.classList.contains('background-base')) {
    const { alpha, stops } = baseTokens(canvas)
    return basePainter(size, stops, alpha, BASE_ANGLE, seed)
  }
  const { colour, glow } = fieldTokens(canvas)
  return colour ? fieldPainter(size, colour, glow, seed) : null
}

// Draw each canvas when its size in device pixels changes: at the start, when the window changes
// size, and when the window goes to a display with a different scale. The plain draw occurs at
// once. The dither paint occurs when the size stays the same for DITHER_DELAY_MS. It paints a few
// rows in each task, one canvas after the other. A new size stops it, and it starts again later.
function useCanvases(root: RefObject<HTMLDivElement | null>): void {
  useEffect(() => {
    const element = root.current
    if (!element) return
    const canvases = [...element.querySelectorAll('canvas')]
    const sizes = new Map<HTMLCanvasElement, PixelSize>()
    let timer = 0
    const dither = (index: number, painter: Painter | null, row: number): void => {
      if (index >= canvases.length) return
      const canvas = canvases[index]
      const size = sizes.get(canvas)
      const current = painter ?? (size ? painterOf(canvas, size, index + 1) : null)
      let next = row
      if (current && size) {
        const end = performance.now() + DITHER_SLICE_MS
        // Paint 8 rows at a time until the time of the task is over.
        while (next < size.height && performance.now() < end) {
          current.rows(next, next + 8)
          next += 8
        }
        if (next < size.height) {
          timer = window.setTimeout(() => dither(index, current, next), 0)
          return
        }
        if (canvas.width === size.width && canvas.height === size.height) {
          // The compositor holds the GPU image of the plain draw. A write to the canvas then
          // goes to a second GPU image, and the canvas keeps the first image for later use. A
          // change of size releases both images. So the width goes to 0 and back, and the pixels
          // go to a new image. No frame occurs in this task, so the empty canvas does not show.
          canvas.width = 0
          const ctx = sizedContext(canvas, size)
          const image = new ImageData(current.pixels, size.width, size.height)
          // One large write keeps a large block of shared memory in the renderer and in the GPU
          // process after the write. Bands of about 1 MB use only a small block.
          const band = Math.max(1, Math.floor(UPLOAD_BYTES / (4 * size.width)))
          for (let top = 0; top < size.height; top += band) {
            ctx?.putImageData(image, 0, 0, 0, top, size.width, band)
          }
        }
      }
      timer = window.setTimeout(() => dither(index + 1, null, 0), 0)
    }
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
        sizes.set(canvas, size)
        if (canvas.classList.contains('background-base')) drawBase(canvas, size)
        else drawField(canvas, size)
      }
      window.clearTimeout(timer)
      timer = window.setTimeout(() => dither(0, null, 0), DITHER_DELAY_MS)
    })
    for (const canvas of canvases) observer.observe(canvas, { box: 'device-pixel-content-box' })
    return () => {
      observer.disconnect()
      window.clearTimeout(timer)
    }
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
