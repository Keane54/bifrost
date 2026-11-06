import { describe, expect, test } from 'vitest'
import { isUuid } from '../../src/shared/uuid'

describe('isUuid', () => {
  test('isUuid accepts a UUID and refuses other values', () => {
    expect(isUuid('73b5ca76-a4a8-4f97-9764-e41657296414')).toBe(true)
    expect(isUuid('73b5ca76')).toBe(false)
    expect(isUuid('')).toBe(false)
    expect(isUuid(1)).toBe(false)
    expect(isUuid(null)).toBe(false)
  })
})
