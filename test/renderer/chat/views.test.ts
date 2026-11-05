import { describe, expect, it } from 'vitest'
import * as R from '../../../src/renderer/src/actions/reasons'
import {
  attachTarget,
  chatPanelId,
  chatSessionId,
  chatViews,
  MAX_WEBGL,
  openChatIds,
  webglPlan,
} from '../../../src/renderer/src/chat/views'
import type { Frame } from '../../../src/renderer/src/wm/state'
import type { SessionRow } from '../../../src/shared/types'
import { row } from '../overview/fixtures'

function frame(id: string, panels: string[], active: string, minimised = false): Frame {
  return {
    active,
    id,
    locked: false,
    minimised,
    opacity: 1,
    panels,
    rect: { h: 100, w: 100, x: 0, y: 0 },
  }
}

describe('chat ids', () => {
  it('chatPanelId and chatSessionId convert both ways', () => {
    expect(chatPanelId('abc')).toBe('chat:abc')
    expect(chatSessionId('chat:abc')).toBe('abc')
    expect(chatSessionId('overview:1')).toBeNull()
    expect(chatSessionId('chat:')).toBeNull()
  })

  it('openChatIds includes chats in back tabs and minimised frames', () => {
    const frames = [
      frame('f1', ['overview:1', 'chat:a', 'chat:b'], 'chat:a'),
      frame('f2', ['chat:c'], 'chat:c', true),
    ]
    expect(openChatIds(frames)).toEqual(['a', 'b', 'c'])
  })
})

describe('chatViews', () => {
  it('marks the active chat of the top frame as focused and visible', () => {
    const frames = [frame('f1', ['chat:a'], 'chat:a'), frame('f2', ['chat:b'], 'chat:b')]
    const v = chatViews({ frames })
    expect(v.get('b')).toEqual({ focused: true, visible: true })
    expect(v.get('a')).toEqual({ focused: false, visible: true })
  })

  it('marks a back tab and a minimised chat as not visible', () => {
    const frames = [
      frame('f1', ['chat:a', 'chat:b'], 'chat:a'),
      frame('f2', ['chat:c'], 'chat:c', true),
    ]
    const v = chatViews({ frames })
    expect(v.get('b')).toEqual({ focused: false, visible: false })
    expect(v.get('c')).toEqual({ focused: false, visible: false })
    // The minimised frame is on top but is not the top frame.
    expect(v.get('a')).toEqual({ focused: true, visible: true })
  })
})

describe('webglPlan', () => {
  it('releases hidden terminals and loads up to 12', () => {
    const ids = Array.from({ length: 14 }, (_, i) => `s${i}`)
    const first = webglPlan(ids, [])
    expect(first.load).toEqual(ids.slice(0, MAX_WEBGL))
    expect(first.release).toEqual([])
    const second = webglPlan(ids.slice(1), ids.slice(0, MAX_WEBGL))
    expect(second.release).toEqual(['s0'])
    expect(second.load).toEqual(['s12'])
  })
})

describe('attachTarget', () => {
  it('waits for the session list', () => {
    expect(attachTarget(undefined, false)).toEqual({ ok: false, reason: R.REASON_WAIT_LIST })
  })

  it('gives the reason for a gone, external or parked row and for a row without a short ID', () => {
    const fail = (r: SessionRow | undefined) => attachTarget(r, true)
    expect(fail(undefined)).toEqual({ ok: false, reason: R.REASON_GONE })
    expect(fail(row({ kind: 'external', sessionId: 'x', shortId: 's' }))).toEqual({
      ok: false,
      reason: R.REASON_EXTERNAL,
    })
    expect(fail(row({ sessionId: 'x', shortId: 's', state: 'parked' }))).toEqual({
      ok: false,
      reason: R.REASON_PARKED,
    })
    expect(fail(row({ sessionId: 'x' }))).toEqual({ ok: false, reason: R.REASON_WAIT_ID })
  })

  it('gives the short ID and the cwd, and / for an empty cwd', () => {
    expect(attachTarget(row({ cwd: '/p', sessionId: 'x', shortId: 's1' }), true)).toEqual({
      cwd: '/p',
      ok: true,
      shortId: 's1',
    })
    expect(attachTarget(row({ cwd: '', sessionId: 'x', shortId: 's1' }), true)).toMatchObject({
      cwd: '/',
    })
  })
})
