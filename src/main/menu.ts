import type { MenuItemConstructorOptions } from 'electron'
import type { DisplayMode } from '../shared/types'
import type { ModeController } from './window/display-mode'

export interface MenuOptions {
  mode: DisplayMode
  isDev: boolean
  onMode(mode: DisplayMode): void
  onToggleFullscreen(): void
  onClosePanel(): void
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

// The menu of the app, as plain data. index.ts builds it again after each change of the mode
// and after each click on a View item.
// The Window menu has no item with the role close. Cmd+W closes the active panel, not the window.
export function buildMenuTemplate(opts: MenuOptions): MenuItemConstructorOptions[] {
  const { mode } = opts
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
        {
          accelerator: 'Ctrl+Cmd+F',
          checked: mode === 'fullscreen',
          click: () => opts.onToggleFullscreen(),
          label: 'Fullscreen',
          type: 'radio',
        },
        ...(opts.isDev
          ? [
              { type: 'separator' } as const,
              { role: 'reload' } as const,
              { role: 'toggleDevTools' } as const,
            ]
          : []),
      ],
    },
    {
      label: 'Window',
      submenu: [
        { accelerator: 'Cmd+W', click: () => opts.onClosePanel(), label: 'Close Panel' },
        { role: 'minimize' },
        { role: 'zoom' },
      ],
    },
  ]
}
