import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { lineInDiff, parseDiff } from '../../../src/main/reviews/diff-lines'

const sample = readFileSync(new URL('../../fixtures/reviews/sample.diff', import.meta.url), 'utf8')
const files = parseDiff(sample)
const byPath = (path: string) => files.find(f => f.path === path)

describe('parseDiff', () => {
  it('reads the hunks of each side', () => {
    expect(byPath('src/limit.ts')?.hunks).toEqual([
      { leftEnd: 13, leftStart: 10, rightEnd: 14, rightStart: 10 },
      { leftEnd: 29, leftStart: 30, rightEnd: 33, rightStart: 32 },
    ])
  })

  it('a binary file has no hunks', () => {
    expect(byPath('assets/logo.png')).toEqual({ binary: true, hunks: [], path: 'assets/logo.png' })
  })

  it('a renamed file uses the new path and a deleted file uses the old path', () => {
    expect(byPath('docs/new.md')?.hunks).toHaveLength(1)
    expect(byPath('docs/old.md')).toBeUndefined()
    expect(byPath('src/gone.ts')?.hunks).toEqual([
      { leftEnd: 2, leftStart: 1, rightEnd: -1, rightStart: 0 },
    ])
  })

  it('unquotes a quoted path', () => {
    expect(byPath('docs/café menu.md')?.hunks).toEqual([
      { leftEnd: 1, leftStart: 1, rightEnd: 2, rightStart: 1 },
    ])
  })
})

describe('lineInDiff', () => {
  it('needs both lines of a range in one hunk', () => {
    expect(lineInDiff(files, 'src/limit.ts', 'RIGHT', 12)).toBe(true)
    expect(lineInDiff(files, 'src/limit.ts', 'RIGHT', 15)).toBe(false)
    expect(lineInDiff(files, 'src/limit.ts', 'LEFT', 13)).toBe(true)
    expect(lineInDiff(files, 'src/limit.ts', 'RIGHT', 12, 10)).toBe(true)
    expect(lineInDiff(files, 'src/limit.ts', 'RIGHT', 33, 14)).toBe(false)
    expect(lineInDiff(files, 'src/limit.ts', 'RIGHT', 33, 32)).toBe(true)
    expect(lineInDiff(files, 'src/limit.ts', 'LEFT', 30)).toBe(false)
    expect(lineInDiff(files, 'nothing.ts', 'RIGHT', 1)).toBe(false)
    expect(lineInDiff(files, 'assets/logo.png', 'RIGHT', 1)).toBe(false)
  })
})
