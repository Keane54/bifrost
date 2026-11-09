import { describe, expect, it } from 'vitest'
import {
  addIgnore,
  REASON_IGNORE_BAD,
  REASON_IGNORE_COPY,
  REASON_IGNORE_FULL,
  removeIgnore,
} from '../../../src/renderer/src/settings/reviews-ignore'
import { MAX_REVIEWS_IGNORE } from '../../../src/shared/settings'

describe('addIgnore', () => {
  it('appends a trimmed lower-case entry', () => {
    expect(addIgnore(['a/b'], ' Acme/Web ')).toEqual({ list: ['a/b', 'acme/web'], ok: true })
    expect(addIgnore([], 'acme/*')).toEqual({ list: ['acme/*'], ok: true })
  })

  it('refuses a bad entry with a friendly reason', () => {
    expect(REASON_IGNORE_BAD).toBe('Use owner/repo or owner/*.')
    for (const bad of ['', 'acme', 'acme/', '/web', 'a/b/c', '*/web']) {
      expect(addIgnore([], bad), bad).toEqual({ ok: false, reason: REASON_IGNORE_BAD })
    }
  })

  it('refuses a copy and a full list', () => {
    expect(addIgnore(['acme/web'], 'ACME/web')).toEqual({ ok: false, reason: REASON_IGNORE_COPY })
    const full = Array.from({ length: MAX_REVIEWS_IGNORE }, (_, i) => `o/r${i}`)
    expect(addIgnore(full, 'o/new')).toEqual({ ok: false, reason: REASON_IGNORE_FULL })
  })
})

describe('removeIgnore', () => {
  it('removes one entry, and keeps the list for a bad index', () => {
    expect(removeIgnore(['a/b', 'c/d'], 0)).toEqual(['c/d'])
    const list = ['a/b']
    expect(removeIgnore(list, 3)).toBe(list)
  })
})
