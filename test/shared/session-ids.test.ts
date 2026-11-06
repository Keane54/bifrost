import { describe, expect, it } from 'vitest'
import { continueIdOf, currentIdOf } from '../../src/shared/session-ids'

describe('the IDs of a row (spec 6.1)', () => {
  it('currentIdOf gives the current ID, else the row ID', () => {
    expect(currentIdOf({ sessionId: 'row' })).toBe('row')
    expect(currentIdOf({ currentId: 'now', sessionId: 'row' })).toBe('now')
  })

  it('continueIdOf gives the resume ID of a background row', () => {
    expect(
      continueIdOf({ currentId: 'now', kind: 'owned', resumeId: 'job', sessionId: 'row' }),
    ).toBe('job')
    expect(continueIdOf({ currentId: 'now', kind: 'owned', sessionId: 'row' })).toBeUndefined()
  })

  it('continueIdOf gives the current ID of an interactive row', () => {
    expect(continueIdOf({ currentId: 'now', kind: 'external', sessionId: 'row' })).toBe('now')
    expect(continueIdOf({ kind: 'external', resumeId: 'x', sessionId: 'row' })).toBe('row')
  })
})
