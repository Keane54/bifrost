// Module panels in the window system (plan Task 6). A module panel has the ID
// module:<module id>:<panel id>. Its title and icon come from the manifest. A panel of a module
// that is off or gone shows a friendly notice (Review Focus 3).
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import {
  MODULE_OFF_NOTICE,
  ModulePanelTitle,
  ModulePanelView,
} from '../../../src/renderer/src/modules/ModulePanel'
import { MODULE_ICON_COMPONENTS } from '../../../src/renderer/src/modules/module-icons'
import { modulePanelOf, moduleSideButtons } from '../../../src/renderer/src/modules/module-panels'
import { createModulesStore, EMPTY_MODULES } from '../../../src/renderer/src/modules/use-modules'
import { PanelContent, panelScrolls, panelTitle } from '../../../src/renderer/src/panels/panels'
import { parseUiStore } from '../../../src/renderer/src/wm/layout'
import { PANEL_ICONS } from '../../../src/renderer/src/wm/panel-icons'
import { ModuleButtons } from '../../../src/renderer/src/wm/SideBar'
import {
  DEFAULT_SIZES,
  initialState,
  panelKind,
  wmReducer,
} from '../../../src/renderer/src/wm/state'
import { MODULE_ICONS, MODULE_ID_PATTERN } from '../../../src/shared/module-manifest'
import type { ModuleRow, ModulesSnapshot } from '../../../src/shared/modules'
import { MODULE_PANEL, modulePanelId } from '../../../src/shared/view-id'

function row(over: Partial<ModuleRow> = {}): ModuleRow {
  return {
    dailyCap: 50,
    description: 'Says hello.',
    dev: false,
    enabled: true,
    granted: [],
    id: 'hello',
    jobsToday: 0,
    model: 'sonnet',
    name: 'Hello',
    offReason: null,
    panels: [
      { entry: 'panels/main.html', icon: 'star', id: 'main', title: 'Hello board' },
      { entry: 'panels/log.html', icon: 'clock', id: 'log', title: 'Hello log' },
    ],
    pendingUpdate: null,
    requested: [],
    source: '~/Developer/hello',
    sourceKind: 'folder',
    tier: 'standard',
    version: '1.0.0',
    waitingJobs: 0,
    ...over,
  }
}

const MAIN = 'module:hello:main'

function view(panelId: string, modules: ModuleRow[], loaded = true): string {
  return renderToStaticMarkup(createElement(ModulePanelView, { loaded, modules, panelId }))
}

describe('module panel ids', () => {
  it('builds and matches the ID of a module panel', () => {
    expect(modulePanelId('hello', 'main')).toBe(MAIN)
    expect(MODULE_PANEL.exec(MAIN)?.slice(1)).toEqual(['hello', 'main'])
    expect(modulePanelId('my-tool2', 'p')).toBe('module:my-tool2:p')
  })

  it('accepts the same module ids as the manifest', () => {
    for (const id of [
      'ab',
      'a-b',
      'a1',
      'hello',
      'h',
      'Hello',
      '1ab',
      'a_b',
      `a${'b'.repeat(40)}`,
    ]) {
      expect(MODULE_PANEL.test(modulePanelId(id, 'main')), id).toBe(MODULE_ID_PATTERN.test(id))
    }
  })

  it('panelKind gives module for a module panel', () => {
    expect(panelKind(MAIN)).toBe('module')
    expect(panelKind('module:my-tool2:p')).toBe('module')
    expect(panelKind(`module:a${'b'.repeat(39)}:${'c'.repeat(30)}`)).toBe('module')
  })

  it('panelKind gives null for a bad module panel ID', () => {
    for (const bad of [
      'module',
      'module:',
      'module:hello',
      'module:hello:',
      'module::main',
      'module:h:main',
      'module:Hello:main',
      'module:hello:Main',
      'module:1hello:main',
      'module:hello:1main',
      'module:hello:main:x',
      'module:hello:ma in',
      'module:hello.x:main',
      `module:a${'b'.repeat(40)}:main`,
      `module:hello:${'c'.repeat(31)}`,
      ' module:hello:main',
      'module:hello:main\n',
    ]) {
      expect(panelKind(bad), bad).toBeNull()
    }
  })

  it('panelKind gives heimdall for the Heimdall panel', () => {
    expect(panelKind('heimdall')).toBe('heimdall')
    expect(panelKind('heimdall:1')).toBeNull()
  })

  it('has a size and an icon for module and heimdall', () => {
    expect(DEFAULT_SIZES.module).toBeDefined()
    expect(DEFAULT_SIZES.heimdall).toBeDefined()
    expect(PANEL_ICONS.module).toBeDefined()
    expect(PANEL_ICONS.heimdall).toBeDefined()
  })

  it('opens a module panel in a frame of the default module size', () => {
    const state = wmReducer(initialState({ h: 2000, w: 2000 }), { panelId: MAIN, type: 'open' })
    expect(state.frames).toHaveLength(1)
    expect(state.frames[0]?.panels).toEqual([MAIN])
    expect(state.frames[0]?.rect.w).toBe(DEFAULT_SIZES.module.w)
    expect(state.frames[0]?.rect.h).toBe(DEFAULT_SIZES.module.h)
    const bad = wmReducer(initialState({ h: 2000, w: 2000 }), {
      panelId: 'module:Bad:main',
      type: 'open',
    })
    expect(bad.frames).toHaveLength(0)
  })
})

