import { describe, expect, it } from 'vitest'
import {
  MAX_MESSAGE,
  MAX_PATHS,
  MAX_REPLY,
  MAX_SUBJECT,
  parseRequestResult,
  REQUEST_RESULT_VERSION,
} from '../../../src/main/reviews/request-result'
import { MAX_QUESTION } from '../../../src/main/reviews/state'

const HEAD = 'a'.repeat(40)
const BY = 'c'.repeat(40)
const SECRET = 'sk-ant-secret'

type Expect = Parameters<typeof parseRequestResult>[1]

const EXPECT: Expect = {
  changed: new Set(['src/limit.ts', 'README.md', 'src/gone.ts']),
  headSha: HEAD,
  items: ['PRRT_1', 'IC_2', 'PRR_3', 'PRRT_4'],
  pr: 'acme/api#9',
}

type Data = Record<string, unknown>
type Item = Record<string, unknown>

function valid(): Data {
  return {
    checks: 'passed',
    commit: {
      message: 'fix: check the upper limit\n\nThe check used <=.',
      paths: ['src/limit.ts', 'src/gone.ts'],
    },
    headSha: HEAD,
    items: [
      { id: 'PRRT_1', outcome: 'fixed' },
      { id: 'IC_2', outcome: 'no-fix', reply: 'The README covers this already.\n\tSee "Limits".' },
      { id: 'PRR_3', outcome: 'no-action' },
      { id: 'PRRT_4', outcome: 'needs-you', question: 'Is the limit for each user or each key?' },
    ],
    pr: 'acme/api#9',
    version: 1,
  }
}

const items = (data: Data): Item[] => data.items as Item[]
const commit = (data: Data): Data => data.commit as Data

function reasonOf(text: string, over: Partial<Expect> = {}): string {
  const out = parseRequestResult(text, { ...EXPECT, ...over })
  return out.ok ? 'valid' : out.reason
}

const reason = (data: unknown, over: Partial<Expect> = {}): string =>
  reasonOf(JSON.stringify(data), over)

// A valid result with one change.
function changed(change: (data: Data) => void): Data {
  const data = valid()
  change(data)
  return data
}

