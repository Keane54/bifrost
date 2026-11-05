import type { MenuItemConstructorOptions } from 'electron'
import type { DisplayMode } from '../shared/types'

export interface MenuOptions {
  mode: DisplayMode
  isDev: boolean
  onMode(mode: DisplayMode): void
  onToggleFullscreen(): void
  onClosePanel(): void
}

// The menu of the app, as plain data. index.ts builds it again after each change of the mode.
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
