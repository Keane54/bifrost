import { homedir } from 'node:os'
import { join } from 'node:path'
import { electronApp, is } from '@electron-toolkit/utils'
import { app, BrowserWindow, Menu, screen, systemPreferences } from 'electron'
import icon from '../../resources/icon.png?asset'
import { effectiveKeys } from '../shared/keys'
import {
  attachWindow,
  closeAllPtys,
  getSettings,
  patchSettings,
  registerIpc,
  send,
  setMenuRebuild,
  setModeController,
  stopRegistry,
} from './ipc'
import { buildMenuTemplate, menuKeys, modeHandlers, zoomStep } from './menu'
import { refusedTestHome, testHomeConfig, testHomeError } from './test-home'
import { createModeController, type ModeController } from './window/display-mode'
import { openWindowStateStore, restoreBounds } from './window/window-state'

// The test home (D12). Read it before the single instance lock, because the lock uses the
// userData folder. So a test home gets its own lock and runs beside the real Bifrost.
const testHome = testHomeConfig(process.env, homedir())
// A value that Bifrost refuses must not fall back to the real home.
const badTestHome = refusedTestHome(process.env, homedir())
if (testHome) {
  app.setPath('userData', testHome.userData)
  console.log(`Bifrost uses the test home ${testHome.home}.`)
}

const DEFAULT_SIZE = { height: 900, width: 1440 }
// The smallest size of the window. In a smaller window, the panels would be too small to use.
const MIN_WINDOW = { minHeight: 500, minWidth: 800 }
// Bifrost saves the bounds 500 ms after the last move or resize.
const BOUNDS_DELAY_MS = 500

// The mode controller of the open window. It is null when no window is open.
let modeController: ModeController | null = null

// The View items read the controller at each click. So they do nothing while no window is open.
const viewHandlers = modeHandlers({ controller: () => modeController, rebuild: () => showMenu() })

// Build the app menu from the real mode and the key map. Bifrost builds it again after each
// change of the mode, after each click on a View item, when the settings store opens and after
// a change of a menu key. So the radio items show the real mode and the keys are current.
// A Zoom item steps the Interface scale setting. The settings store then zooms the page.
function showMenu(): void {
  Menu.setApplicationMenu(
    Menu.buildFromTemplate(
      buildMenuTemplate({
        isDev: is.dev,
        keys: menuKeys(effectiveKeys(getSettings().keys)),
        mode: modeController?.get() ?? 'window',
        onClosePanel: () => send('wm:close-panel'),
        onZoom: step =>
          patchSettings({ interfaceScale: zoomStep(getSettings().interfaceScale, step) }),
        ...viewHandlers,
      }),
    ),
  )
}

