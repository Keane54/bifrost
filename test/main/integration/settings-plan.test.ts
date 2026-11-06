import { expect, test } from 'vitest'
import {
  checkInstall,
  HOOK_COMMAND,
  HOOK_ROWS,
  planUninstall,
} from '../../../src/main/integration/settings-plan'
import { oldInstalled } from '../../helpers/old-install'

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

test('checkInstall finds all 10 rows and the wrapper of an old install', () => {
  expect(HOOK_ROWS).toHaveLength(10)
  expect(checkInstall(oldInstalled())).toEqual({ missingHooks: [], statusLineInstalled: true })
})

test('planUninstall and checkInstall do not throw for unexpected types', () => {
  const bad = { hooks: 'x', statusLine: 'y' }
  expect(planUninstall(bad, null)).toEqual(bad)
  expect(checkInstall(bad).statusLineInstalled).toBe(false)
})

test('planUninstall keeps an empty event array and hooks of the user', () => {
  expect(planUninstall({ hooks: { Stop: [] } }, null)).toEqual({ hooks: { Stop: [] } })
})

test('planUninstall removes only Bifrost hooks and restores the statusLine', () => {
  const installed = oldInstalled({
    hooks: { UserPromptSubmit: [USER_HOOK] },
    model: 'x',
    statusLine: MINE,
  })
  expect(planUninstall(installed, MINE)).toEqual({
    hooks: { UserPromptSubmit: [USER_HOOK] },
    model: 'x',
    statusLine: MINE,
  })
})

test('planUninstall removes the hooks key and the statusLine when nothing else was there', () => {
  expect(planUninstall(oldInstalled(), null)).toEqual({})
})

test('planUninstall keeps a statusLine that is not the wrapper', () => {
  const s = { ...oldInstalled(), statusLine: MINE }
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
  const input = deepFreeze(oldInstalled({ model: 'x', statusLine: MINE }))
  const copy = structuredClone(input)
  planUninstall(input, MINE)
  expect(input).toEqual(copy)
})

test('checkInstall names the missing rows', () => {
  const s = oldInstalled() as Loose
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
