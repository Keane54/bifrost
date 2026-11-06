import type { MenuItemConstructorOptions } from 'electron'
import { afterEach, expect, test, vi } from 'vitest'
import { buildMenuTemplate, menuKeys, modeHandlers, zoomStep } from '../../src/main/menu'
import type { ModeController } from '../../src/main/window/display-mode'
import { activeBindings, canonicalBinding, effectiveKeys } from '../../src/shared/keys'
import type { DisplayMode } from '../../src/shared/types'

function build(
  mode: DisplayMode = 'window',
  isDev = false,
  handlers: Partial<Parameters<typeof buildMenuTemplate>[0]> = {},
): MenuItemConstructorOptions[] {
  return buildMenuTemplate({
    isDev,
    keys: menuKeys(effectiveKeys({})),
    mode,
    onClosePanel: () => {},
    onMode: () => {},
    onToggleFullscreen: () => {},
    onZoom: () => {},
    ...handlers,
  })
}

function submenu(
  template: MenuItemConstructorOptions[],
  label: string,
): MenuItemConstructorOptions[] {
  const menu = template.find(item => item.label === label)
  return (menu?.submenu ?? []) as MenuItemConstructorOptions[]
}

function clickOf(item: MenuItemConstructorOptions | undefined): () => void {
  if (typeof item?.click !== 'function') throw new Error('the item has no click handler')
  return item.click as () => void
}

function walk(template: MenuItemConstructorOptions[]): MenuItemConstructorOptions[] {
  return template.flatMap(item => [
    item,
    ...(Array.isArray(item.submenu) ? walk(item.submenu as MenuItemConstructorOptions[]) : []),
  ])
}

test('the View menu checks the current mode', () => {
  for (const mode of ['window', 'borderless', 'fullscreen'] as const) {
    const items = submenu(build(mode), 'View').filter(item => item.type === 'radio')
    expect(items.map(item => item.label)).toEqual(['Window', 'Borderless', 'Fullscreen'])
    expect(items.filter(item => item.checked).map(item => item.label)).toEqual([
      { borderless: 'Borderless', fullscreen: 'Fullscreen', window: 'Window' }[mode],
    ])
  }
})

test('the View items call the handlers', () => {
  const onMode = vi.fn()
  const onToggleFullscreen = vi.fn()
  const items = submenu(build('window', false, { onMode, onToggleFullscreen }), 'View')
  const click = (label: string): void => {
    clickOf(items.find(item => item.label === label))()
  }
  click('Window')
  click('Borderless')
  click('Fullscreen')
  expect(onMode.mock.calls).toEqual([['window'], ['borderless']])
  expect(onToggleFullscreen).toHaveBeenCalledOnce()
})

test('Fullscreen has Cmd+Ctrl+F and Borderless has no accelerator', () => {
  const items = submenu(build(), 'View')
  expect(items.find(item => item.label === 'Fullscreen')?.accelerator).toBe('Cmd+Ctrl+F')
  expect(items.find(item => item.label === 'Borderless')?.accelerator).toBeUndefined()
  expect(items.find(item => item.label === 'Window')?.accelerator).toBeUndefined()
})

test('Close Panel has Cmd+W and no item has the close role', () => {
  const onClosePanel = vi.fn()
  const template = build('window', false, { onClosePanel })
  const close = submenu(template, 'Window').find(item => item.label === 'Close Panel')
  expect(close?.accelerator).toBe('Cmd+W')
  clickOf(close)()
  expect(onClosePanel).toHaveBeenCalledOnce()
  for (const item of walk(build('window', true))) {
    expect(item.role).not.toBe('close')
  }
})

test('the menu has the roles that macOS text boxes and the app need', () => {
  const roles = walk(build()).map(item => item.role)
  for (const role of [
    'about',
    'hide',
    'hideOthers',
    'unhide',
    'quit',
    'undo',
    'redo',
    'cut',
    'copy',
    'paste',
    'selectAll',
    'minimize',
    'zoom',
  ]) {
    expect(roles).toContain(role)
  }
})

