import { describe, expect, it } from 'vitest'
import { addSlash, moveSlash, removeSlash } from '../../../src/renderer/src/settings/slash-list'
import { checkSlashCommand } from '../../../src/shared/settings'

describe('addSlash', () => {
  it('appends a trimmed command', () => {
    expect(addSlash(['/a'], ' /b ')).toEqual({ list: ['/a', '/b'], ok: true })
  })

  it('refuses a copy, a bad command and a full list', () => {
    expect(addSlash(['/a'], '/a')).toEqual({
      ok: false,
      reason: 'That command is already in the list.',
    })
    const bad = checkSlashCommand('b')
    expect(bad.ok).toBe(false)
    expect(addSlash(['/a'], 'b')).toEqual({
      ok: false,
      reason: bad.ok ? '' : bad.reason,
    })
    const full = Array.from({ length: 12 }, (_, i) => `/c${i}`)
    expect(addSlash(full, '/new')).toEqual({
      ok: false,
      reason: 'You can keep up to 12 commands.',
    })
  })
})

describe('removeSlash and moveSlash', () => {
  it('change the order and keep the array at an edge', () => {
    const list = ['/a', '/b', '/c']
    expect(removeSlash(list, 1)).toEqual(['/a', '/c'])
    expect(removeSlash(list, 3)).toBe(list)
    expect(removeSlash(list, -1)).toBe(list)
    expect(moveSlash(list, 1, -1)).toEqual(['/b', '/a', '/c'])
    expect(moveSlash(list, 1, 1)).toEqual(['/a', '/c', '/b'])
    expect(moveSlash(list, 0, -1)).toBe(list)
    expect(moveSlash(list, 2, 1)).toBe(list)
    expect(moveSlash(list, 5, -1)).toBe(list)
  })
})
