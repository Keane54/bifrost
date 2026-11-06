import { describe, expect, it } from 'vitest'
import * as R from '../../../src/renderer/src/actions/reasons'
import {
  afterSend,
  CLAUDE_BOX_LOST_NOTE,
  claudeBoxLostNote,
  effectiveAlsoClaude,
  planRename,
  renameControls,
} from '../../../src/renderer/src/actions/rename-model'
import { REASON_NAME_LONG, REASON_NO_NAME } from '../../../src/shared/input'
import { row } from '../overview/fixtures'

const owned = row({ sessionId: 'o', shortId: 'abcd1234', state: 'idle' })
const external = row({ kind: 'external', sessionId: 'e' })
const parked = row({ sessionId: 'p', shortId: 'abcd1234', state: 'parked' })
const red = row({ box: 'red', sessionId: 'r', shortId: 'abcd1234', state: 'needs-you' })

describe('renameControls', () => {
  it('shows the Claude Code check box only for an owned row that is not parked', () => {
    expect(renameControls(owned).claudeBox).toBe('enabled')
    expect(renameControls(external).claudeBox).toBe('hidden')
    expect(renameControls(parked).claudeBox).toBe('hidden')
  })

  it('disables the check box with the red box reason', () => {
    expect(renameControls(red)).toMatchObject({
      claudeBox: 'disabled',
      claudeBoxReason: R.REASON_RED_BOX,
    })
  })

  it('disables the check box while the short ID is missing', () => {
    const noId = row({ sessionId: 'n', state: 'idle' })
    expect(renameControls(noId)).toMatchObject({
      claudeBox: 'disabled',
      claudeBoxReason: R.REASON_WAIT_ID,
    })
  })

  it('shows the reset button only when a local name exists', () => {
    expect(renameControls(owned).showReset).toBe(false)
    expect(renameControls({ ...owned, claudeName: 'alpha', name: 'Work' }).showReset).toBe(true)
    expect(renameControls({ ...external, claudeName: 'alpha', name: 'Work' }).showReset).toBe(true)
  })
})

describe('planRename', () => {
  it('saves a local name only', () => {
    expect(planRename(owned, { alsoClaude: false, name: '  Work  ' })).toEqual({
      alias: 'Work',
      ok: true,
      send: null,
    })
  })

  it('clears the local name for an empty name', () => {
    expect(planRename(external, { alsoClaude: false, name: '   ' })).toEqual({
      alias: null,
      ok: true,
      send: null,
    })
  })

  it('refuses control characters and a long name', () => {
    expect(planRename(owned, { alsoClaude: false, name: 'a\x1bb' }).ok).toBe(false)
    expect(planRename(owned, { alsoClaude: false, name: 'x'.repeat(65) })).toEqual({
      ok: false,
      reason: REASON_NAME_LONG,
    })
  })

  it('clears the local name and sends /rename when Also rename is on', () => {
    expect(planRename(owned, { alsoClaude: true, name: 'Work' })).toEqual({
      alias: null,
      ok: true,
      send: '/rename Work',
    })
  })

  it('needs a name when Also rename is on', () => {
    expect(planRename(owned, { alsoClaude: true, name: ' ' })).toEqual({
      ok: false,
      reason: REASON_NO_NAME,
    })
  })

  it('gives the right reason for a hidden check box', () => {
    expect(planRename(parked, { alsoClaude: true, name: 'Work' })).toEqual({
      ok: false,
      reason: R.REASON_PARKED,
    })
    expect(planRename(external, { alsoClaude: true, name: 'Work' })).toEqual({
      ok: false,
      reason: R.REASON_EXTERNAL,
    })
  })

  it('refuses Also rename when the check box is not usable', () => {
    expect(planRename(red, { alsoClaude: true, name: 'Work' })).toEqual({
      ok: false,
      reason: R.REASON_RED_BOX,
    })
    expect(planRename(parked, { alsoClaude: true, name: 'Work' }).ok).toBe(false)
    expect(planRename(external, { alsoClaude: true, name: 'Work' }).ok).toBe(false)
  })
})

describe('effectiveAlsoClaude', () => {
  it('is on only when the box is on and enabled', () => {
    expect(effectiveAlsoClaude(owned, true)).toBe(true)
    expect(effectiveAlsoClaude(owned, false)).toBe(false)
    expect(effectiveAlsoClaude(red, true)).toBe(false)
    expect(effectiveAlsoClaude(parked, true)).toBe(false)
  })

  it('gives the note when the box was on but is not usable now', () => {
    expect(claudeBoxLostNote(red, true)).toBe(CLAUDE_BOX_LOST_NOTE)
    expect(claudeBoxLostNote(red, false)).toBeNull()
    expect(claudeBoxLostNote(owned, true)).toBeNull()
  })
})

describe('afterSend (ruling of 2026-11-06)', () => {
  it('clears the local name after a /rename from the send box or Run slash command', () => {
    for (const text of ['/rename work', '  /rename work  ', '/rename', '/rename\twork']) {
      expect(afterSend(text)).toEqual({ clearAlias: true, rememberSlash: false })
    }
  })

  it('keeps the local name and remembers the text after any other send', () => {
    for (const text of ['/renamex', '/compact', 'please /rename it', 'hello']) {
      expect(afterSend(text)).toEqual({ clearAlias: false, rememberSlash: true })
    }
  })
})
