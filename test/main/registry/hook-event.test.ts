import { expect, test } from 'vitest'
import { parseHookEvent } from '../../../src/main/registry/hook-event'

test('parseHookEvent reads a Stop event', () => {
  expect(
    parseHookEvent(
      '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Done"}',
      5,
    ),
  ).toEqual({ at: 5, lastAssistantMessage: 'Done', name: 'Stop', sessionId: 's1' })
})

test('parseHookEvent reads the notification type and the tool name', () => {
  expect(
    parseHookEvent(
      '{"hook_event_name":"Notification","session_id":"s1","notification_type":"permission_prompt","cwd":"/p"}',
      1,
    ),
  ).toEqual({
    at: 1,
    cwd: '/p',
    name: 'Notification',
    notificationType: 'permission_prompt',
    sessionId: 's1',
  })
  expect(
    parseHookEvent('{"hook_event_name":"PreToolUse","session_id":"s2","tool_name":"Bash"}', 2),
  ).toEqual({ at: 2, name: 'PreToolUse', sessionId: 's2', toolName: 'Bash' })
})

test('parseHookEvent returns null for an unknown event, bad JSON or no session_id', () => {
  expect(parseHookEvent('{"hook_event_name":"Other","session_id":"s1"}', 1)).toBeNull()
  expect(parseHookEvent('not json', 1)).toBeNull()
  expect(parseHookEvent('', 1)).toBeNull()
  expect(parseHookEvent('{"hook_event_name":"Stop"}', 1)).toBeNull()
})