async function createWindow(): Promise<void> {
  const store = await openWindowStateStore(join(app.getPath('userData'), 'window-state.json'))
  // The app can quit, or another call can open a window, during the wait above.
  if (BrowserWindow.getAllWindows().length > 0) return
  const workAreas = screen.getAllDisplays().map(d => d.workArea)
  const mainWindow = new BrowserWindow({
    autoHideMenuBar: true,
    // This colour must match --color-bg in src/renderer/src/styles/app.css.
    backgroundColor: '#0a0a0a',
    ...MIN_WINDOW,
    show: false,
    title: 'Bifrost',
    ...restoreBounds(store.state.bounds, workAreas, DEFAULT_SIZE),
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

  const controller = createModeController(mainWindow, mode => {
    void store.update({ mode }).catch(err => console.error('Bifrost cannot save the mode.', err))
    send('display:changed', mode)
    showMenu()
  })
  modeController = controller
  setModeController(controller)
  showMenu()
  // The green button and the Esc key change the mode without a call to the controller.
  mainWindow.on('enter-full-screen', () => controller.sync())
  mainWindow.on('leave-full-screen', () => controller.sync())

  // Save the bounds of the normal window, not the bounds of a full screen.
  const saveBounds = (): void => {
    if (mainWindow.isDestroyed()) return
    void store
      .update({ bounds: mainWindow.getNormalBounds() })
      .catch(err => console.error('Bifrost cannot save the window bounds.', err))
  }
  let boundsTimer: NodeJS.Timeout | undefined
  const saveBoundsLater = (): void => {
    clearTimeout(boundsTimer)
    boundsTimer = setTimeout(saveBounds, BOUNDS_DELAY_MS)
  }
  mainWindow.on('resize', saveBoundsLater)
  mainWindow.on('move', saveBoundsLater)
  mainWindow.on('close', () => {
    clearTimeout(boundsTimer)
    saveBounds()
  })
  // The menu and the IPC handlers must not use the controller of a closed window.
  mainWindow.on('closed', () => {
    if (modeController === controller) modeController = null
    setModeController(null)
  })

  mainWindow.on('ready-to-show', () => {
    mainWindow.show()
    // Apply the saved mode. The controller saves the mode again when it changes.
    controller
      .set(store.state.mode)
      .catch(err => console.error('Bifrost cannot apply the saved display mode.', err))
  })

  // The window shows only the Bifrost page. A link or a script cannot open another page in it.
  // A reload of the same URL stays possible, because Vite reloads the page in development.
  // The page also cannot open a new window.
  mainWindow.webContents.on('will-navigate', e => {
    if (e.url !== mainWindow.webContents.getURL()) e.preventDefault()
  })
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))

  // In development, F12 opens or closes the DevTools. Bifrost does not use the electron-toolkit
  // optimizer. It blocks Cmd+R (Resume) in the packaged app, and Cmd+- (Zoom Out) at all times.
  if (is.dev) {
    mainWindow.webContents.on('before-input-event', (event, input) => {
      if (input.type !== 'keyDown' || input.code !== 'F12') return
      event.preventDefault()
      const { webContents } = mainWindow
      if (webContents.isDevToolsOpened()) webContents.closeDevTools()
      else webContents.openDevTools({ mode: 'undocked' })
    })
  }

  // In development, electron-vite gives a URL with hot reload.
  // In production, the app loads the built HTML file.
  if (is.dev && process.env.ELECTRON_RENDERER_URL) {
    mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    mainWindow.loadFile(join(import.meta.dirname, '../renderer/index.html'))
  }
}

// Open the window. An error goes to the console.
function openWindow(): void {
  createWindow().catch(err => console.error('Bifrost cannot open the window.', err))
}

// Show and focus the window of this instance. Open a window if none is open.
function showWindow(): void {
  if (!app.isReady()) return
  const win = BrowserWindow.getAllWindows()[0]
  if (!win) {
    openWindow()
    return
  }
  if (win.isMinimized()) win.restore()
  win.show()
  win.focus()
}

// Start the app. Only the first instance calls this function.
function startApp(): void {
  // macOS adds its own item "Enter Full Screen" to a menu with the name View.
  // Bifrost has its own Fullscreen item there. So stop the macOS item before the menu is set.
  // registerDefaults does not save the value. So other Electron apps keep their setting.
  if (process.platform === 'darwin') {
    systemPreferences.registerDefaults({ NSFullScreenMenuItemEverywhere: false })
  }

  // A second start of Bifrost shows the window of this instance.
  app.on('second-instance', () => showWindow())

  // Electron fires this event when it is ready to create windows.
  app.whenReady().then(() => {
    electronApp.setAppUserModelId('com.electron')

    // A change of a menu key in the settings builds the menu again.
    setMenuRebuild(showMenu)

    // Register the IPC handlers before any window loads a page.
    // This also opens the settings store and starts the registry service.
    registerIpc(testHome)

    openWindow()

    // On macOS, a click on the Dock icon opens a window if none is open.
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) openWindow()
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
}

// Only one Bifrost runs at a time. Two instances could both change the settings file.
// A second instance quits at once. It registers no IPC and starts no service.
// A test home value that Bifrost refuses also stops the start. Then a check never uses the real
// home by mistake.
if (badTestHome !== null) {
  console.error(testHomeError(badTestHome))
  app.exit(1)
} else if (app.requestSingleInstanceLock()) {
  startApp()
} else {
  app.quit()
}
