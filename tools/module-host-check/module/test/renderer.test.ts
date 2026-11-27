// Tests the module's React renderer against a stand-in for the host: __bifrostSend records each
// batch as the host would get it, and events go in through __bifrostOnEvent the way the host calls
// it. The elements come from createElement rather than JSX, so Node runs this file as it is:
// node --test test/
import assert from 'node:assert/strict'
import { test } from 'node:test'

import React from 'react'

import { render } from '../src/renderer.ts'
import type { Op } from '../src/renderer.ts'

const h = React.createElement

const host = globalThis as typeof globalThis & {
  __bifrostSend?: (ops: Op[]) => void
  __bifrostOnEvent?: (handler: number, value: unknown) => void
}

// Starts a fresh record of batches. Each one goes through JSON, as it does in the host, so a value
// that JSON can't carry shows up here too.
function record(): Op[][] {
  const batches: Op[][] = []
  host.__bifrostSend = ops => {
    batches.push(JSON.parse(JSON.stringify(ops)))
  }
  return batches
}

// Lets any timer or microtask that React queued run, so a late batch would show up.
const settle = () => new Promise(resolve => setTimeout(resolve, 20))

function send(handler: number, value: unknown = null) {
  assert.equal(typeof host.__bifrostOnEvent, 'function', 'the renderer sets __bifrostOnEvent')
  host.__bifrostOnEvent!(handler, value)
}

// The handler number that a batch gave to a function prop of the first node of a type.
function handlerOf(batch: Op[], type: string, prop: string): number {
  const op = batch.find(op => op[0] === 'create' && op[2] === type)
  assert.ok(op?.[0] === 'create', `no ${type} in the batch`)
  const value = op[3][prop] as { $fn?: unknown }
  assert.equal(typeof value?.$fn, 'number', `${type}.${prop} isn't sent as a handler`)
  return value.$fn as number
}

type Shown = string | { type: string; props: Record<string, unknown>; children: Shown[] }

// Plays the ops into a tree the way the host would and returns the root's children, with each
// text node as its string. An op that names a node the host doesn't have fails the test.
function replay(batches: Op[][]): Shown[] {
  type Held = { type: string | null; props: Record<string, unknown>; text: string; ids: number[] }
  const nodes = new Map<number, Held>([[0, { type: 'root', props: {}, text: '', ids: [] }]])
  const node = (id: number) => {
    const found = nodes.get(id)
    assert.ok(found, `node ${id} wasn't created`)
    return found
  }
  const detach = (parent: number, id: number) => {
    const ids = node(parent).ids
    if (ids.includes(id)) ids.splice(ids.indexOf(id), 1)
  }
  const create = (id: number, held: Held) => {
    assert.ok(!nodes.has(id), `node ${id} was created twice`)
    nodes.set(id, held)
  }
  for (const op of batches.flat()) {
    switch (op[0]) {
      case 'create':
        create(op[1], { type: op[2], props: { ...op[3] }, text: '', ids: [] })
        break
      case 'text':
        create(op[1], { type: null, props: {}, text: op[2], ids: [] })
        break
      case 'append':
        node(op[2])
        detach(op[1], op[2])
        node(op[1]).ids.push(op[2])
        break
      case 'insert': {
        node(op[2])
        detach(op[1], op[2])
        const ids = node(op[1]).ids
        assert.ok(ids.includes(op[3]), `node ${op[3]} isn't a child of ${op[1]}`)
        ids.splice(ids.indexOf(op[3]), 0, op[2])
        break
      }
      case 'remove':
        assert.ok(node(op[1]).ids.includes(op[2]), `node ${op[2]} isn't a child of ${op[1]}`)
        detach(op[1], op[2])
        break
      case 'update':
        for (const [key, value] of Object.entries(op[2])) {
          if (value === null) delete node(op[1]).props[key]
          else node(op[1]).props[key] = value
        }
        break
      case 'setText':
        node(op[1]).text = op[2]
        break
      default:
        assert.fail(`unknown op ${JSON.stringify(op)}`)
    }
  }
  const show = (id: number): Shown => {
    const held = node(id)
    if (held.type === null) return held.text
    return { type: held.type, props: held.props, children: held.ids.map(show) }
  }
  return node(0).ids.map(show)
}

test('theFirstCommitIsOneBatch', async () => {
  const batches = record()
  render(h('Stack', { gap: 8 }, h('Text', null, 'First'), h('Text', null, 'Second')))
  await settle()

  assert.equal(batches.length, 1)
  const created = batches[0].flatMap(op => (op[0] === 'create' ? [op[2]] : []))
  assert.deepEqual(created.sort(), ['Stack', 'Text', 'Text'])
  assert.deepEqual(replay(batches), [
    {
      type: 'Stack',
      props: { gap: 8 },
      children: [
        { type: 'Text', props: {}, children: ['First'] },
        { type: 'Text', props: {}, children: ['Second'] },
      ],
    },
  ])
})

function Likes() {
  const [likes, setLikes] = React.useState(0)
  return h('Button', { label: 'Like', onPress: () => setLikes(n => n + 1) }, 'Liked ', likes)
}

test('aClickSendsOneSetText', async () => {
  const batches = record()
  render(h(Likes))
  await settle()
  const count = batches[0].find(op => op[0] === 'text' && op[2] === '0')
  assert.ok(count, 'the count is its own text node')

  send(handlerOf(batches[0], 'Button', 'onPress'))
  await settle()

  assert.deepEqual(batches.slice(1), [[['setText', count[1], '1']]])
})

test('aNewClosureSendsNothing', async () => {
  const batches = record()
  const seen: number[] = []
  let renders = 0
  // Every render hands the button a new closure, and nothing else about it changes.
  function Presses() {
    const [presses, setPresses] = React.useState(0)
    renders += 1
    const onPress = () => {
      seen.push(presses)
      setPresses(presses + 1)
    }
    return h('Button', { label: 'Press', onPress }, 'Press')
  }
  render(h(Presses))
  await settle()
  const handler = handlerOf(batches[0], 'Button', 'onPress')

  send(handler)
  send(handler)
  await settle()

  assert.equal(renders, 3)
  // The second press ran the second render's closure, under the same handler number.
  assert.deepEqual(seen, [0, 1])
  assert.equal(batches.length, 1)
})

test('laterCommitsKeepTheTreeInStep', async () => {
  const batches = record()
  function Shelf() {
    const [items, setItems] = React.useState(['a', 'b'])
    return h(
      'Stack',
      null,
      h('Button', { label: 'Change', onPress: (next: string[]) => setItems(next) }),
      items.map(item => h('Text', { key: item }, item)),
    )
  }
  render(h(Shelf))
  await settle()
  const handler = handlerOf(batches[0], 'Button', 'onPress')
  const shelf = (items: string[]) => [
    {
      type: 'Stack',
      props: {},
      children: [
        { type: 'Button', props: { label: 'Change', onPress: { $fn: handler } }, children: [] },
        ...items.map(item => ({ type: 'Text', props: {}, children: [item] })),
      ],
    },
  ]
  assert.deepEqual(replay(batches), shelf(['a', 'b']))

  // A new node goes in before an old one and another comes out, then an old one moves and a new
  // one goes on the end.
  for (const items of [['c', 'a'], ['a', 'c', 'd']]) {
    const sent = batches.length
    send(handler, items)
    await settle()
    assert.equal(batches.length, sent + 1, 'each change is one batch')
    assert.deepEqual(replay(batches), shelf(items))
  }
})
