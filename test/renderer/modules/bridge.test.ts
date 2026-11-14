import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  type BridgeDeps,
  connectFrame,
  createBridge,
  type FrameHost,
} from '../../../src/renderer/src/modules/bridge'
import { ModuleFrame, moduleFrameElement } from '../../../src/renderer/src/modules/ModuleFrame'
import {
  MODULE_IN_FLIGHT as BRIDGE_IN_FLIGHT,
  MODULE_MESSAGE_BYTES as BRIDGE_MESSAGE_BYTES,
  MODULE_RATE as BRIDGE_RATE,
} from '../../../src/shared/modules'

interface FakeWindow {
  posted: { message: unknown; target: string }[]
  postMessage(message: unknown, target: string): void
}

function fakeWindow(): FakeWindow {
  const posted: FakeWindow['posted'] = []
  return { posted, postMessage: (message, target) => posted.push({ message, target }) }
}

interface Deferred {
  promise: Promise<unknown>
  resolve(value: unknown): void
  reject(error: unknown): void
}

function deferred(): Deferred {
  let resolve: (value: unknown) => void = () => {}
  let reject: (error: unknown) => void = () => {}
  const promise = new Promise<unknown>((a, b) => {
    resolve = a
    reject = b
  })
  return { promise, reject, resolve }
}

// Wait until each reply that is ready went to the frame.
const settle = () => new Promise(r => setTimeout(r, 0))

function setup(over: Partial<BridgeDeps> = {}) {
  const frame = fakeWindow()
  const calls: { moduleId: string; name: string; args: unknown }[] = []
  let now = 5000
  const deps: BridgeDeps = {
    call: async (moduleId, name, args) => {
      calls.push({ args, moduleId, name })
      return { echo: name }
    },
    frame: () => frame,
    moduleId: 'demo',
    now: () => now,
    ...over,
  }
  return {
    bridge: createBridge(deps),
    calls,
    frame,
    tick: (ms: number) => {
      now += ms
    },
  }
}

function msg(id: number, call: string, args: unknown = null): Record<string, unknown> {
  return { args, bifrost: 1, call, id }
}

