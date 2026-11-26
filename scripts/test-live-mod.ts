// Tests the prompt lines of the Live details mod (App/Bifrost/Resources/live-mod/hooks/register.ts)
// against a fake engine, so it needs no Claude Code and opens no socket. Node 24 or later runs it
// as it is, as Node strips the types: node --test scripts/test-live-mod.ts
//
// The origin kinds are the ones Claude Code 2.1.332 hands a prompt.submit hook, and the person
// ones are the list its own sec-default mod uses to decide that a person prompted.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { register } from '../App/Bifrost/Resources/live-mod/hooks/register.ts'

type Hook = ($: unknown, e: unknown, next: (e: unknown) => unknown) => unknown

const hooks = new Map<string, Hook>()
register(((event: string, hook: Hook) => {
  hooks.set(event, hook)
  return { catch: () => undefined }
}) as never)

// Every line the mod sent, parsed back from the body of its POST.
const sent: Record<string, unknown>[] = []
const engine = {
  env: { get: async () => '/nonexistent-bifrost-test-home' },
  session: { id: async () => '00000000-0000-4000-8000-000000000001' },
  http: {
    fetch: async (_url: string, init: { body: string }) => {
      sent.push(JSON.parse(init.body))
    },
  },
}

const TEXT = 'words the person typed'

// Run one prompt through the mod's prompt.submit hook and return the prompt lines it sent. The
// hook must hand the event on unchanged, and no line may carry the prompt's text.
async function submit(fields: Record<string, unknown>) {
  sent.length = 0
  const event = { text: TEXT, wait: false, ...fields }
  const passedOn = Symbol('next')
  const result = await hooks.get('prompt.submit')!(engine, event, e => {
    assert.equal(e, event)
    return passedOn
  })
  assert.equal(result, passedOn)
  // The send never blocks the hook, so let it finish before reading what went out.
  await new Promise(resolve => setImmediate(resolve))
  assert.ok(!JSON.stringify(sent).includes(TEXT), 'a line carried the text of the prompt')
  return sent.filter(line => line.kind === 'prompt')
}

// The person flags of the prompt lines for each origin kind.
async function flags(kinds: string[], fields: Record<string, unknown> = {}) {
  const found: Record<string, unknown[]> = {}
  for (const kind of kinds) {
    found[kind] = (await submit({ origin: { kind }, ...fields })).map(line => line.person)
  }
  return found
}

const each = (kinds: string[], value: unknown[]) =>
  Object.fromEntries(kinds.map(kind => [kind, value]))

const PERSON = ['composer', 'bridge', 'sdk', 'slack-ping', 'human']

test('a prompt that a person starts sends person true', async () => {
  assert.deepEqual(await flags(PERSON), each(PERSON, [true]))
  assert.deepEqual(await flags(PERSON, { isMeta: false }), each(PERSON, [true]))
})

test('a prompt that the machine starts sends person false', async () => {
  const machine = [
    'auto-continuation',
    'unclassified',
    'task-notification',
    'scheduled-trigger',
    'peer',
    'peer-send-message',
    'projects-relay',
    'channel',
    'coordinator',
    'observer',
    'observer-activity',
    'plugin',
    'a-kind-from-a-later-claude-code',
  ]
  assert.deepEqual(await flags(machine), each(machine, [false]))
  // A plugin can say asUser from any hook, a timer included, so it doesn't prove a person.
  const plugin = await submit({ origin: { kind: 'plugin', name: 'some-mod', asUser: true } })
  assert.deepEqual(plugin.map(line => line.person), [false])
})

test('a hidden prompt never counts, even from the composer', async () => {
  assert.deepEqual(await flags(PERSON, { isMeta: true }), each(PERSON, [false]))
})

test('a prompt with no origin sends no line', async () => {
  for (const fields of [{}, { origin: undefined }, { origin: {} }, { origin: { kind: 7 } }]) {
    assert.deepEqual(await submit(fields), [], JSON.stringify(fields))
  }
})
