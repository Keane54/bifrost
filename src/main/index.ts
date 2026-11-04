import { join } from 'node:path'
import { electronApp, is, optimizer } from '@electron-toolkit/utils'
import { app, BrowserWindow, shell } from 'electron'
import icon from '../../resources/icon.png?asset'
import { attachWindow, closeAllPtys, registerIpc, stopRegistry } from './ipc'

function createWindow(): void {
  const mainWindow = new BrowserWindow({
    autoHideMenuBar: true,
    backgroundColor: '#0b0f14',
    height: 900,
    show: false,
    title: 'Bifrost',
    width: 1440,
    ...(process.platform === 'linux' ? { icon } : {}),
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: join(import.meta.dirname, '../preload/index.cjs'),
      // The preload uses only contextBridge and ipcRenderer, so it works in the sandbox.
      sandbox: true,
    },
  })

  attachWindow(mainWindow)

  mainWindow.on('ready-to-show', () => {
    mainWindow.show()
  })

  mainWindow.webContents.setWindowOpenHandler(details => {
    shell.openExternal(details.url)
    return { action: 'deny' }
  })

  // In development, electron-vite gives a URL with hot reload.
  // In production, the app loads the built HTML file.
  if (is.dev && process.env.ELECTRON_RENDERER_URL) {
    mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    mainWindow.loadFile(join(import.meta.dirname, '../renderer/index.html'))
  }
}

// Electron fires this event when it is ready to create windows.
app.whenReady().then(() => {
  electronApp.setAppUserModelId('com.electron')

  // F12 opens DevTools in development.
  // In production, the app ignores Command + R.
  app.on('browser-window-created', (_, window) => {
    optimizer.watchWindowShortcuts(window)
  })

  // Register the IPC handlers before any window loads a page.
  registerIpc()

  createWindow()

  // On macOS, a click on the Dock icon opens a window if none is open.
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

// On macOS, the app stays active after the last window closes.
// The user quits the app with Command + Q.
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

// Close all PTYs before the app quits. Then no attach client stays alive after Bifrost.
// Stop the registry service. Then no poll starts after this time.
app.on('will-quit', () => {
  closeAllPtys()
  stopRegistry()
})
