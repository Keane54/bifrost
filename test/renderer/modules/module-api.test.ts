// The client library that a module frame loads from _bifrost/api.js. The test compiles the
// TypeScript source as the build does, and runs the result in a new V8 context with a fake parent
// window, as the frame gives it.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createContext, runInContext } from 'node:vm'
import { describe, expect, it } from 'vitest'
import { compileModuleApi, MODULE_API_SOURCE } from '../../../scripts/module-api/build'

const SOURCE = await compileModuleApi(
  readFileSync(join(__dirname, '../../..', MODULE_API_SOURCE), 'utf8'),
)

interface Bifrost {
  call(name: string, args?: unknown): Promise<unknown>
  on(event: string, fn: (data: unknown) => void): () => void
}

type Listener = (event: { data: unknown; source: unknown }) => void

function load() {
  const posted: { message: Record<string, unknown>; target: string }[] = []
  const parent = {
    postMessage: (message: Record<string, unknown>, target: string) =>
      posted.push({ message, target }),
  }
  let listener: Listener | null = null
  const context = createContext({
    addEventListener: (type: string, fn: Listener) => {
      if (type === 'message') listener = fn
    },
    console,
    parent,
  })
  runInContext(SOURCE, context)
  const deliver = (data: unknown, source: unknown = parent): void => listener?.({ data, source })
  return { bifrost: (context as { bifrost: Bifrost }).bifrost, context, deliver, posted }
}

describe('api.js', () => {
  it('posts a call to the parent window and resolves with the value of the reply', async () => {
    const t = load()
    const result = t.bifrost.call('storage.get', { key: 'a' })
    expect(t.posted).toHaveLength(1)
    const { message, target } = t.posted[0] ?? { message: {}, target: '' }
    expect(target).toBe('*')
    expect(message).toMatchObject({ args: { key: 'a' }, bifrost: 1, call: 'storage.get' })
    expect(Number.isSafeInteger(message.id)).toBe(true)
    t.deliver({ bifrost: 1, id: message.id, ok: true, value: 42 })
    await expect(result).resolves.toBe(42)
  })

  it('rejects with the refusal code of the reply', async () => {
    const t = load()
    const result = t.bifrost.call('notify', { title: 'x' })
    const id = t.posted[0]?.message.id
    t.deliver({ bifrost: 1, error: 'refused: not allowed for this module', id, ok: false })
    await expect(result).rejects.toThrow('refused: not allowed for this module')
  })

  it('gives each call its own id', () => {
    const t = load()
    void t.bifrost.call('a')
    void t.bifrost.call('b')
    const [one, two] = t.posted.map(p => p.message.id)
    expect(one).not.toBe(two)
  })

  it('ignores a reply from another window, with no bifrost: 1, or with an unknown id', async () => {
    const t = load()
    const result = t.bifrost.call('usage.get')
    const id = t.posted[0]?.message.id
    t.deliver({ bifrost: 1, id, ok: true, value: 'evil' }, {})
    t.deliver({ id, ok: true, value: 'no tag' })
    t.deliver({ bifrost: 1, id: -5, ok: true, value: 'unknown id' })
    t.deliver({ bifrost: 1, id, ok: true, value: 'good' })
    t.deliver({ bifrost: 1, id, ok: true, value: 'second' })
    await expect(result).resolves.toBe('good')
  })

  it('calls each listener of an event and stops after the listener is removed', () => {
    const t = load()
    const got: unknown[] = []
    const off = t.bifrost.on('refresh', data => got.push(data))
    t.bifrost.on('other', () => got.push('wrong'))
    t.deliver({ bifrost: 1, data: { n: 1 }, event: 'refresh' })
    t.deliver({ bifrost: 1, data: 'x', event: 'refresh' }, {})
    off()
    t.deliver({ bifrost: 1, data: { n: 2 }, event: 'refresh' })
    expect(got).toEqual([{ n: 1 }])
  })

  it('keeps calling listeners when one throws', () => {
    const t = load()
    const got: unknown[] = []
    const quiet = { error: () => {} }
    Object.assign(t.context, { console: quiet })
    t.bifrost.on('refresh', () => {
      throw new Error('bad listener')
    })
    t.bifrost.on('refresh', data => got.push(data))
    t.deliver({ bifrost: 1, data: 1, event: 'refresh' })
    expect(got).toEqual([1])
  })

  it('rejects a call whose arguments cannot be posted', async () => {
    const t = load()
    const parent = (t.context as { parent: { postMessage: unknown } }).parent
    parent.postMessage = () => {
      throw new Error('DataCloneError')
    }
    await expect(t.bifrost.call('storage.set', { fn: () => 1 })).rejects.toThrow('DataCloneError')
  })

  it('gives a bifrost object that a module cannot replace', () => {
    const t = load()
    const before = t.bifrost
    runInContext('try { globalThis.bifrost = 1 } catch {}', t.context)
    expect((t.context as { bifrost: unknown }).bifrost).toBe(before)
    expect(Object.isFrozen(before)).toBe(true)
  })
})