describe('parseRequestResult', () => {
  it('accepts a valid result', () => {
    const out = parseRequestResult(JSON.stringify(valid()), EXPECT)
    expect(out.ok ? 'valid' : out.reason).toBe('valid')
    if (!out.ok) return
    expect(REQUEST_RESULT_VERSION).toBe(1)
    expect(out.result).toEqual(valid())
  })

  it('accepts a Fixed item with by and no commit', () => {
    const data = changed(d => {
      d.items = [
        { by: BY, id: 'PRRT_1', outcome: 'fixed' },
        { id: 'IC_2', outcome: 'no-action' },
        { id: 'PRR_3', outcome: 'no-action' },
        { id: 'PRRT_4', outcome: 'no-action' },
      ]
      d.commit = null
      d.checks = 'none'
    })
    const out = parseRequestResult(JSON.stringify(data), EXPECT)
    expect(out.ok ? 'valid' : out.reason).toBe('valid')
    if (!out.ok) return
    expect(out.result.commit).toBeNull()
    expect(out.result.items[0]).toEqual({ by: BY, id: 'PRRT_1', outcome: 'fixed' })
    // A 64 digit ID of a SHA-256 repository is a full ID too.
    const long = changed(d => {
      items(d)[0] = { by: 'd'.repeat(64), id: 'PRRT_1', outcome: 'fixed' }
      d.commit = null
    })
    expect(reason(long)).toBe('valid')
  })

  it('refuses a by that is not a full commit ID', () => {
    for (const by of ['abc1234', 'C'.repeat(40), 'c'.repeat(41), 12, null]) {
      const data = changed(d => {
        items(d)[0] = { by, id: 'PRRT_1', outcome: 'fixed' }
        d.commit = null
      })
      expect(reason(data)).toBe('the by field of item 1 is not a full commit ID')
    }
  })

  it('refuses bad JSON, a missing field and an unknown field', () => {
    expect(reasonOf('{"version": 1,')).toBe('the result is not valid JSON')
    expect(reasonOf('')).toBe('the result is not valid JSON')
    expect(reason([valid()])).toBe('the result is not a JSON object')
    expect(reason(null)).toBe('the result is not a JSON object')
    for (const key of ['version', 'pr', 'headSha', 'items', 'commit', 'checks']) {
      const data = valid()
      delete data[key]
      expect(reason(data)).toBe(`the ${key} field is missing`)
    }
    expect(reason({ ...valid(), extra: 1 })).toBe('an unknown field')
    expect(reason(changed(d => Object.assign(items(d)[2] ?? {}, { note: 'x' })))).toBe(
      'an unknown field',
    )
    expect(reason(changed(d => Object.assign(commit(d), { author: 'x' })))).toBe('an unknown field')
    // A known field of another outcome.
    expect(reason(changed(d => Object.assign(items(d)[0] ?? {}, { reply: 'Done.' })))).toBe(
      'item 1 has a reply field, which a fixed item does not have',
    )
    expect(reason(changed(d => Object.assign(items(d)[1] ?? {}, { by: BY })))).toBe(
      'item 2 has a by field, which a no-fix item does not have',
    )
    expect(reason(changed(d => Object.assign(items(d)[2] ?? {}, { question: 'Why?' })))).toBe(
      'item 3 has a question field, which a no-action item does not have',
    )
    // A missing field of an item or of the commit.
    expect(reason(changed(d => delete items(d)[1]?.reply))).toBe('item 2 has no reply field')
    expect(reason(changed(d => delete items(d)[3]?.question))).toBe('item 4 has no question field')
    expect(reason(changed(d => delete items(d)[0]?.outcome))).toBe('item 1 has no outcome field')
    expect(reason(changed(d => delete items(d)[0]?.id))).toBe('item 1 has no id field')
    expect(reason(changed(d => delete commit(d).paths))).toBe('the commit has no paths field')
    expect(reason(changed(d => delete commit(d).message))).toBe('the commit has no message field')
    // Wrong types.
    expect(reason(changed(d => (d.items = {})))).toBe('the items field is not a list')
    expect(reason(changed(d => (items(d)[0] = 'PRRT_1' as unknown as Item)))).toBe(
      'item 1 is not a JSON object',
    )
    expect(reason(changed(d => (d.commit = 'fix: x')))).toBe(
      'the commit field is not null or a JSON object',
    )
    expect(reason(changed(d => (d.commit = [])))).toBe(
      'the commit field is not null or a JSON object',
    )
    expect(reason(changed(d => (d.version = 2)))).toBe('the version field is not 1')
    expect(reason(changed(d => (d.version = '1')))).toBe('the version field is not 1')
    expect(reason(changed(d => (items(d)[0] = { id: 'PRRT_1', outcome: 'done' })))).toBe(
      'the outcome of item 1 is not fixed, no-fix, no-action or needs-you',
    )
    expect(reason(changed(d => (d.checks = 'skipped')))).toBe(
      'the checks field is not passed, failed, blocked or none',
    )
  })

  it('refuses another PR or another head', () => {
    expect(reason(changed(d => (d.pr = 'acme/api#10')))).toBe(
      'the pr field is not this pull request',
    )
    expect(reason(changed(d => (d.headSha = 'b'.repeat(40))))).toBe(
      'the headSha field is not the head commit of the round',
    )
    expect(reason(valid(), { pr: 'acme/web#9' })).toBe('the pr field is not this pull request')
  })

  it('refuses an unknown item, a missing item and a second result for one item', () => {
    expect(reason(changed(d => (items(d)[2] = { id: 'PRR_9', outcome: 'no-action' })))).toBe(
      'an item that is not in the input',
    )
    expect(reason(changed(d => (items(d)[2] = { id: 7, outcome: 'no-action' })))).toBe(
      'an item that is not in the input',
    )
    expect(reason(changed(d => items(d).pop()))).toBe('a missing item')
    expect(reason(changed(d => (d.items = [])))).toBe('a missing item')
    const twice = changed(d => items(d).push({ id: 'PRR_3', outcome: 'no-action' }))
    expect(reason(twice)).toBe('a second result for one item')
  })

  it('refuses a blank reply and a question over MAX_QUESTION', () => {
    const reply = (text: unknown): Data =>
      changed(d => (items(d)[1] = { id: 'IC_2', outcome: 'no-fix', reply: text }))
    const question = (text: unknown): Data =>
      changed(d => (items(d)[3] = { id: 'PRRT_4', outcome: 'needs-you', question: text }))

    expect(reason(reply(' \n\t '))).toBe('the reply of item 2 is empty')
    expect(reason(reply(''))).toBe('the reply of item 2 is empty')
    expect(reason(reply(5))).toBe('the reply of item 2 is not text')
    expect(reason(reply('x'.repeat(MAX_REPLY)))).toBe('valid')
    expect(reason(reply('x'.repeat(MAX_REPLY + 1)))).toBe(
      'the reply of item 2 is longer than 4,000 characters',
    )
    expect(reason(reply('Ring \u0007 the bell.'))).toBe(
      'the reply of item 2 has a control character',
    )
    expect(reason(reply('Line one.\r\nLine two.'))).toBe(
      'the reply of item 2 has a control character',
    )
    // A character that changes the direction of the text.
    expect(reason(reply('Look ‮ here.'))).toBe('the reply of item 2 has a control character')

    expect(reason(question('x'.repeat(MAX_QUESTION)))).toBe('valid')
    expect(reason(question('x'.repeat(MAX_QUESTION + 1)))).toBe(
      'the question of item 4 is longer than 500 characters',
    )
    expect(reason(question('   '))).toBe('the question of item 4 is empty')
    expect(reason(question(null))).toBe('the question of item 4 is not text')
    expect(reason(question('One?\n\tTwo?'))).toBe('valid')
    expect(reason(question('One?\u0000'))).toBe('the question of item 4 has a control character')
  })

  it('refuses a path with .., an absolute path, a path below .git and an unchanged path', () => {
    const withPath = (path: unknown): Data =>
      changed(d => (commit(d).paths = ['src/limit.ts', path]))
    // Each path is in changed, so that only the rule of its form refuses it.
    const form = 'path 2 of the commit is not a clean relative path'
    for (const path of [
      '../secret.ts',
      'src/../../secret.ts',
      '/etc/hosts',
      'src\\limit.ts',
      'src//limit.ts',
      'src/',
      './src/limit.ts',
      'src/./limit.ts',
      '',
    ]) {
      expect(reason(withPath(path), { changed: new Set(['src/limit.ts', path]) }), path).toBe(form)
    }
    for (const path of ['.git', '.git/config', '.GIT/hooks/pre-commit', 'sub/.git/config']) {
      expect(reason(withPath(path), { changed: new Set(['src/limit.ts', path]) }), path).toBe(
        'path 2 of the commit is in a .git folder',
      )
    }
    expect(reason(withPath('src/other.ts'))).toBe('path 2 of the commit did not change')
    expect(reason(withPath(3))).toBe('path 2 of the commit is not text')
    expect(reason(withPath('src/limit.ts'))).toBe('path 2 of the commit shows more than one time')
    expect(reason(changed(d => (commit(d).paths = 'src/limit.ts')))).toBe(
      'the paths field of the commit is not a list',
    )
    expect(reason(changed(d => (commit(d).paths = [])))).toBe('the commit has no paths')
    const many = Array.from({ length: MAX_PATHS + 1 }, (_, i) => `f${i}.ts`)
    const all = new Set(many)
    expect(
      reason(
        changed(d => (commit(d).paths = many.slice(0, MAX_PATHS))),
        { changed: all },
      ),
    ).toBe('valid')
    expect(
      reason(
        changed(d => (commit(d).paths = many)),
        { changed: all },
      ),
    ).toBe('the commit has more than 200 paths')
  })

  it('refuses a Fixed item with no commit and a commit with no Fixed item', () => {
    expect(reason(changed(d => (d.commit = null)))).toBe('a Fixed item has no commit')
    // A Fixed item with by does not need the commit, so the commit has no Fixed item.
    const onlyBy = changed(d => (items(d)[0] = { by: BY, id: 'PRRT_1', outcome: 'fixed' }))
    expect(reason(onlyBy)).toBe('a commit with no Fixed item')
    const noFixed = changed(d => (items(d)[0] = { id: 'PRRT_1', outcome: 'no-action' }))
    expect(reason(noFixed)).toBe('a commit with no Fixed item')
  })

  it('refuses a commit with failed checks', () => {
    expect(reason(changed(d => (d.checks = 'failed')))).toBe('a commit with failed checks')
    for (const checks of ['passed', 'blocked', 'none']) {
      expect(reason(changed(d => (d.checks = checks)))).toBe('valid')
    }
    // Failed checks with no commit: the result has no code fix.
    const noFix = changed(d => {
      items(d)[0] = { id: 'PRRT_1', outcome: 'needs-you', question: 'The tests fail. Go on?' }
      d.commit = null
      d.checks = 'failed'
    })
    expect(reason(noFix)).toBe('valid')
  })

  it('refuses a subject over MAX_SUBJECT', () => {
    const message = (text: unknown): Data => changed(d => (commit(d).message = text))
    expect(reason(message('x'.repeat(MAX_SUBJECT)))).toBe('valid')
    expect(reason(message(`${'x'.repeat(MAX_SUBJECT)}\n\nThe body.`))).toBe('valid')
    expect(reason(message('x'.repeat(MAX_SUBJECT + 1)))).toBe(
      'the first line of the commit message is longer than 100 characters',
    )
    expect(reason(message('\nfix: the limit'))).toBe(
      'the first line of the commit message is empty',
    )
    expect(reason(message('   '))).toBe('the first line of the commit message is empty')
    expect(reason(message(''))).toBe('the first line of the commit message is empty')
    expect(reason(message(`fix: x\n\n${'y'.repeat(MAX_MESSAGE)}`))).toBe(
      'the commit message is longer than 4,000 characters',
    )
    expect(reason(message('fix: x\n\n\tAn indented line.'))).toBe(
      'the commit message has a control character',
    )
    expect(reason(message('fix: x\u001b[31m'))).toBe('the commit message has a control character')
    expect(reason(message(['fix: x']))).toBe('the commit message is not text')
  })

  // Ruling S10: a fix goes out with no local install, so CI must run on the pushed commit.
  it('refuses a commit message that skips CI', () => {
    const message = (text: string): Data => changed(d => (commit(d).message = text))
    for (const text of [
      'fix: check the limit [skip ci]',
      'fix: check the limit\n\n[ci skip]',
      'fix: check the limit [no ci]',
      'fix: check the limit [skip actions]',
      'fix: check the limit [actions skip]',
      'fix: check the limit [SKIP CI]',
      'fix: check the limit [Skip  CI]',
      'fix: check the limit\n\nskip-checks: true',
      'fix: check the limit\n\nskip-checks:true',
      'fix: check the limit\n\nSkip-Checks: TRUE',
    ]) {
      expect(reason(message(text)), text).toBe('the commit message asks to skip CI')
    }
    for (const text of ['fix: skip the cache in CI', 'fix: no CI change', 'fix: skip-checks off']) {
      expect(reason(message(text)), text).toBe('valid')
    }
  })

  it('a reason never holds text from the file', () => {
    const cases: string[] = [
      `{"version": 1, "${SECRET}": `,
      JSON.stringify({ ...valid(), [SECRET]: 1 }),
      JSON.stringify(changed(d => Object.assign(items(d)[0] ?? {}, { [SECRET]: 1 }))),
      JSON.stringify(changed(d => Object.assign(commit(d), { [SECRET]: 1 }))),
      JSON.stringify(changed(d => (d.version = SECRET))),
      JSON.stringify(changed(d => (d.pr = SECRET))),
      JSON.stringify(changed(d => (d.headSha = SECRET))),
      JSON.stringify(changed(d => (items(d)[0] = { id: SECRET, outcome: 'fixed' }))),
      JSON.stringify(changed(d => (items(d)[0] = { id: 'PRRT_1', outcome: SECRET }))),
      JSON.stringify(changed(d => (items(d)[0] = { by: SECRET, id: 'PRRT_1', outcome: 'fixed' }))),
      JSON.stringify(
        changed(d => (items(d)[1] = { id: 'IC_2', outcome: 'no-fix', reply: `${SECRET}\u0007` })),
      ),
      JSON.stringify(
        changed(d => {
          items(d)[3] = { id: 'PRRT_4', outcome: 'needs-you', question: SECRET.repeat(100) }
        }),
      ),
      JSON.stringify(changed(d => (commit(d).message = `${SECRET.repeat(10)}`))),
      JSON.stringify(changed(d => (commit(d).message = `${SECRET}\u0007`))),
      JSON.stringify(changed(d => (commit(d).paths = [SECRET]))),
      JSON.stringify(changed(d => (commit(d).paths = [`../${SECRET}`]))),
      JSON.stringify(changed(d => (commit(d).paths = [`.git/${SECRET}`]))),
      JSON.stringify(changed(d => (d.checks = SECRET))),
      JSON.stringify(changed(d => (d.commit = SECRET))),
    ]
    for (const text of cases) {
      const out = reasonOf(text)
      expect(out, text).not.toBe('valid')
      expect(out).not.toContain(SECRET)
      expect(out).not.toContain('sk-ant')
    }
  })

  it('the result holds only the known fields', () => {
    const out = parseRequestResult(JSON.stringify(valid()), EXPECT)
    if (!out.ok) throw new Error(out.reason)
    expect(Object.keys(out.result).sort()).toEqual(
      ['checks', 'commit', 'headSha', 'items', 'pr', 'version'].sort(),
    )
    expect(Object.keys(out.result.commit ?? {}).sort()).toEqual(['message', 'paths'])
    expect(out.result.items.map(i => Object.keys(i).sort())).toEqual([
      ['id', 'outcome'],
      ['id', 'outcome', 'reply'],
      ['id', 'outcome'],
      ['id', 'outcome', 'question'],
    ])
  })
})