describe('a saved layout with module panels', () => {
  const rect = { h: 300, w: 400, x: 10, y: 20 }
  const store = parseUiStore({
    current: {
      frames: [
        {
          active: MAIN,
          locked: false,
          minimised: false,
          panels: [MAIN, 'module:Bad:main', 'module:gone:main', 'settings'],
          rect,
        },
        { active: 'module:Bad:x', panels: ['module:Bad:x'], rect },
      ],
      memory: { 'module:Bad:main': rect, 'module:hello:log': rect },
    },
    layouts: [],
    version: 1,
  })

  it('keeps each good module panel and drops a bad ID', () => {
    expect(store.current?.frames).toHaveLength(1)
    expect(store.current?.frames[0]?.panels).toEqual([MAIN, 'module:gone:main', 'settings'])
    expect(store.current?.frames[0]?.active).toBe(MAIN)
    expect(Object.keys(store.current?.memory ?? {})).toEqual(['module:hello:log'])
  })

  it('loads the module panels into the window manager', () => {
    const frames = store.current?.frames ?? []
    const state = wmReducer(initialState({ h: 900, w: 1200 }), {
      frames,
      memory: {},
      type: 'load',
    })
    expect(state.frames[0]?.panels).toEqual([MAIN, 'module:gone:main', 'settings'])
  })

  it('shows the notice for a module that is gone, and nothing crashes', () => {
    const html = view('module:gone:main', [row()])
    expect(html).toContain(MODULE_OFF_NOTICE)
    expect(html).not.toContain('<iframe')
  })
})

describe('the content of a module panel', () => {
  it('has the friendly text', () => {
    expect(MODULE_OFF_NOTICE).toBe('This module is off or no longer installed.')
  })

  it('shows the sandboxed frame of an enabled module', () => {
    const html = view(MAIN, [row()])
    expect(html).toMatch(/^<iframe /)
    expect(html).toContain('sandbox="allow-scripts"')
    expect(html).toContain('src="bifrost-module://hello/panels/main.html"')
    expect(html).toContain('data-module-panel="main"')
    expect(html).not.toContain(MODULE_OFF_NOTICE)
  })

  it('shows the entry of the right panel', () => {
    expect(view('module:hello:log', [row()])).toContain(
      'src="bifrost-module://hello/panels/log.html"',
    )
  })

  it('shows the notice for a module that is turned off', () => {
    const html = view(MAIN, [row({ enabled: false })])
    expect(html).toContain(MODULE_OFF_NOTICE)
    expect(html).not.toContain('<iframe')
  })

  it('shows the notice for a dev module in a packaged app', () => {
    const html = view(MAIN, [
      row({
        dev: true,
        enabled: false,
        offReason: 'This developer module runs only in a development build of Bifrost.',
        sourceKind: 'dev',
      }),
    ])
    expect(html).toContain(MODULE_OFF_NOTICE)
    expect(html).not.toContain('<iframe')
  })

  it('shows the notice for a panel that the manifest no longer has', () => {
    const html = view('module:hello:old', [row()])
    expect(html).toContain(MODULE_OFF_NOTICE)
    expect(html).not.toContain('<iframe')
  })

  it('shows the notice for a panel ID that is not a module panel', () => {
    expect(view('settings', [row()])).toContain(MODULE_OFF_NOTICE)
  })

  it('shows nothing before the first snapshot', () => {
    const html = view(MAIN, [], false)
    expect(html).not.toContain(MODULE_OFF_NOTICE)
    expect(html).not.toContain('<iframe')
  })

  it('does not scroll the frame area of a module panel', () => {
    expect(panelScrolls(MAIN)).toBe(false)
  })

  it('shows a placeholder in the Heimdall panel', () => {
    const html = renderToStaticMarkup(createElement(PanelContent, { panelId: 'heimdall' }))
    expect(html).not.toContain('This panel is not known.')
    expect(html).toContain('Heimdall has nothing for you right now.')
  })
})

