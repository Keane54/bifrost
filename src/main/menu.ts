import type { MenuItemConstructorOptions } from 'electron'
import { type KeyMap, toAccelerator } from '../shared/keys'
import {
  DEFAULT_SETTINGS,
  INTERFACE_SCALE_MAX,
  INTERFACE_SCALE_MIN,
  INTERFACE_SCALE_STEP,
} from '../shared/settings'
import type { DisplayMode } from '../shared/types'
import type { ModeController } from './window/display-mode'

// The Electron accelerators of the two menu keys (D7). null means no key.
export interface MenuKeys {
  closePanel: string | null
  fullscreen: string | null
}

// Zoom In, Zoom Out and Actual Size of the View menu (ruling C1).
export type ZoomStep = 'in' | 'out' | 'reset'

export interface MenuOptions {
  mode: DisplayMode
  isDev: boolean
  keys: MenuKeys
  onMode(mode: DisplayMode): void
  onToggleFullscreen(): void
  onClosePanel(): void
  onZoom(step: ZoomStep): void
}

// Return the accelerator of a binding of the key map, or null for no key.
function acceleratorOf(binding: string | null | undefined): string | null {
  return typeof binding === 'string' ? toAccelerator(binding) : null
}

// Return the accelerators of Close Panel and Fullscreen from the key map.
export function menuKeys(keys: KeyMap): MenuKeys {
  return {
    closePanel: acceleratorOf(keys['close-panel:mod']),
    fullscreen: acceleratorOf(keys['toggle-fullscreen:mod']),
  }
}

// Return the Interface scale after a Zoom item. A step stays from 80 to 150 percent.
// Actual Size gives the default scale.
export function zoomStep(scale: number, step: ZoomStep): number {
  if (step === 'reset') return DEFAULT_SETTINGS.interfaceScale
  const next = scale + (step === 'in' ? INTERFACE_SCALE_STEP : -INTERFACE_SCALE_STEP)
  return Math.min(INTERFACE_SCALE_MAX, Math.max(INTERFACE_SCALE_MIN, next))
}

// Add the accelerator to an item only when the key is not null.
function withKey(
  item: MenuItemConstructorOptions,
  accelerator: string | null,
): MenuItemConstructorOptions {
  return accelerator === null ? item : { ...item, accelerator }
}

export interface ModeHandlerOptions {
  // The mode controller of the open window. It is null when no window is open.
  controller(): ModeController | null
  // Build the menu again from the real mode.
  rebuild(): void
}

// The click handlers of the View items.
// macOS moves the radio check mark at each click, also when the mode does not change.
// So the menu builds again at the click, and again after the change ends.
// The handlers read the controller at each click. So they never use the controller of a closed
// window. With no window, a click changes nothing. A change that fails goes to the console.
export function modeHandlers(opts: ModeHandlerOptions): {
  onMode(mode: DisplayMode): Promise<void>
  onToggleFullscreen(): Promise<void>
} {
  const run = async (change: (controller: ModeController) => Promise<void>): Promise<void> => {
    const controller = opts.controller()
    opts.rebuild()
    if (!controller) return
    try {
      await change(controller)
    } catch (err) {
      console.error('Bifrost cannot change the display mode.', err)
    }
    opts.rebuild()
  }
  return {
    onMode: mode => run(controller => controller.set(mode)),
    onToggleFullscreen: () => run(controller => controller.toggleFullscreen()),
  }
}

// The menu of the app, as plain data. index.ts builds it again after each change of the mode,
// after each click on a View item and after a change of a menu key.
// The Window menu has no item with the role close. Cmd+W closes the active panel, not the window.
// The dev Reload item uses F5. Cmd+R is the Resume key of the renderer.
export function buildMenuTemplate(opts: MenuOptions): MenuItemConstructorOptions[] {
  const { keys, mode } = opts
  return [
    {
      label: 'Bifrost',
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' },
      ],
    },
    {
      label: 'Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' },
      ],
    },
    {
      label: 'View',
      submenu: [
        {
          checked: mode === 'window',
          click: () => opts.onMode('window'),
          label: 'Window',
          type: 'radio',
        },
        {
          checked: mode === 'borderless',
          click: () => opts.onMode('borderless'),
          label: 'Borderless',
          type: 'radio',
        },
        withKey(
          {
            checked: mode === 'fullscreen',
            click: () => opts.onToggleFullscreen(),
            label: 'Fullscreen',
            type: 'radio',
          },
          keys.fullscreen,
        ),
        { type: 'separator' },
        { accelerator: 'Cmd+=', click: () => opts.onZoom('in'), label: 'Zoom In' },
        { accelerator: 'Cmd+-', click: () => opts.onZoom('out'), label: 'Zoom Out' },
        { click: () => opts.onZoom('reset'), label: 'Actual Size' },
        ...(opts.isDev
          ? [
              { type: 'separator' } as const,
              { accelerator: 'F5', role: 'reload' } as const,
              { role: 'toggleDevTools' } as const,
            ]
          : []),
      ],
    },
    {
      label: 'Window',
      submenu: [
        withKey({ click: () => opts.onClosePanel(), label: 'Close Panel' }, keys.closePanel),
        { role: 'minimize' },
        { role: 'zoom' },
      ],
    },
  ]
}