test('the menu binds none of the shortcuts that macOS keeps', () => {
  const kept = [
    'Cmd+Tab',
    'Cmd+Space',
    'Cmd+M',
    'Cmd+Option+Esc',
    'Cmd+Shift+3',
    'Cmd+Shift+4',
    'Cmd+Shift+5',
    'Cmd+Shift+Q',
    'Cmd+Shift+/',
    'Cmd+Ctrl+Q',
    'Ctrl+Space',
  ]
  const normal = (key: string): string =>
    key
      .split('+')
      .map(part => (part === 'Command' ? 'Cmd' : part === 'Control' ? 'Ctrl' : part))
      .join('+')
  for (const dev of [false, true]) {
    for (const item of walk(build('window', dev))) {
      if (item.accelerator === undefined) continue
      expect(kept).not.toContain(normal(String(item.accelerator)))
    }
  }
})

test('the developer items show only in development', () => {
  const labels = (isDev: boolean): Array<string | undefined> =>
    walk(build('window', isDev)).flatMap(item => [item.label, item.role])
  expect(labels(false)).not.toContain('reload')
  expect(labels(false)).not.toContain('toggleDevTools')
  expect(labels(true)).toContain('reload')
  expect(labels(true)).toContain('toggleDevTools')
})

function itemOf(
  template: MenuItemConstructorOptions[],
  menu: string,
  label: string,
): MenuItemConstructorOptions | undefined {
  return submenu(template, menu).find(item => item.label === label)
}

test('the menu uses the key map for Close Panel and Fullscreen', () => {
  const keys = menuKeys(effectiveKeys({}))
  expect(keys).toEqual({ closePanel: 'Cmd+W', fullscreen: 'Cmd+Ctrl+F' })
  const template = build('window', false, { keys })
  expect(itemOf(template, 'Window', 'Close Panel')?.accelerator).toBe('Cmd+W')
  expect(itemOf(template, 'View', 'Fullscreen')?.accelerator).toBe('Cmd+Ctrl+F')
  // A changed key in the settings gives a changed accelerator.
  const changed = menuKeys(
    effectiveKeys({ 'close-panel:mod': 'Mod+Shift+W', 'toggle-fullscreen:mod': 'Mod+Alt+F' }),
  )
  expect(changed).toEqual({ closePanel: 'Cmd+Shift+W', fullscreen: 'Cmd+Alt+F' })
  const custom = build('window', false, { keys: changed })
  expect(itemOf(custom, 'Window', 'Close Panel')?.accelerator).toBe('Cmd+Shift+W')
  expect(itemOf(custom, 'View', 'Fullscreen')?.accelerator).toBe('Cmd+Alt+F')
})

test('a cleared menu key gives no accelerator', () => {
  const keys = menuKeys(effectiveKeys({ 'close-panel:mod': null, 'toggle-fullscreen:mod': null }))
  expect(keys).toEqual({ closePanel: null, fullscreen: null })
  const template = build('window', false, { keys })
  const close = itemOf(template, 'Window', 'Close Panel')
  const fullscreen = itemOf(template, 'View', 'Fullscreen')
  expect(close).toBeDefined()
  expect(fullscreen).toBeDefined()
  expect(close && 'accelerator' in close).toBe(false)
  expect(fullscreen && 'accelerator' in fullscreen).toBe(false)
})

test('the dev Reload item uses F5', () => {
  const reload = walk(build('window', true)).find(item => item.role === 'reload')
  expect(reload?.accelerator).toBe('F5')
})

