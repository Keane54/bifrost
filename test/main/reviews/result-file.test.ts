import { readFileSync } from 'node:fs'
import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { parseDiff } from '../../../src/main/reviews/diff-lines'
import {
  MAX_COMMENT_BODY,
  MAX_COMMENTS,
  MAX_RESULT_BYTES,
  MAX_SUMMARY,
  MAX_WHY,
  parseReviewResult,
  placeComments,
  RESULT_VERSION,
  type ReviewResult,
  readResultFile,
} from '../../../src/main/reviews/result-file'

const sample = readFileSync(new URL('../../fixtures/reviews/sample.diff', import.meta.url), 'utf8')
const files = parseDiff(sample)
const HEAD = 'a'.repeat(40)
const PR = 'acme/api#7'
const expected = { files, headSha: HEAD, pr: PR }
const SECRET = 'sk-ant-secret'

const comment = (extra: Record<string, unknown> = {}): Record<string, unknown> => ({
  body: 'With `<=`, a client gets one request more than its limit.',
  line: 12,
  path: 'src/limit.ts',
  side: 'RIGHT',
  ...extra,
})

const valid = (extra: Record<string, unknown> = {}): Record<string, unknown> => ({
  comments: [comment()],
  headSha: HEAD,
  pr: PR,
  recommendation: 'request-changes',
  summary: 'One bug blocks this.',
  version: 1,
  why: 'The limit check is off by one.',
  ...extra,
})

const parse = (value: unknown) => parseReviewResult(JSON.stringify(value), expected)
const reasonOf = (out: ReturnType<typeof parseReviewResult>): string => (out.ok ? 'ok' : out.reason)
const reason = (value: unknown): string => reasonOf(parse(value))

describe('the limits', () => {
  it('have the values of the plan', () => {
    expect([RESULT_VERSION, MAX_RESULT_BYTES, MAX_COMMENTS, MAX_COMMENT_BODY]).toEqual([
      1,
      1024 * 1024,
      50,
      10_000,
    ])
    expect([MAX_SUMMARY, MAX_WHY]).toEqual([20_000, 300])
  })
})