describe('the module bridge', () => {
  it('ignores a message from another window', async () => {
    const t = setup()
    const other = fakeWindow()
    t.bridge.receive({ data: msg(1, 'storage.get'), source: other })
    t.bridge.receive({ data: msg(2, 'storage.get'), source: null })
    await settle()
    expect(t.calls).toEqual([])
    expect(other.posted).toEqual([])
    expect(t.frame.posted).toEqual([])
  })

  it('ignores a message with no bifrost: 1 or with a bad id', async () => {
    const t = setup()
    for (const data of [
      { call: 'storage.get', id: 1 },
      { bifrost: 2, call: 'storage.get', id: 1 },
      { bifrost: '1', call: 'storage.get', id: 1 },
      { bifrost: 1, call: 'storage.get', id: '1' },
      { bifrost: 1, call: 'storage.get', id: -1 },
      { bifrost: 1, call: 'storage.get', id: 1.5 },
      { bifrost: 1, call: 'storage.get', id: Number.NaN },
      { bifrost: 1, call: 'storage.get', id: 2 ** 60 },
      'bifrost',
      null,
      [1],
    ]) {
      t.bridge.receive({ data, source: t.frame })
    }
    await settle()
    expect(t.calls).toEqual([])
    expect(t.frame.posted).toEqual([])
  })

  it('ignores all messages before the frame has a window', async () => {
    const t = setup({ frame: () => null })
    t.bridge.receive({ data: msg(1, 'storage.get'), source: null })
    await settle()
    expect(t.calls).toEqual([])
  })

  it('sends a call with its own module id, also when the message names another', async () => {
    const t = setup()
    t.bridge.receive({
      data: { ...msg(1, 'storage.get', { key: 'a' }), module: 'other', moduleId: 'other' },
      source: t.frame,
    })
    await settle()
    expect(t.calls).toEqual([{ args: { key: 'a' }, moduleId: 'demo', name: 'storage.get' }])
  })

  it('replies to the frame with the value', async () => {
    const t = setup()
    t.bridge.receive({ data: msg(7, 'usage.get'), source: t.frame })
    await settle()
    expect(t.frame.posted).toEqual([
      { message: { bifrost: 1, id: 7, ok: true, value: { echo: 'usage.get' } }, target: '*' },
    ])
  })

  it('replies with the refusal code of a failed call', async () => {
    const t = setup({
      call: async () => {
        throw new Error('refused: not allowed for this module')
      },
    })
    t.bridge.receive({ data: msg(3, 'notify'), source: t.frame })
    await settle()
    expect(t.frame.posted[0]?.message).toEqual({
      bifrost: 1,
      error: 'refused: not allowed for this module',
      id: 3,
      ok: false,
    })
  })

  it('replies with a general code for an error that is not a refusal', async () => {
    const t = setup({
      call: async () => {
        throw new Error('An object could not be cloned at /Users/x/secret')
      },
    })
    t.bridge.receive({ data: msg(3, 'notify'), source: t.frame })
    await settle()
    expect(t.frame.posted[0]?.message).toEqual({
      bifrost: 1,
      error: 'refused: module call failed',
      id: 3,
      ok: false,
    })
  })

  it('refuses a call name that is not a short text, and sends nothing', async () => {
    const t = setup()
    t.bridge.receive({ data: { bifrost: 1, id: 1 }, source: t.frame })
    t.bridge.receive({ data: msg(2, ''), source: t.frame })
    t.bridge.receive({ data: { ...msg(3, 'x'), call: 5 }, source: t.frame })
    t.bridge.receive({ data: msg(4, 'x'.repeat(65)), source: t.frame })
    await settle()
    expect(t.calls).toEqual([])
    expect(t.frame.posted.map(p => p.message)).toEqual(
      [1, 2, 3, 4].map(id => ({ bifrost: 1, error: 'refused: bad module input', id, ok: false })),
    )
  })

  it('refuses a message larger than 256 KB, and sends nothing', async () => {
    const t = setup()
    expect(BRIDGE_MESSAGE_BYTES).toBe(256 * 1024)
    const value = 'x'.repeat(BRIDGE_MESSAGE_BYTES)
    t.bridge.receive({ data: msg(1, 'storage.set', { key: 'a', value }), source: t.frame })
    await settle()
    expect(t.calls).toEqual([])
    expect(t.frame.posted[0]?.message).toEqual({
      bifrost: 1,
      error: 'refused: module message too large',
      id: 1,
      ok: false,
    })
  })

  it('refuses arguments that are not JSON, and sends a JSON copy of good arguments', async () => {
    const t = setup()
    const cyclic: Record<string, unknown> = {}
    cyclic.self = cyclic
    t.bridge.receive({ data: msg(1, 'storage.set', { key: 'a', value: 1n }), source: t.frame })
    t.bridge.receive({ data: msg(2, 'storage.set', cyclic), source: t.frame })
    t.bridge.receive({
      data: msg(3, 'storage.set', { at: new Date(0), gone: undefined, key: 'a' }),
      source: t.frame,
    })
    t.bridge.receive({ data: { bifrost: 1, call: 'usage.get', id: 4 }, source: t.frame })
    await settle()
    expect(t.calls).toEqual([
      { args: { at: '1970-01-01T00:00:00.000Z', key: 'a' }, moduleId: 'demo', name: 'storage.set' },
      { args: null, moduleId: 'demo', name: 'usage.get' },
    ])
    expect(t.frame.posted.slice(0, 2).map(p => p.message)).toEqual(
      [1, 2].map(id => ({ bifrost: 1, error: 'refused: bad module input', id, ok: false })),
    )
  })

  it('refuses calls over 100 in one second, before they reach the main process', async () => {
    const t = setup()
    expect(BRIDGE_RATE).toBe(100)
    for (let i = 0; i < BRIDGE_RATE + 1; i++) {
      t.bridge.receive({ data: msg(i, 'usage.get'), source: t.frame })
      await settle()
    }
    expect(t.calls).toHaveLength(BRIDGE_RATE)
    expect(t.frame.posted.at(-1)?.message).toEqual({
      bifrost: 1,
      error: 'refused: too many module calls',
      id: BRIDGE_RATE,
      ok: false,
    })
    t.tick(1000)
    t.bridge.receive({ data: msg(500, 'usage.get'), source: t.frame })
    await settle()
    expect(t.calls).toHaveLength(BRIDGE_RATE + 1)
  })

  it('refuses more than 32 calls in flight', async () => {
    const waits: Deferred[] = []
    const t = setup({
      call: () => {
        const d = deferred()
        waits.push(d)
        return d.promise
      },
    })
    expect(BRIDGE_IN_FLIGHT).toBe(32)
    for (let i = 0; i < BRIDGE_IN_FLIGHT + 1; i++) {
      t.bridge.receive({ data: msg(i, 'usage.get'), source: t.frame })
    }
    await settle()
    expect(waits).toHaveLength(BRIDGE_IN_FLIGHT)
    expect(t.frame.posted.map(p => p.message)).toEqual([
      { bifrost: 1, error: 'refused: too many module calls', id: BRIDGE_IN_FLIGHT, ok: false },
    ])
    waits[0]?.reject(new Error('refused: module off'))
    await settle()
    t.bridge.receive({ data: msg(99, 'usage.get'), source: t.frame })
    await settle()
    expect(waits).toHaveLength(BRIDGE_IN_FLIGHT + 1)
  })

  it('sends an event to the frame', () => {
    const t = setup()
    t.bridge.event('refresh', { n: 1 })
    expect(t.frame.posted).toEqual([
      { message: { bifrost: 1, data: { n: 1 }, event: 'refresh' }, target: '*' },
    ])
  })

  it('sends no reply and no event after close', async () => {
    const wait = deferred()
    const t = setup({ call: () => wait.promise })
    t.bridge.receive({ data: msg(1, 'usage.get'), source: t.frame })
    t.bridge.close()
    wait.resolve('late')
    t.bridge.event('refresh', null)
    t.bridge.receive({ data: msg(2, 'usage.get'), source: t.frame })
    await settle()
    expect(t.frame.posted).toEqual([])
  })
})

