import { describe, expect, it } from 'vitest'
import { isPlainObject, isRecord } from '../../src/shared/plain-object'

describe('isRecord', () => {
  it('accepts objects and refuses null and arrays', () => {
    expect(isRecord({})).toBe(true)
    expect(isRecord(Object.create(null))).toBe(true)
    for (const bad of [null, [], 'x', 1, undefined]) expect(isRecord(bad)).toBe(false)
  })

  it('accepts a class instance, unlike isPlainObject', () => {
    class Box {}
    expect(isRecord(new Box())).toBe(true)
    expect(isPlainObject(new Box())).toBe(false)
  })
})
