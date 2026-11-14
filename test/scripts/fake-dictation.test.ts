// A test of the fake speech helper of the smoke tests. The script runs with sh. It only prints
// fixed lines of the protocol. It never opens the microphone.
import { spawnSync } from 'node:child_process'
import { statSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { type HelperEvent, parseHelperLine } from '../../src/shared/dictation-protocol'

const FAKE = join(import.meta.dirname, '..', 'smoke', 'fake-dictation', 'bifrost-dictation')

// Run the fake helper with these stdin lines. Give its exit status and its events.
function runFake(input: string): { events: (HelperEvent | null)[]; status: number | null } {
  const result = spawnSync('sh', [FAKE], {
    encoding: 'utf8',
    env: { PATH: '/usr/bin:/bin' },
    input,
    timeout: 5_000,
  })
  const lines = result.stdout.split('\n').filter(line => line !== '')
  return { events: lines.map(parseHelperLine), status: result.status }
}

describe('the fake speech helper', () => {
  it('can run as a program', () => {
    expect(statSync(FAKE).mode & 0o111).not.toBe(0)
  })

  it('gives ready, then level and text for a start, then the final text for a stop', () => {
    const { events, status } = runFake('start\nstop\nquit\n')
    expect(status).toBe(0)
    expect(events).not.toContain(null)
    const kinds = events.map(event => event?.t)
    expect(kinds[0]).toBe('ready')
    expect(kinds).toContain('level')
    expect(kinds).toContain('text')
    expect(kinds.at(-1)).toBe('end')
    const lastText = events.filter(event => event?.t === 'text').at(-1)
    const end = events.at(-1)
    expect(end?.t === 'end' && lastText?.t === 'text' && end.final === lastText.final).toBe(true)
  })

  it('gives an empty end for a stop with no session', () => {
    const { events } = runFake('stop\n')
    expect(events).toEqual([
      { fallback: false, language: 'en-US', t: 'ready' },
      { final: '', t: 'end' },
    ])
  })

  it('stops at the end of stdin', () => {
    const { events, status } = runFake('start\n')
    expect(status).toBe(0)
    expect(events.map(event => event?.t)).not.toContain('end')
  })
})