test('the View menu has Zoom In, Zoom Out and Actual Size, and they call onZoom', () => {
  const onZoom = vi.fn()
  const template = build('window', false, { onZoom })
  const zoomIn = itemOf(template, 'View', 'Zoom In')
  const zoomOut = itemOf(template, 'View', 'Zoom Out')
  const actual = itemOf(template, 'View', 'Actual Size')
  expect(zoomIn?.accelerator).toBe('Cmd+=')
  expect(zoomOut?.accelerator).toBe('Cmd+-')
  expect(actual).toBeDefined()
  expect(actual && 'accelerator' in actual).toBe(false)
  clickOf(zoomIn)()
  clickOf(zoomOut)()
  clickOf(actual)()
  expect(onZoom.mock.calls).toEqual([['in'], ['out'], ['reset']])
})

test('zoomStep steps the scale by 10 from 80 to 150, and Actual Size gives 100', () => {
  expect(zoomStep(100, 'in')).toBe(110)
  expect(zoomStep(140, 'in')).toBe(150)
  expect(zoomStep(150, 'in')).toBe(150)
  expect(zoomStep(100, 'out')).toBe(90)
  expect(zoomStep(90, 'out')).toBe(80)
  expect(zoomStep(80, 'out')).toBe(80)
  expect(zoomStep(130, 'reset')).toBe(100)
  expect(zoomStep(80, 'reset')).toBe(100)
})

// The accelerators that Electron gives a role item without its own accelerator (macOS).
const ROLE_KEYS: Readonly<Record<string, string>> = {
  copy: 'Cmd+C',
  cut: 'Cmd+X',
  forceReload: 'Shift+Cmd+R',
  hide: 'Cmd+H',
  hideOthers: 'Alt+Cmd+H',
  minimize: 'Cmd+M',
  paste: 'Cmd+V',
  quit: 'Cmd+Q',
  redo: 'Shift+Cmd+Z',
  reload: 'Cmd+R',
  resetZoom: 'Cmd+0',
  selectAll: 'Cmd+A',
  toggleDevTools: 'Alt+Cmd+I',
  togglefullscreen: 'Ctrl+Cmd+F',
  undo: 'Cmd+Z',
  zoomIn: 'Cmd+=',
  zoomOut: 'Cmd+-',
}

test('no menu accelerator equals a renderer key of the default map', () => {
  const renderer = new Set(activeBindings(effectiveKeys({})).map(entry => entry.binding))
  const accelerators = new Set<string>([
    // The role keys of the app menu, the Edit menu and the Window menu.
    'Cmd+H',
    'Alt+Cmd+H',
    'Cmd+Q',
    'Cmd+M',
    'Alt+Cmd+I',
    'Cmd+Z',
    'Shift+Cmd+Z',
    'Cmd+X',
    'Cmd+C',
    'Cmd+V',
    'Cmd+A',
  ])
  for (const dev of [false, true]) {
    for (const item of walk(build('window', dev))) {
      const role = item.role === undefined ? undefined : String(item.role)
      const fallback = role !== undefined && Object.hasOwn(ROLE_KEYS, role) ? ROLE_KEYS[role] : null
      const accelerator = item.accelerator === undefined ? fallback : String(item.accelerator)
      if (accelerator !== null) accelerators.add(accelerator)
    }
  }
  // The Zoom items of the View menu are in the list.
  expect(accelerators).toContain('Cmd+=')
  expect(accelerators).toContain('Cmd+-')
  for (const accelerator of accelerators) {
    const binding = canonicalBinding(accelerator)
    expect(binding, accelerator).not.toBeNull()
    expect(renderer.has(binding ?? ''), accelerator).toBe(false)
  }
})

// A mode controller that records the calls. A change ends when the test resolves it.
function fakeController(): ModeController & {
  set: ReturnType<typeof vi.fn>
  toggleFullscreen: ReturnType<typeof vi.fn>
} {
  return {
    get: () => 'window',
    set: vi.fn(async () => {}),
    sync: () => {},
    toggleFullscreen: vi.fn(async () => {}),
  }
}

afterEach(() => {
  vi.restoreAllMocks()
})