describe('the title of a module panel', () => {
  const title = (panelId: string, modules: ModuleRow[]): string =>
    renderToStaticMarkup(createElement(ModulePanelTitle, { modules, panelId }))

  it('comes from the manifest, with the module name', () => {
    expect(panelTitle(MAIN, undefined, [row()])).toBe('Hello board (Hello)')
    expect(panelTitle('module:hello:log', undefined, [row()])).toBe('Hello log (Hello)')
  })

  it('stays the manifest title while the module is off', () => {
    expect(panelTitle(MAIN, undefined, [row({ enabled: false })])).toBe('Hello board (Hello)')
  })

  it('shows the module name dim after the panel title in the title bar', () => {
    const html = title(MAIN, [row()])
    expect(html).toBe(
      'Hello board<span class="text-text-dim" data-module-name="true"> · Hello</span>',
    )
  })

  it('shows the module name of a panel that copies a Bifrost title', () => {
    const spoof = row({
      id: 'spoof',
      name: 'Spoof',
      panels: [{ entry: 'panels/a.html', icon: 'star', id: 'a', title: 'Settings' }],
    })
    expect(panelTitle('module:spoof:a', undefined, [spoof])).toBe('Settings (Spoof)')
    expect(title('module:spoof:a', [spoof])).toContain(' · Spoof</span>')
  })

  it('shows Module with no module name for a module that is gone', () => {
    expect(title('module:gone:main', [row()])).toBe('Module')
  })

  it('shows a module name as text, never as HTML', () => {
    const html = title(MAIN, [row({ name: '<b>Bold</b>' })])
    expect(html).toContain('&lt;b&gt;Bold&lt;/b&gt;')
    expect(html).not.toContain('<b>')
  })

  it('is Module for a module that is gone', () => {
    expect(panelTitle('module:gone:main', undefined, [row()])).toBe('Module')
    expect(panelTitle(MAIN)).toBe('Module')
  })

  it('is Heimdall for the Heimdall panel', () => {
    expect(panelTitle('heimdall')).toBe('Heimdall')
  })

  it('finds the row and the panel of a module panel', () => {
    const found = modulePanelOf([row({ id: 'other' }), row()], 'module:hello:log')
    expect(found?.row.id).toBe('hello')
    expect(found?.panel.entry).toBe('panels/log.html')
    expect(modulePanelOf([row()], 'module:hello:none')).toBeNull()
    expect(modulePanelOf([row()], 'settings')).toBeNull()
  })
})