describe('ModuleFrame', () => {
  const html = renderToStaticMarkup(
    createElement(ModuleFrame, { entry: 'panels/main.html', moduleId: 'demo', panelId: 'main' }),
  )

  it('renders a frame with only allow-scripts, from the module protocol', () => {
    expect(html).toMatch(/^<iframe /)
    expect(html).toContain('sandbox="allow-scripts"')
    expect(html).toContain('src="bifrost-module://demo/panels/main.html"')
    expect(html).not.toContain('allow-same-origin')
    expect(html).not.toMatch(/\sallow="/)
  })

  it('gives the frame a key from the module, the panel and the entry', () => {
    const props = { entry: 'panels/main.html', moduleId: 'demo', panelId: 'main' }
    const keyOf = (p: typeof props) => moduleFrameElement(p, { current: null }).key
    const key = keyOf(props)
    expect(key).not.toBe(null)
    expect(keyOf({ ...props })).toBe(key)
    for (const other of [
      { ...props, moduleId: 'other' },
      { ...props, panelId: 'side' },
      { ...props, entry: 'panels/other.html' },
      { entry: 'panels/main.html', moduleId: 'demo-main', panelId: 'x' },
    ]) {
      expect(keyOf(other), JSON.stringify(other)).not.toBe(key)
    }
    // Two ids that join to the same text still give two keys.
    expect(keyOf({ ...props, moduleId: 'a-b', panelId: 'c' })).not.toBe(
      keyOf({ ...props, moduleId: 'a', panelId: 'b-c' }),
    )
  })
})

describe('connectFrame', () => {
  type Listener = (e: { source: unknown; data: unknown }) => void
  type EventCb = (moduleId: string, event: string, data: unknown) => void

  function setupHost() {
    const listeners = new Set<Listener>()
    const host: FrameHost = {
      addEventListener: (_type, fn) => listeners.add(fn),
      removeEventListener: (_type, fn) => listeners.delete(fn),
    }
    const eventCbs = new Set<EventCb>()
    const calls: string[] = []
    const modules = {
      call: async (moduleId: string) => {
        calls.push(moduleId)
        return null
      },
      onEvent: (cb: EventCb) => {
        eventCbs.add(cb)
        return () => eventCbs.delete(cb)
      },
    }
    const dispatch = (source: unknown, data: unknown) => {
      for (const fn of [...listeners]) fn({ data, source })
    }
    const emit = (moduleId: string, event: string) => {
      for (const cb of [...eventCbs]) cb(moduleId, event, null)
    }
    return { calls, dispatch, emit, eventCbs, host, listeners, modules }
  }

  it('binds each frame to its own element, so a new frame never acts as the old one', async () => {
    const t = setupHost()
    const a: { contentWindow: FakeWindow | null } = { contentWindow: fakeWindow() }
    const b: { contentWindow: FakeWindow | null } = { contentWindow: fakeWindow() }
    const deps = { host: t.host, modules: t.modules, now: () => 1 }
    const offA = connectFrame(a, 'one', deps)
    const offB = connectFrame(b, 'two', deps)
    t.dispatch(b.contentWindow, msg(1, 'usage.get'))
    t.dispatch(a.contentWindow, msg(2, 'usage.get'))
    await settle()
    expect(t.calls).toEqual(['two', 'one'])
    // The old element leaves the page: its window is gone, and nothing more goes out as 'one'.
    const oldWindow = a.contentWindow
    a.contentWindow = null
    t.dispatch(oldWindow, msg(3, 'usage.get'))
    await settle()
    expect(t.calls).toEqual(['two', 'one'])
    offA()
    offB()
    expect(t.listeners.size).toBe(0)
    expect(t.eventCbs.size).toBe(0)
  })

  it('sends the events of its own module only, until it disconnects', () => {
    const t = setupHost()
    const a = { contentWindow: fakeWindow() }
    const off = connectFrame(a, 'one', { host: t.host, modules: t.modules, now: () => 1 })
    t.emit('two', 'refresh')
    t.emit('one', 'refresh')
    off()
    t.emit('one', 'refresh')
    expect(a.contentWindow.posted.map(p => p.message)).toEqual([
      { bifrost: 1, data: null, event: 'refresh' },
    ])
  })
})