describe('parseReviewResult', () => {
  it('accepts a valid result', () => {
    const out = parse(valid())
    expect(out.ok).toBe(true)
    if (!out.ok) return
    expect(out.result).toStrictEqual({
      comments: [
        {
          body: 'With `<=`, a client gets one request more than its limit.',
          line: 12,
          path: 'src/limit.ts',
          side: 'RIGHT',
        },
      ],
      headSha: HEAD,
      pr: PR,
      recommendation: 'request-changes',
      summary: 'One bug blocks this.',
      version: 1,
      why: 'The limit check is off by one.',
    })
    // A range, a deleted line, a quoted path, an Approve with a summary only, and an Approve
    // with nothing.
    const range = comment({ line: 13, startLine: 11, startSide: 'RIGHT' })
    const deleted = comment({ line: 1, path: 'src/gone.ts', side: 'LEFT' })
    const quoted = comment({ line: 2, path: 'docs/café menu.md' })
    const out2 = parse(valid({ comments: [range, deleted, quoted] }))
    expect(out2.ok && out2.result.comments).toStrictEqual([range, deleted, quoted])
    expect(
      reason(valid({ comments: [], recommendation: 'approve', summary: 'A minor point.' })),
    ).toBe('ok')
    expect(reason(valid({ comments: [], recommendation: 'approve', summary: '' }))).toBe('ok')
    expect(reason(valid({ comments: [], recommendation: 'comment' }))).toBe('ok')
    expect(reason(valid({ recommendation: 'comment', summary: '' }))).toBe('ok')
  })

  it('gives an empty summary for a summary with only white space', () => {
    const out = parse(valid({ summary: ' \n\t ' }))
    expect(out.ok && out.result.summary).toBe('')
  })

  it('refuses bad JSON, a missing field and an unknown field', () => {
    expect(reasonOf(parseReviewResult('{', expected))).toBe('the result is not valid JSON')
    expect(reasonOf(parseReviewResult('', expected))).toBe('the result is not valid JSON')
    expect(reasonOf(parseReviewResult('[]', expected))).toBe('the result is not a JSON object')
    expect(reasonOf(parseReviewResult('null', expected))).toBe('the result is not a JSON object')
    expect(reasonOf(parseReviewResult('"text"', expected))).toBe('the result is not a JSON object')
    for (const field of [
      'version',
      'pr',
      'headSha',
      'recommendation',
      'why',
      'summary',
      'comments',
    ]) {
      const value = valid()
      delete value[field]
      expect(reason(value)).toBe(`the ${field} field is missing`)
    }
    expect(reason(valid({ extra: 1 }))).toBe('an unknown field')
    const withProto = `{"__proto__": 1, ${JSON.stringify(valid()).slice(1)}`
    expect(reasonOf(parseReviewResult(withProto, expected))).toBe('an unknown field')
    expect(reason(valid({ comments: [comment({ extra: 1 })] }))).toBe('an unknown field')
    expect(reason(valid({ comments: [comment(), comment({ path: undefined })] }))).toBe(
      'comment 2 has no path field',
    )
    for (const field of ['line', 'side', 'body']) {
      expect(reason(valid({ comments: [comment({ [field]: undefined })] }))).toBe(
        `comment 1 has no ${field} field`,
      )
    }
    expect(reason(valid({ comments: [5] }))).toBe('comment 1 is not a JSON object')
    expect(reason(valid({ comments: [[]] }))).toBe('comment 1 is not a JSON object')
    expect(reason(valid({ comments: {} }))).toBe('the comments field is not a list')
    expect(reason(valid({ version: 2 }))).toBe('the version field is not 1')
    expect(reason(valid({ version: '1' }))).toBe('the version field is not 1')
    expect(reason(valid({ why: 5 }))).toBe('the why field is not text')
    expect(reason(valid({ summary: null }))).toBe('the summary field is not text')
    expect(reason(valid({ comments: [comment({ body: 5 })] }))).toBe(
      'the body of comment 1 is not text',
    )
  })

  it('refuses another PR or another head', () => {
    expect(reason(valid({ pr: 'acme/api#8' }))).toBe('the pr field is not this pull request')
    expect(reason(valid({ pr: 7 }))).toBe('the pr field is not this pull request')
    expect(reason(valid({ headSha: 'b'.repeat(40) }))).toBe(
      'the headSha field is not the reviewed commit',
    )
    expect(reason(valid({ headSha: HEAD.toUpperCase() }))).toBe(
      'the headSha field is not the reviewed commit',
    )
    expect(reason(valid({ recommendation: 'Approve' }))).toBe(
      'the recommendation field is not approve, comment or request-changes',
    )
  })

  it('refuses a path that is not in the diff, and a binary file', () => {
    expect(reason(valid({ comments: [comment({ path: 'src/other.ts' })] }))).toBe(
      'comment 1 is on a file that is not in the diff',
    )
    // A renamed file has only its new path.
    expect(reason(valid({ comments: [comment({ line: 2, path: 'docs/old.md' })] }))).toBe(
      'comment 1 is on a file that is not in the diff',
    )
    expect(reason(valid({ comments: [comment({ path: 5 })] }))).toBe(
      'comment 1 is on a file that is not in the diff',
    )
    expect(reason(valid({ comments: [comment({ line: 1, path: 'assets/logo.png' })] }))).toBe(
      'comment 1 is on a binary file',
    )
  })

  it('refuses a line that is not a whole number of 1 or more', () => {
    for (const line of [0, -1, 1.5, '12', null, Number.MAX_SAFE_INTEGER + 1]) {
      expect(reason(valid({ comments: [comment({ line })] }))).toBe(
        'the line of comment 1 is not a whole number of 1 or more',
      )
    }
    for (const startLine of [0, 1.5, '11', null]) {
      expect(reason(valid({ comments: [comment({ startLine })] }))).toBe(
        'the startLine of comment 1 is not a whole number of 1 or more',
      )
    }
    expect(reason(valid({ comments: [comment({ side: 'right' })] }))).toBe(
      'the side of comment 1 is not LEFT or RIGHT',
    )
  })

  it('refuses a start line that is not below the line, and a start side that differs', () => {
    expect(reason(valid({ comments: [comment({ startLine: 12 })] }))).toBe(
      'the startLine of comment 1 is not below its line',
    )
    expect(reason(valid({ comments: [comment({ startLine: 13 })] }))).toBe(
      'the startLine of comment 1 is not below its line',
    )
    expect(reason(valid({ comments: [comment({ startLine: 11, startSide: 'LEFT' })] }))).toBe(
      'the startSide of comment 1 is not its side',
    )
    expect(reason(valid({ comments: [comment({ startLine: 11, startSide: null })] }))).toBe(
      'the startSide of comment 1 is not its side',
    )
    expect(reason(valid({ comments: [comment({ startSide: 'RIGHT' })] }))).toBe(
      'comment 1 has a startSide with no startLine',
    )
  })

  it('refuses an Approve with comments and a Request changes with no text', () => {
    expect(reason(valid({ recommendation: 'approve' }))).toBe(
      'an Approve recommendation has line comments',
    )
    expect(reason(valid({ comments: [], summary: '' }))).toBe(
      'a Request changes recommendation has no text',
    )
    expect(reason(valid({ comments: [], recommendation: 'comment', summary: ' \n ' }))).toBe(
      'a Comment recommendation has no text',
    )
  })

  it('refuses an empty why and a why over the limit', () => {
    expect(reason(valid({ why: '' }))).toBe('the why field is empty')
    expect(reason(valid({ why: '  \n' }))).toBe('the why field is empty')
    expect(reason(valid({ why: 'x'.repeat(MAX_WHY) }))).toBe('ok')
    expect(reason(valid({ why: 'x'.repeat(MAX_WHY + 1) }))).toBe(
      'the why field is longer than 300 characters',
    )
  })

  it('refuses more than MAX_COMMENTS comments and a body over the limit', () => {
    const many = Array.from({ length: MAX_COMMENTS }, () => comment())
    expect(reason(valid({ comments: many }))).toBe('ok')
    expect(reason(valid({ comments: [...many, comment()] }))).toBe(
      'the comments field has more than 50 comments',
    )
    expect(reason(valid({ comments: [comment({ body: 'x'.repeat(MAX_COMMENT_BODY) })] }))).toBe(
      'ok',
    )
    expect(reason(valid({ comments: [comment({ body: 'x'.repeat(MAX_COMMENT_BODY + 1) })] }))).toBe(
      'the body of comment 1 is longer than 10,000 characters',
    )
    expect(reason(valid({ comments: [comment({ body: ' \n' })] }))).toBe(
      'the body of comment 1 is empty',
    )
    expect(reason(valid({ summary: 'x'.repeat(MAX_SUMMARY) }))).toBe('ok')
    expect(reason(valid({ summary: 'x'.repeat(MAX_SUMMARY + 1) }))).toBe(
      'the summary field is longer than 20,000 characters',
    )
  })

  it('a reason never holds text from the file', () => {
    const long = (n: number): string => `${SECRET} ${'x'.repeat(n)}`
    const bad: string[] = [
      `{${SECRET}`,
      `{"${SECRET}": 1}`,
      `"${SECRET}"`,
      JSON.stringify({ ...valid(), [SECRET]: SECRET }),
      JSON.stringify(valid({ comments: [comment({ [SECRET]: SECRET })] })),
      JSON.stringify(valid({ version: SECRET })),
      JSON.stringify(valid({ pr: SECRET })),
      JSON.stringify(valid({ headSha: SECRET })),
      JSON.stringify(valid({ recommendation: SECRET })),
      JSON.stringify(valid({ why: long(MAX_WHY) })),
      JSON.stringify(valid({ summary: long(MAX_SUMMARY) })),
      JSON.stringify(valid({ comments: SECRET })),
      JSON.stringify(valid({ comments: [SECRET] })),
      JSON.stringify(valid({ comments: [comment({ path: SECRET })] })),
      JSON.stringify(valid({ comments: [comment({ line: SECRET })] })),
      JSON.stringify(valid({ comments: [comment({ side: SECRET })] })),
      JSON.stringify(valid({ comments: [comment({ startLine: SECRET })] })),
      JSON.stringify(valid({ comments: [comment({ startLine: 11, startSide: SECRET })] })),
      JSON.stringify(valid({ comments: [comment({ body: long(MAX_COMMENT_BODY) })] })),
      JSON.stringify(valid({ recommendation: 'approve', summary: SECRET })),
    ]
    for (const text of bad) {
      const out = parseReviewResult(text, expected)
      expect(out.ok).toBe(false)
      expect(reasonOf(out)).not.toContain('sk-ant')
    }
  })
})

