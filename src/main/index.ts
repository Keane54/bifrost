import { join } from 'node:path'
import { electronApp, is, optimizer } from '@electron-toolkit/utils'
import { app, BrowserWindow } from 'electron'
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

  // The window shows only the Bifrost page. A link or a script cannot open another page in it.
  // A reload of the same URL stays possible, because Vite reloads the page in development.
  // The page also cannot open a new window.
  mainWindow.webContents.on('will-navigate', e => {
    if (e.url !== mainWindow.webContents.getURL()) e.preventDefault()
  })
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))

  // In development, electron-vite gives a URL with hot reload.
  // In production, the app loads the built HTML file.
  if (is.dev && process.env.ELECTRON_RENDERER_URL) {
    mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    mainWindow.loadFile(join(import.meta.dirname, '../renderer/index.html'))
  }
}

// Show and focus the window of this instance. Open a window if none is open.
function showWindow(): void {
  if (!app.isReady()) return
  const win = BrowserWindow.getAllWindows()[0]
  if (!win) {
    createWindow()
    return
  }
  if (win.isMinimized()) win.restore()
  win.show()
  win.focus()
}

// Start the app. Only the first instance calls this function.
function startApp(): void {
  // A second start of Bifrost shows the window of this instance.
  app.on('second-instance', () => showWindow())

  // Electron fires this event when it is ready to create windows.
  app.whenReady().then(() => {
    electronApp.setAppUserModelId('com.electron')

    // F12 opens DevTools in development.
    // In production, the app ignores Command + R.
    app.on('browser-window-created', (_, window) => {
      optimizer.watchWindowShortcuts(window)
    })

    // Register the IPC handlers before any window loads a page.
    // This also makes the active marker file and starts the registry service.
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
  // This also deletes the active marker file. Then the scripts stop their work.
  app.on('will-quit', () => {
    closeAllPtys()
    stopRegistry()
  })
}

// Only one Bifrost runs at a time. Two instances would each read only some of the event files,
// and both could change the settings file.
// A second instance quits at once. It registers no IPC, makes no marker file and starts no service.
// So it cannot delete the marker file of the first instance when it quits.
if (app.requestSingleInstanceLock()) {
  startApp()
} else {
  app.quit()
}
