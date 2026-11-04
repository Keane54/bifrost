import { expect, test } from 'vitest'
import {
  checkInstall,
  HOOK_COMMAND,
  HOOK_ROWS,
  planInstall,
  planUninstall,
  STATUSLINE_COMMAND,
} from '../../../src/main/integration/settings-plan'

const USER_HOOK = { hooks: [{ command: 'echo hi', type: 'command' }] }
const MINE = {
  command: 'sh ~/.claude/statusline-command.sh',
  padding: 0,
  refreshInterval: 1,
  type: 'command',
}

// biome-ignore lint/suspicious/noExplicitAny: the tests read nested settings
type Loose = any

function deepFreeze<T>(value: T): T {
  if (value && typeof value === 'object') {
    for (const child of Object.values(value)) deepFreeze(child)
    Object.freeze(value)
  }
  return value
}

test('planInstall on empty settings adds 10 rows and the wrapper', () => {
  const p = planInstall({}, undefined)
  expect(HOOK_ROWS).toHaveLength(10)
  expect(checkInstall(p.next)).toEqual({ missingHooks: [], statusLineInstalled: true })
  expect(p.original).toBeNull()
  expect(p.next.statusLine).toEqual({ command: STATUSLINE_COMMAND, type: 'command' })
  expect(p.changes).toHaveLength(11)
})

test('planInstall keeps the user hooks', () => {
  const p = planInstall({ hooks: { UserPromptSubmit: [USER_HOOK] } }, undefined)
  expect((p.next.hooks as Loose).UserPromptSubmit).toContainEqual(USER_HOOK)
  expect((p.next.hooks as Loose).UserPromptSubmit).toContainEqual({
    hooks: [{ command: HOOK_COMMAND, type: 'command' }],
  })
})

test('planInstall is idempotent', () => {
  const first = planInstall({ statusLine: MINE }, undefined)
  const second = planInstall(first.next, first.original)
  expect(second.next).toEqual(first.next)
  expect(second.changes).toEqual([])
})

test('planInstall saves the user statusLine and keeps refreshInterval and padding', () => {
  const p = planInstall({ statusLine: MINE }, undefined)
  expect(p.original).toEqual(MINE)
  expect(p.next.statusLine).toEqual({
    command: STATUSLINE_COMMAND,
    padding: 0,
    refreshInterval: 1,
    type: 'command',
  })
})

test('planInstall never saves the wrapper as the original', () => {
  const installed = planInstall({ statusLine: MINE }, undefined).next
  expect(planInstall(installed, MINE).original).toEqual(MINE)
  expect(planInstall(installed, undefined).original).toBeNull()
})

test('planInstall saves the new statusLine when it is not the wrapper', () => {
  const NEW = { command: 'sh new.sh', type: 'command' }
  expect(planInstall({ statusLine: NEW }, MINE).original).toEqual(NEW)
})

test.each([
  [{ hooks: 'x' }],
  [{ hooks: [] }],
  [{ hooks: null }],
  [{ hooks: { Stop: {} } }],
  [{ statusLine: 'sh x.sh' }],
  [{ statusLine: { type: 'command' } }],
])('planInstall throws for unexpected types in %j', settings => {
  expect(() => planInstall(settings, undefined)).toThrow(/unexpected/i)
})

test('planUninstall and checkInstall do not throw for unexpected types', () => {
  const bad = { hooks: 'x', statusLine: 'y' }
  expect(planUninstall(bad, null)).toEqual(bad)
  expect(checkInstall(bad).statusLineInstalled).toBe(false)
})

test('planUninstall keeps an empty event array and hooks of the user', () => {
  expect(planUninstall({ hooks: { Stop: [] } }, null)).toEqual({ hooks: { Stop: [] } })
})

test('planInstall does not change its input', () => {
  const input = deepFreeze({
    hooks: { UserPromptSubmit: [USER_HOOK] },
    model: 'x',
    statusLine: { ...MINE },
  })
  const copy = structuredClone(input)
  planInstall(input, undefined)
  expect(input).toEqual(copy)
})

test('planUninstall removes only Bifrost hooks and restores the statusLine', () => {
  const installed = planInstall(
    { hooks: { UserPromptSubmit: [USER_HOOK] }, model: 'x', statusLine: MINE },
    undefined,
  ).next
  expect(planUninstall(installed, MINE)).toEqual({
    hooks: { UserPromptSubmit: [USER_HOOK] },
    model: 'x',
    statusLine: MINE,
  })
})

test('planUninstall removes the hooks key and the statusLine when nothing else was there', () => {
  expect(planUninstall(planInstall({}, undefined).next, null)).toEqual({})
})

test('planUninstall keeps a statusLine that is not the wrapper', () => {
  const s = { ...planInstall({}, undefined).next, statusLine: MINE }
  expect(planUninstall(s, null).statusLine).toEqual(MINE)
})

test('planUninstall removes only the Bifrost hook from a shared entry', () => {
  const shared = {
    hooks: [
      { command: 'echo hi', type: 'command' },
      { command: HOOK_COMMAND, type: 'command' },
    ],
    matcher: '*',
  }
  const out = planUninstall({ hooks: { PostToolUse: [shared] } }, null)
  expect(out).toEqual({
    hooks: { PostToolUse: [{ hooks: [{ command: 'echo hi', type: 'command' }], matcher: '*' }] },
  })
})

test('planUninstall does not change its input', () => {
  const input = deepFreeze(planInstall({ model: 'x', statusLine: MINE }, undefined).next)
  const copy = structuredClone(input)
  planUninstall(input, MINE)
  expect(input).toEqual(copy)
})

test('checkInstall names the missing rows', () => {
  const s = planInstall({}, undefined).next as Loose
  delete s.hooks.Notification
  expect(checkInstall(s).missingHooks).toEqual([
    'Notification:permission_prompt',
    'Notification:idle_prompt',
  ])
})

test('checkInstall does not accept a hook with another matcher', () => {
  const s = {
    hooks: { Stop: [{ hooks: [{ command: HOOK_COMMAND, type: 'command' }], matcher: 'x' }] },
  }
  expect(checkInstall(s).missingHooks).toContain('Stop')
  expect(checkInstall(s).statusLineInstalled).toBe(false)
})

test('planInstall writes plain sentences in changes', () => {
  const p = planInstall({ statusLine: MINE }, undefined)
  expect(p.changes).toContain('Add the hook for Stop.')
  expect(p.changes).toContain('Add the hook for Notification with the matcher idle_prompt.')
  expect(p.changes).toContain('Change the statusLine command to the Bifrost wrapper.')
})
