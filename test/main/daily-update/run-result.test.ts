import { describe, expect, it } from 'vitest'
import {
  checkDailyResult,
  extractResult,
  MAX_OUTPUT_BYTES,
  RESULT_BEGIN,
  RESULT_END,
  RESULT_VERSION,
} from '../../../src/main/daily-update/run-result'

const ON = ['a', 'b']
const item = { id: 'T-1', kind: 'ticket', title: 'Title' }
const area = (id: string, extra: object = {}) => ({
  draft: 'Done',
  id,
  items: [item],
  moved: true,
  ...extra,
})
const good = () => ({ areas: [area('a'), area('b')], unplaced: [item], version: 1 })
const check = (v: unknown, on = ON) => checkDailyResult(JSON.stringify(v), on)
const bad = { failure: 'bad-result', ok: false }

describe('checkDailyResult', () => {
  it('accepts a good file', () => {
    const out = check(good())
    expect(RESULT_VERSION).toBe(1)
    expect(out).toEqual({
      areas: [area('a'), area('b')],
      ok: true,
      unplaced: [item],
    })
  })

  it('keeps the optional item fields', () => {
    const full = { ...item, from: 'A', to: 'B', url: 'https://x.test/1' }
    const out = check({ ...good(), areas: [area('a', { items: [full] }), area('b')] })
    expect(out.ok && out.areas[0]?.items[0]).toEqual(full)
  })

  it.each(['no-user', 'source-unavailable', 'tool-denied'])(
    'accepts the failure %s alone',
    code => {
      expect(check({ failure: code, version: 1 })).toEqual({ failure: code, ok: false })
    },
  )

  it('refuses a failure with other keys or an unknown code', () => {
    expect(check({ areas: [], failure: 'no-user', version: 1 })).toEqual(bad)
    expect(check({ failure: 'timeout', version: 1 })).toEqual(bad)
    expect(check({ failure: 'bad-result', version: 1 })).toEqual(bad)
  })

  it('refuses a missing, an extra, an unknown or a duplicate area', () => {
    expect(check({ ...good(), areas: [area('a')] })).toEqual(bad)
    expect(check({ ...good(), areas: [area('a'), area('b'), area('c')] })).toEqual(bad)
    expect(check({ ...good(), areas: [area('a'), area('x')] })).toEqual(bad)
    expect(check({ ...good(), areas: [area('a'), area('a')] })).toEqual(bad)
  })

  it('refuses two items with the same kind and ID in one area or in unplaced', () => {
    const pr = { id: 'T-1', kind: 'pr', title: 'A PR' }
    const two = [item, { ...item, title: 'Other' }]
    expect(check({ ...good(), areas: [area('a', { items: two }), area('b')] })).toEqual(bad)
    expect(check({ ...good(), unplaced: two })).toEqual(bad)
    expect(check({ ...good(), areas: [area('a', { items: [item, pr] }), area('b')] }).ok).toBe(true)
    expect(check({ ...good(), unplaced: [item, pr] }).ok).toBe(true)
  })

  it('refuses an unknown key at each level', () => {
    expect(check({ ...good(), extra: 1 })).toEqual(bad)
    expect(check({ ...good(), areas: [area('a', { extra: 1 }), area('b')] })).toEqual(bad)
    expect(check({ ...good(), unplaced: [{ ...item, extra: 1 }] })).toEqual(bad)
  })

  it('refuses a wrong version, a non-object and a missing list', () => {
    expect(check({ ...good(), version: 2 })).toEqual(bad)
    expect(check([])).toEqual(bad)
    expect(check(null)).toEqual(bad)
    expect(check({ areas: [area('a'), area('b')], version: 1 })).toEqual(bad)
  })

  it('refuses an http url and a url that is too long', () => {
    const withUrl = (url: string) => ({ ...good(), unplaced: [{ ...item, url }] })
    expect(check(withUrl('http://x.test'))).toEqual(bad)
    expect(check(withUrl(`https://${'a'.repeat(2000)}`))).toEqual(bad)
    expect(check(withUrl(`https://${'a'.repeat(1992)}`)).ok).toBe(true)
  })

  it('refuses text over the limits', () => {
    const t = (extra: object) => ({ ...good(), unplaced: [{ ...item, ...extra }] })
    expect(check(t({ title: 'x'.repeat(301) }))).toEqual(bad)
    expect(check(t({ title: 'x'.repeat(300) })).ok).toBe(true)
    expect(check(t({ id: 'x'.repeat(101) }))).toEqual(bad)
    expect(check(t({ from: 'x'.repeat(61) }))).toEqual(bad)
    expect(check(t({ to: 'x'.repeat(61) }))).toEqual(bad)
    expect(check(t({ kind: 'issue' }))).toEqual(bad)
  })

  it('refuses an empty draft and a draft that is too long', () => {
    expect(check({ ...good(), areas: [area('a', { draft: '' }), area('b')] })).toEqual(bad)
    expect(
      check({ ...good(), areas: [area('a', { draft: 'x'.repeat(8001) }), area('b')] }),
    ).toEqual(bad)
    expect(
      check({ ...good(), areas: [area('a', { draft: 'x'.repeat(8000) }), area('b')] }).ok,
    ).toBe(true)
  })

  it('refuses too many items and a moved flag that is not a boolean', () => {
    // Each item has its own ID, because two items with one kind and ID are refused.
    const many = Array.from({ length: 101 }, (_, i) => ({ ...item, id: `T-${i}` }))
    expect(check({ ...good(), unplaced: many })).toEqual(bad)
    expect(check({ ...good(), areas: [area('a', { items: many }), area('b')] })).toEqual(bad)
    expect(check({ ...good(), unplaced: many.slice(0, 100) }).ok).toBe(true)
    expect(check({ ...good(), areas: [area('a', { moved: 'yes' }), area('b')] })).toEqual(bad)
  })

  it('refuses text that is not JSON', () => {
    expect(checkDailyResult('not json', ON)).toEqual(bad)
  })
})