test('a View click calls the controller and builds the menu again after the change', async () => {
  const controller = fakeController()
  let finish = (): void => {}
  controller.set.mockImplementation(() => new Promise<void>(resolve => (finish = resolve)))
  const rebuild = vi.fn()
  const handlers = modeHandlers({ controller: () => controller, rebuild })
  const done = handlers.onMode('borderless')
  expect(controller.set).toHaveBeenCalledWith('borderless')
  // macOS moved the check mark at the click. The menu builds again at once.
  expect(rebuild).toHaveBeenCalledOnce()
  finish()
  await done
  expect(rebuild).toHaveBeenCalledTimes(2)
  await handlers.onToggleFullscreen()
  expect(controller.toggleFullscreen).toHaveBeenCalledOnce()
  expect(rebuild).toHaveBeenCalledTimes(4)
})

test('a View click that does not change the mode also builds the menu again', async () => {
  const controller = fakeController()
  const rebuild = vi.fn()
  await modeHandlers({ controller: () => controller, rebuild }).onMode('window')
  expect(controller.set).toHaveBeenCalledWith('window')
  expect(rebuild).toHaveBeenCalledTimes(2)
})

test('a failed change goes to the console and does not reject', async () => {
  const error = vi.spyOn(console, 'error').mockImplementation(() => {})
  const controller = fakeController()
  controller.set.mockRejectedValue(new Error('Object has been destroyed'))
  controller.toggleFullscreen.mockRejectedValue(new Error('Object has been destroyed'))
  const rebuild = vi.fn()
  const handlers = modeHandlers({ controller: () => controller, rebuild })
  await expect(handlers.onMode('borderless')).resolves.toBeUndefined()
  await expect(handlers.onToggleFullscreen()).resolves.toBeUndefined()
  expect(error).toHaveBeenCalledTimes(2)
  expect(rebuild).toHaveBeenCalledTimes(4)
})

test('with no window, a View click calls no controller and only builds the menu again', async () => {
  const old = fakeController()
  let current: ModeController | null = old
  const rebuild = vi.fn()
  const handlers = modeHandlers({ controller: () => current, rebuild })
  // The window closes. Then the handlers must not use its controller.
  current = null
  await handlers.onMode('borderless')
  await handlers.onToggleFullscreen()
  expect(old.set).not.toHaveBeenCalled()
  expect(old.toggleFullscreen).not.toHaveBeenCalled()
  expect(rebuild).toHaveBeenCalledTimes(2)
  // A new window gives a new controller. The handlers use it.
  const next = fakeController()
  current = next
  await handlers.onMode('borderless')
  expect(next.set).toHaveBeenCalledWith('borderless')
})

test('the menu keeps its accelerators registered when no key is recording', () => {
  const items = walk(build('window', true)).filter(item => item.type !== 'separator')
  expect(items.some(item => item.registerAccelerator !== undefined)).toBe(false)
})

test('the menu gives its keys to the page while a key records', () => {
  const template = build('window', true, { recording: true })
  const keyed = walk(template).filter(item => item.accelerator !== undefined || item.role)
  // Cmd+W, Cmd+Ctrl+F, Cmd+=, Cmd+-, F5 and the role items.
  expect(keyed.length).toBeGreaterThan(10)
  for (const item of keyed)
    expect(item.registerAccelerator, String(item.label ?? item.role)).toBe(false)
  // The menu still shows the keys.
  const close = submenu(template, 'Window').find(item => item.label === 'Close Panel')
  expect(close?.accelerator).toBe('Cmd+W')
  const view = submenu(template, 'View')
  expect(view.find(item => item.label === 'Zoom In')?.accelerator).toBe('Cmd+=')
  expect(view.find(item => item.label === 'Zoom Out')?.accelerator).toBe('Cmd+-')
  expect(view.find(item => item.label === 'Fullscreen')?.registerAccelerator).toBe(false)
  // An item without a key stays as it was.
  expect(view.find(item => item.label === 'Actual Size')?.registerAccelerator).toBeUndefined()
})