describe('readResultFile', () => {
  let base: string

  beforeAll(async () => {
    base = await mkdtemp(join(tmpdir(), 'bifrost-result-file-'))
  })

  afterAll(async () => {
    await rm(base, { force: true, recursive: true })
  })

  it('reads a regular file', async () => {
    const file = join(base, 'result.json')
    await writeFile(file, '{"a": 1}\n')
    expect(await readResultFile(file)).toEqual({ ok: true, text: '{"a": 1}\n' })
  })

  it('readResultFile refuses a link and a file over MAX_RESULT_BYTES', async () => {
    const target = join(base, 'target.json')
    await writeFile(target, '{}')
    const link = join(base, 'link.json')
    await symlink(target, link)
    expect(await readResultFile(link)).toEqual({ ok: false, reason: 'not a regular file' })
    const folder = join(base, 'folder.json')
    await mkdir(folder)
    expect(await readResultFile(folder)).toEqual({ ok: false, reason: 'not a regular file' })
    expect(await readResultFile(join(base, 'none.json'))).toEqual({
      ok: false,
      reason: 'missing',
    })
    const atLimit = join(base, 'at-limit.json')
    await writeFile(atLimit, 'x'.repeat(MAX_RESULT_BYTES))
    expect((await readResultFile(atLimit)).ok).toBe(true)
    const big = join(base, 'big.json')
    await writeFile(big, 'x'.repeat(MAX_RESULT_BYTES + 1))
    expect(await readResultFile(big)).toEqual({ ok: false, reason: 'too large' })
  })
})

