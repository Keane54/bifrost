import type { DisplayMode } from '../../shared/types'

// The parts of BrowserWindow that the mode controller uses.
export interface ModeWindow {
  isDestroyed(): boolean
  isFullScreen(): boolean
  setFullScreen(on: boolean): void
  isSimpleFullScreen(): boolean
  setSimpleFullScreen(on: boolean): void
  once(event: 'enter-full-screen' | 'leave-full-screen', cb: () => void): void
}

export interface ModeController {
  get(): DisplayMode
  set(mode: DisplayMode): Promise<void>
  toggleFullscreen(): Promise<void>
  sync(): void
}

// Change the display mode of a window. The mode always comes from the window itself.
// Calls run one after the other. A call starts after the call before it ends.
export function createModeController(
  win: ModeWindow,
  onChange: (mode: DisplayMode) => void,
  waitMs = 3000,
): ModeController {
  // The last mode that sync saw.
  let last: DisplayMode = 'window'
  // A closed window throws on each read. The closed event can build the menu again, and the menu
  // reads the mode. So a closed window gives the last mode.
  const get = (): DisplayMode => {
    if (win.isDestroyed()) return last
    if (win.isFullScreen()) return 'fullscreen'
    if (win.isSimpleFullScreen()) return 'borderless'
    return 'window'
  }
  last = get()
  // The mode before the last start of Fullscreen.
  let before: DisplayMode = 'window'
  let queue: Promise<void> = Promise.resolve()

  // Call onChange one time for each change of the real mode.
  const sync = (): void => {
    const mode = get()
    if (mode === last) return
    if (mode === 'fullscreen') before = last
    last = mode
    onChange(mode)
  }

  // Start a change of the native full screen. Then wait for its event.
  // If the event does not come, stop the wait after waitMs.
  const change = (event: 'enter-full-screen' | 'leave-full-screen', on: boolean): Promise<void> =>
    new Promise(resolve => {
      let done = false
      const finish = (): void => {
        if (done) return
        done = true
        clearTimeout(timer)
        resolve()
      }
      const timer = setTimeout(finish, waitMs)
      win.once(event, finish)
      win.setFullScreen(on)
    })

  const apply = async (mode: DisplayMode): Promise<void> => {
    if (mode === get()) return
    if (mode === 'fullscreen') {
      if (win.isSimpleFullScreen()) win.setSimpleFullScreen(false)
      await change('enter-full-screen', true)
    } else {
      if (win.isFullScreen()) await change('leave-full-screen', false)
      if (mode === 'borderless') win.setSimpleFullScreen(true)
      else if (win.isSimpleFullScreen()) win.setSimpleFullScreen(false)
    }
    sync()
  }

  const set = (mode: DisplayMode): Promise<void> => {
    const run = queue.then(() => apply(mode))
    queue = run.catch(() => {})
    return run
  }

  const toggleFullscreen = (): Promise<void> => {
    // Read the mode when the call starts, not when it is queued.
    const run = queue.then(() => apply(get() === 'fullscreen' ? before : 'fullscreen'))
    queue = run.catch(() => {})
    return run
  }

  return { get, set, sync, toggleFullscreen }
}
