import { describe, expect, it } from 'vitest'
import { REASON_WAIT_LIST } from '../../../src/renderer/src/actions/reasons'
import { notifiedOpenStep } from '../../../src/renderer/src/actions/run-plan'
import { attachTarget } from '../../../src/renderer/src/chat/views'
import {
  INITIAL_REGISTRY,
  withFirstRows,
  withUpdate,
} from '../../../src/renderer/src/data/registry-state'
import { row } from '../overview/fixtures'

const a = row({ sessionId: 'A' })
const b = row({ sessionId: 'B' })

describe('registry state (bug B1)', () => {
  it('is not loaded before the first rows come', () => {
    expect(INITIAL_REGISTRY.loaded).toBe(false)
    expect(INITIAL_REGISTRY.rows).toEqual([])
  })

  it('the answer of the first rows() call sets loaded, without an update', () => {
    const state = withFirstRows(INITIAL_REGISTRY, [a])
    expect(state.loaded).toBe(true)
    expect(state.rows).toEqual([a])
  })

  it('an empty answer also counts as loaded', () => {
    const state = withFirstRows(INITIAL_REGISTRY, [])
    expect(state.loaded).toBe(true)
    expect(state.rows).toEqual([])
  })

  it('an update that came first is newer, so a late answer keeps its rows and error', () => {
    const updated = withUpdate(INITIAL_REGISTRY, [b], 'claude agents failed.')
    const state = withFirstRows(updated, [a])
    expect(state.rows).toEqual([b])
    expect(state.error).toBe('claude agents failed.')
    expect(state.loaded).toBe(true)
  })

  it('an update sets the rows, the error and loaded', () => {
    const state = withUpdate(withFirstRows(INITIAL_REGISTRY, [a]), [b], null)
    expect(state).toMatchObject({ error: null, loaded: true, rows: [b] })
  })

  it('a chat window attaches after the first answer alone', () => {
    const state = withFirstRows(INITIAL_REGISTRY, [a])
    const target = attachTarget(
      state.rows.find(r => r.sessionId === 'A'),
      state.loaded,
    )
    expect(target).not.toEqual({ ok: false, reason: REASON_WAIT_LIST })
  })

  it('a pending notification open stops after the first answer when its row is not there', () => {
    const state = withFirstRows(INITIAL_REGISTRY, [a])
    expect(notifiedOpenStep('A', state.rows, state.loaded)).toBe('open')
    expect(notifiedOpenStep('Z', state.rows, state.loaded)).toBe('drop')
  })
})
