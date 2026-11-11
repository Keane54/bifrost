import { describe, expect, test, vi } from 'vitest'
import { friendlyFailure } from '../../../src/main/reviews/friendly-failure'

describe('friendlyFailure', () => {
  test('gives the result of a working call', async () => {
    await expect(friendlyFailure(async () => 7, 'Fixed.', vi.fn())).resolves.toBe(7)
  })

  test('passes a refusal on as it is', async () => {
    const log = vi.fn()
    const call = async (): Promise<void> => {
      throw new Error('refused: reviews are busy')
    }
    await expect(friendlyFailure(call, 'Fixed.', log)).rejects.toThrow('refused: reviews are busy')
    expect(log).not.toHaveBeenCalled()
  })

  test('replaces any other error with the fixed text and logs a fixed text only', async () => {
    const log = vi.fn()
    const call = async (): Promise<void> => {
      throw new Error("EACCES: permission denied, rm '/Users/x/repos/y'")
    }
    await expect(friendlyFailure(call, 'Fixed.', log)).rejects.toThrow(/^Fixed\.$/)
    expect(log).toHaveBeenCalledTimes(1)
    expect(String(log.mock.calls[0]?.[0])).not.toContain('/Users')
  })
})
