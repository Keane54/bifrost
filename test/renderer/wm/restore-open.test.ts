// A double-click on an Overview row runs the open action. This action dispatches the reducer
// action open for the chat panel. These tests prove that open restores a minimised chat.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  frameOf,
  initialState,
  topFrame,
  type WmAction,
  type WmState,
  wmReducer,
} from '../../../src/renderer/src/wm/state'

const bounds = { h: 800, w: 1200 }
const CHAT = 'chat:123e4567-e89b-12d3-a456-426614174000'
const open = (panelId: string): WmAction => ({ panelId, type: 'open' })

function run(actions: WmAction[], from: WmState = initialState(bounds)): WmState {
  return actions.reduce(wmReducer, from)
}

function minimise(state: WmState, panelId: string): WmState {
  const frame = frameOf(state, panelId)
  if (!frame) throw new Error('no frame')
  return wmReducer(state, { frameId: frame.id, type: 'minimise' })
}

describe('open restores a minimised chat', () => {
  it('restores and focuses a minimised frame with the chat as the active panel', () => {
    const s = run([open(CHAT), open('watchlist')])
    const minimised = minimise(s, CHAT)
    expect(frameOf(minimised, CHAT)?.minimised).toBe(true)
    const next = wmReducer(minimised, open(CHAT))
    expect(frameOf(next, CHAT)?.minimised).toBe(false)
    expect(topFrame(next)?.active).toBe(CHAT)
  })

  it('restores a minimised frame that holds the chat as a back tab and shows the chat', () => {
    const s = run([open('watchlist'), open(CHAT)])
    const target = frameOf(s, 'watchlist')
    const source = frameOf(s, CHAT)
    if (!target || !source) throw new Error('no frame')
    const stacked = wmReducer(s, { frameId: source.id, targetId: target.id, type: 'stack' })
    const back = wmReducer(stacked, open('watchlist'))
    expect(frameOf(back, CHAT)?.active).toBe('watchlist')
    const minimised = minimise(back, CHAT)
    const next = wmReducer(minimised, open(CHAT))
    const frame = frameOf(next, CHAT)
    expect(frame?.minimised).toBe(false)
    expect(frame?.active).toBe(CHAT)
    expect(topFrame(next)?.id).toBe(frame?.id)
  })

  it('restores the right frame when another frame is on top', () => {
    const s = run([open(CHAT), open('watchlist'), open('event-log')])
    const minimised = minimise(s, CHAT)
    const next = wmReducer(minimised, open(CHAT))
    expect(topFrame(next)?.active).toBe(CHAT)
    expect(next.frames.filter(f => f.minimised)).toHaveLength(0)
    expect(next.frames).toHaveLength(3)
  })

  it('the double-click of an Overview row runs the open action', () => {
    const text = readFileSync(
      join(__dirname, '../../../src/renderer/src/overview/OverviewTable.tsx'),
      'utf8',
    )
    expect(text).toMatch(/onDoubleClick=\{\(\) => \{[^}]*run\('open', id\)/s)
  })
})
