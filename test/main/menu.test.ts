import type { MenuItemConstructorOptions } from 'electron'
import { afterEach, expect, test, vi } from 'vitest'
import { buildMenuTemplate, modeHandlers } from '../../src/main/menu'
import type { ModeController } from '../../src/main/window/display-mode'
import type { DisplayMode } from '../../src/shared/types'

function build(
  mode: DisplayMode = 'window',
  isDev = false,
  handlers: Partial<Parameters<typeof buildMenuTemplate>[0]> = {},
): MenuItemConstructorOptions[] {
  return buildMenuTemplate({
    isDev,
    mode,
    onClosePanel: () => {},
    onMode: () => {},
    onToggleFullscreen: () => {},
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

test('Fullscreen has Ctrl+Cmd+F and Borderless has no accelerator', () => {
  const items = submenu(build(), 'View')
  expect(items.find(item => item.label === 'Fullscreen')?.accelerator).toBe('Ctrl+Cmd+F')
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