describe('placeComments', () => {
  const result = (extra: Partial<ReviewResult> = {}): ReviewResult => ({
    comments: [],
    headSha: HEAD,
    pr: PR,
    recommendation: 'request-changes',
    summary: 'One bug blocks this.',
    version: 1,
    why: 'The limit check is off by one.',
    ...extra,
  })

  it('placeComments moves a comment outside the hunks into the summary', () => {
    const inside = { body: 'Inside.', line: 12, path: 'src/limit.ts', side: 'RIGHT' } as const
    const deleted = { body: 'Deleted.', line: 2, path: 'src/gone.ts', side: 'LEFT' } as const
    const outside = { body: 'Outside.', line: 20, path: 'src/limit.ts', side: 'RIGHT' } as const
    // The range starts outside the hunk of its line.
    const range = {
      body: 'Range.',
      line: 33,
      path: 'src/limit.ts',
      side: 'RIGHT',
      startLine: 12,
      startSide: 'RIGHT',
    } as const
    const out = placeComments(result({ comments: [inside, outside, deleted, range] }), files)
    expect(out.comments).toStrictEqual([inside, deleted])
    expect(out.moved).toBe(2)
    expect(out.summary).toBe(
      'One bug blocks this.\n\n`src/limit.ts` line 20: Outside.\n\n`src/limit.ts` line 33: Range.',
    )
  })

  it('starts the summary with the first moved comment when the summary is empty', () => {
    const outside = { body: 'Outside.', line: 20, path: 'src/limit.ts', side: 'RIGHT' } as const
    const out = placeComments(result({ comments: [outside], summary: '' }), files)
    expect(out).toStrictEqual({
      comments: [],
      moved: 1,
      summary: '`src/limit.ts` line 20: Outside.',
    })
  })

  it('keeps the summary as it is when no comment moves', () => {
    const inside = { body: 'Inside.', line: 12, path: 'src/limit.ts', side: 'RIGHT' } as const
    const out = placeComments(result({ comments: [inside] }), files)
    expect(out).toStrictEqual({ comments: [inside], moved: 0, summary: 'One bug blocks this.' })
  })
})
