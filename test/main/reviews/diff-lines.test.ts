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

describe('parseDiff edge cases', () => {
  it('reads a hunk header with no count on the right side', () => {
    const f = parseDiff('diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -3,2 +7 @@\n-a\n-b\n+c\n')
    expect(f[0]?.hunks).toEqual([{ leftEnd: 4, leftStart: 3, rightEnd: 7, rightStart: 7 }])
  })

  it('a pure rename has no hunks and uses the new path', () => {
    const text =
      'diff --git a/old.md b/new.md\nsimilarity index 100%\nrename from old.md\nrename to new.md\n'
    expect(parseDiff(text)).toEqual([{ binary: false, hunks: [], path: 'new.md' }])
  })

  it('reads an unquoted path with spaces and a trailing tab', () => {
    const text =
      'diff --git a/my dir/a b.md b/my dir/a b.md\n--- a/my dir/a b.md\t\n+++ b/my dir/a b.md\t\n@@ -1 +1 @@\n-a\n+b\n'
    expect(parseDiff(text)[0]?.path).toBe('my dir/a b.md')
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

  it('supports a start side and refuses an equal or reversed range', () => {
    expect(lineInDiff(files, 'src/limit.ts', 'RIGHT', 12, 11, 'LEFT')).toBe(true)
    expect(lineInDiff(files, 'src/limit.ts', 'RIGHT', 12, 32, 'RIGHT')).toBe(false)
    expect(lineInDiff(files, 'src/limit.ts', 'RIGHT', 33, 11, 'LEFT')).toBe(false)
    expect(lineInDiff(files, 'src/limit.ts', 'RIGHT', 12, 12)).toBe(false)
    expect(lineInDiff(files, 'src/limit.ts', 'RIGHT', 11, 12)).toBe(false)
  })
})
