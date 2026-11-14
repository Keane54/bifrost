// The JSON lines that the speech helper prints. Bifrost trusts no line: a bad line gives null.
import { describe, expect, it } from 'vitest'
import { MAX_HELPER_LINE, parseHelperLine } from '../../src/shared/dictation-protocol'

const line = (value: unknown): string => JSON.stringify(value)

describe('parseHelperLine', () => {
  it('accepts each event of the helper', () => {
    const events = [
      { fallback: false, language: 'en-US', t: 'ready' },
      { fallback: true, language: 'en-US', t: 'ready' },
      { progress: 0, t: 'downloading' },
      { progress: 0.37, t: 'downloading' },
      { progress: 1, t: 'downloading' },
      { t: 'level', v: 0 },
      { t: 'level', v: 0.42 },
      { t: 'level', v: 1 },
      { final: '', t: 'text', volatile: 'Open' },
      { final: 'Open app.tsx. ', t: 'text', volatile: 'Fix the bug' },
      { final: 'Café 👋 ok.', t: 'end' },
      { final: '', t: 'end' },
      { code: 'mic-denied', message: 'The microphone is off.', t: 'error' },
      { code: 'mic-asked', message: 'macOS asks for the microphone.', t: 'error' },
      { code: 'speech-asked', message: 'macOS asks for Speech Recognition.', t: 'error' },
      { code: 'speech-denied', message: 'Speech Recognition is off.', t: 'error' },
      { code: 'no-model', message: 'No model.', t: 'error' },
      { code: 'failed', message: 'The audio engine did not start.', t: 'error' },
    ]
    for (const event of events) expect(parseHelperLine(line(event))).toEqual(event)
  })

  it('accepts white space around the JSON', () => {
    expect(parseHelperLine(` ${line({ t: 'level', v: 0.5 })}\r`)).toEqual({ t: 'level', v: 0.5 })
  })

  it('refuses a line that is not JSON or not an object', () => {
    for (const bad of ['', 'ready', '{', 'null', '1', '"text"', '[]', line([{ t: 'end' }])]) {
      expect(parseHelperLine(bad), bad).toBeNull()
    }
  })

  it('refuses a bad or unknown type', () => {
    for (const t of ['boot', 'listening', 'READY', '', 1, null]) {
      expect(parseHelperLine(line({ final: '', t })), String(t)).toBeNull()
    }
    expect(parseHelperLine(line({ final: '' }))).toBeNull()
  })

  it('refuses a level outside 0..1 or a level that is not a number', () => {
    for (const v of [-0.01, 1.01, 2, -1, '0.5', null, true]) {
      expect(parseHelperLine(line({ t: 'level', v })), String(v)).toBeNull()
    }
    expect(parseHelperLine('{"t":"level","v":1e400}')).toBeNull()
  })

  it('refuses a download progress outside 0..1 or a progress that is not a number', () => {
    for (const progress of [-0.01, 1.01, 100, '0.5', null, false]) {
      expect(parseHelperLine(line({ progress, t: 'downloading' })), String(progress)).toBeNull()
    }
  })

  it('refuses a missing field', () => {
    for (const event of [
      { language: 'en-US', t: 'ready' },
      { fallback: false, t: 'ready' },
      { t: 'level' },
      { t: 'downloading' },
      { final: '', t: 'text' },
      { t: 'text', volatile: '' },
      { t: 'end' },
      { message: 'x', t: 'error' },
      { code: 'failed', t: 'error' },
    ]) {
      expect(parseHelperLine(line(event)), line(event)).toBeNull()
    }
  })

  it('refuses a field of the wrong type', () => {
    for (const event of [
      { fallback: 'no', language: 'en-US', t: 'ready' },
      { fallback: false, language: 5, t: 'ready' },
      { fallback: false, language: '', t: 'ready' },
      { final: 1, t: 'text', volatile: '' },
      { final: '', t: 'text', volatile: null },
      { final: ['a'], t: 'end' },
      { code: 'failed', message: 1, t: 'error' },
    ]) {
      expect(parseHelperLine(line(event)), line(event)).toBeNull()
    }
  })

  it('refuses an unknown error code', () => {
    for (const code of ['mic', 'denied', 'asked', 'mic-ask', 'model-missing', 'FAILED', '']) {
      expect(parseHelperLine(line({ code, message: 'x', t: 'error' })), code).toBeNull()
    }
  })

  it('refuses extra keys', () => {
    for (const event of [
      { engine: 'analyzer', fallback: false, language: 'en-US', t: 'ready' },
      { t: 'level', ts: 12, v: 0.5 },
      { bytes: 10, progress: 0.5, t: 'downloading' },
      { final: '', isFinal: false, t: 'text', volatile: '' },
      { final: '', stopMs: 40, t: 'end' },
      { code: 'failed', message: 'x', nsCode: 1, t: 'error' },
      { t: 'level', type: 'level', v: 0.5 },
    ]) {
      expect(parseHelperLine(line(event)), line(event)).toBeNull()
    }
  })

  it('refuses a line over the cap, and accepts a line at the cap', () => {
    const head = '{"t":"end","final":"'
    const tail = '"}'
    const atCap = `${head}${'a'.repeat(MAX_HELPER_LINE - head.length - tail.length)}${tail}`
    expect(atCap).toHaveLength(MAX_HELPER_LINE)
    expect(parseHelperLine(atCap)).not.toBeNull()
    const overCap = `${head}${'a'.repeat(MAX_HELPER_LINE - head.length - tail.length + 1)}${tail}`
    expect(parseHelperLine(overCap)).toBeNull()
    expect(parseHelperLine(`${atCap} `)).toBeNull()
  })

  it('has the cap of the plan', () => {
    expect(MAX_HELPER_LINE).toBe(64_000)
  })

  it('gives a new object with only the known fields', () => {
    const text = line({ final: 'a', t: 'end' })
    const first = parseHelperLine(text)
    const second = parseHelperLine(text)
    expect(first).toEqual(second)
    expect(first).not.toBe(second)
    expect(Object.getPrototypeOf(first)).toBe(Object.prototype)
  })

  it('refuses a key that is a prototype name', () => {
    expect(parseHelperLine('{"t":"end","final":"a","__proto__":{"x":1}}')).toBeNull()
  })
})