describe('extractResult', () => {
  const out = (result: unknown, extra: object = {}) =>
    JSON.stringify({ is_error: false, result, type: 'result', ...extra })
  const block = (body: string) => `${RESULT_BEGIN}\n${body}\n${RESULT_END}`

  it('gives the text between the markers, after prose', () => {
    const stdout = out(`I wrote it.\n${block('{"a":1}')}\nDone.`)
    expect(extractResult(stdout)).toEqual({ ok: true, text: '{"a":1}' })
  })

  it('uses the last BEGIN line', () => {
    const stdout = out(`${block('first')}\n${block('second')}`)
    expect(extractResult(stdout)).toEqual({ ok: true, text: 'second' })
    const open = out(`${RESULT_BEGIN}\nold\n${RESULT_BEGIN}\nnew\n${RESULT_END}`)
    expect(extractResult(open)).toEqual({ ok: true, text: 'new' })
  })

  it('accepts marker lines with white space around them', () => {
    expect(extractResult(out(`  ${RESULT_BEGIN} \nx\n${RESULT_END}\t`))).toEqual({
      ok: true,
      text: 'x',
    })
  })

  it('refuses each bad output', () => {
    const none = { ok: false }
    expect(extractResult('x'.repeat(MAX_OUTPUT_BYTES + 1))).toEqual(none)
    expect(extractResult('not json')).toEqual(none)
    expect(extractResult('[]')).toEqual(none)
    expect(extractResult('null')).toEqual(none)
    expect(extractResult(out(block('x'), { is_error: true }))).toEqual(none)
    expect(extractResult(JSON.stringify({ result: block('x') }))).toEqual(none)
    expect(extractResult(out(5))).toEqual(none)
    expect(extractResult(out('no markers'))).toEqual(none)
    expect(extractResult(out(`${RESULT_BEGIN}\nx`))).toEqual(none)
    expect(extractResult(out(`${RESULT_END}\nx\n${RESULT_BEGIN}`))).toEqual(none)
    expect(extractResult(out(`say ${RESULT_BEGIN} x ${RESULT_END}`))).toEqual(none)
  })
})