describe('the module buttons of the side bar', () => {
  const modules = [
    row(),
    row({
      enabled: false,
      id: 'off',
      name: 'Off',
      panels: [{ entry: 'panels/a.html', icon: 'bell', id: 'a', title: 'Off panel' }],
    }),
    row({
      dev: true,
      enabled: false,
      id: 'devmod',
      offReason: 'This developer module runs only in a development build of Bifrost.',
      panels: [{ entry: 'panels/a.html', icon: 'bot', id: 'a', title: 'Dev panel' }],
      sourceKind: 'dev',
    }),
    row({
      id: 'timer',
      name: 'Timer',
      panels: [{ entry: 'panels/t.html', icon: 'timer', id: 't', title: 'Countdown' }],
    }),
  ]

  it('gives one button for each panel of each enabled module', () => {
    expect(moduleSideButtons(modules)).toEqual([
      { icon: 'star', label: 'Hello board (Hello)', panelId: MAIN },
      { icon: 'clock', label: 'Hello log (Hello)', panelId: 'module:hello:log' },
      { icon: 'timer', label: 'Countdown (Timer)', panelId: 'module:timer:t' },
    ])
  })

  it('renders each button with the module name, and none for a module that is off', () => {
    const open = vi.fn()
    const html = renderToStaticMarkup(createElement(ModuleButtons, { modules, open }))
    expect(html.match(/<button /g)).toHaveLength(3)
    expect(html).toContain('aria-label="Hello board (Hello)"')
    expect(html).toContain('aria-label="Hello log (Hello)"')
    expect(html).toContain('aria-label="Countdown (Timer)"')
    expect(html).not.toContain('Off panel')
    expect(html).not.toContain('Dev panel')
  })

  it('gives two modules with the same panel title different labels', () => {
    const board = (id: string, name: string) =>
      row({ id, name, panels: [{ entry: 'panels/b.html', icon: 'star', id: 'b', title: 'Board' }] })
    const labels = moduleSideButtons([board('one', 'One'), board('two', 'Two')]).map(b => b.label)
    expect(labels).toEqual(['Board (One)', 'Board (Two)'])
  })

  it('gives a panel that copies a Bifrost title the module name', () => {
    const spoof = row({
      id: 'spoof',
      name: 'Spoof',
      panels: [{ entry: 'panels/a.html', icon: 'star', id: 'a', title: 'Answer Claude' }],
    })
    const html = renderToStaticMarkup(
      createElement(ModuleButtons, { modules: [spoof], open: vi.fn() }),
    )
    expect(html).toContain('aria-label="Answer Claude (Spoof)"')
    expect(html).not.toContain('aria-label="Answer Claude"')
  })

  it('renders the icon of the manifest', () => {
    const one = [row({ panels: [row().panels[0] as ModuleRow['panels'][0]] })]
    const html = renderToStaticMarkup(createElement(ModuleButtons, { modules: one, open: vi.fn() }))
    expect(html).toContain('lucide-star')
  })

  it('renders nothing with no enabled module', () => {
    const html = renderToStaticMarkup(
      createElement(ModuleButtons, { modules: [row({ enabled: false })], open: vi.fn() }),
    )
    expect(html).toBe('')
  })

  it('maps each module icon name to a lucide icon', () => {
    expect(Object.keys(MODULE_ICON_COMPONENTS).sort()).toEqual([...MODULE_ICONS].sort())
    for (const name of MODULE_ICONS) expect(MODULE_ICON_COMPONENTS[name]).toBeDefined()
  })

  it('the side bar uses the module buttons and the module icon of a minimised frame', () => {
    const text = readFileSync(
      join(__dirname, '../../../src/renderer/src/wm/SideBar.tsx'),
      'utf8',
    ).replace(/\s+/g, ' ')
    expect(text).toContain('<ModuleButtons modules={modules} open={open} />')
    expect(text).toContain('panelTitle(frame.active, rows, modules)')
    expect(text).toContain('MODULE_ICON_COMPONENTS[found.panel.icon]')
  })
})

describe('createModulesStore', () => {
  const ONE: ModulesSnapshot = { modules: [row()] }
  const TWO: ModulesSnapshot = { modules: [row(), row({ id: 'two' })] }

  function fakeApi() {
    let push: ((s: ModulesSnapshot) => void) | null = null
    let answer: ((s: ModulesSnapshot) => void) | null = null
    const off = vi.fn()
    const api = {
      onUpdate: vi.fn((cb: (s: ModulesSnapshot) => void) => {
        push = cb
        return off
      }),
      snapshot: vi.fn(
        () =>
          new Promise<ModulesSnapshot>(resolve => {
            answer = resolve
          }),
      ),
    }
    return {
      answer: (s: ModulesSnapshot) => answer?.(s),
      api,
      off,
      push: (s: ModulesSnapshot) => push?.(s),
    }
  }

  it('starts empty and does not subscribe before a listener', () => {
    const fake = fakeApi()
    const store = createModulesStore(fake.api)
    expect(store.get()).toBe(EMPTY_MODULES)
    expect(store.loaded()).toBe(false)
    expect(fake.api.onUpdate).not.toHaveBeenCalled()
  })

  it('subscribes once, loads the snapshot and takes each push', async () => {
    const fake = fakeApi()
    const store = createModulesStore(fake.api)
    const a = vi.fn()
    const stopA = store.subscribe(a)
    const stopB = store.subscribe(vi.fn())
    expect(fake.api.onUpdate).toHaveBeenCalledTimes(1)
    fake.answer(ONE)
    await Promise.resolve()
    expect(store.get()).toBe(ONE)
    expect(store.loaded()).toBe(true)
    fake.push(TWO)
    expect(store.get()).toBe(TWO)
    expect(a).toHaveBeenCalledTimes(2)
    stopA()
    expect(fake.off).not.toHaveBeenCalled()
    stopB()
    expect(fake.off).toHaveBeenCalledTimes(1)
  })

  it('keeps a push that comes before the first answer', async () => {
    const fake = fakeApi()
    const store = createModulesStore(fake.api)
    store.subscribe(vi.fn())
    fake.push(TWO)
    fake.answer(ONE)
    await Promise.resolve()
    expect(store.get()).toBe(TWO)
  })
})
