import { expect, test } from 'vitest'
import { BUSY_MESSAGE, createSerialRunner } from '../../../src/main/integration/serial'

// Return a promise and the function that resolves it.
function gate<T>(): { promise: Promise<T>; open: (value: T) => void } {
  let open: (value: T) => void = () => {}
  const promise = new Promise<T>(resolve => {
    open = resolve
  })
  return { open, promise }
}

test('a second call during a call rejects, and the first call resolves', async () => {
  const runner = createSerialRunner()
  const first = gate<string>()
  const one = runner.run(() => first.promise)
  let secondRan = false
  const two = runner.run(async () => {
    secondRan = true
    return 'two'
  })
  await expect(two).rejects.toThrow(BUSY_MESSAGE)
  expect(secondRan).toBe(false)
  first.open('one')
  await expect(one).resolves.toBe('one')
})

test('a new call runs after the first call ends', async () => {
  const runner = createSerialRunner()
  const first = gate<string>()
  const one = runner.run(() => first.promise)
  first.open('one')
  await one
  await expect(runner.run(async () => 'next')).resolves.toBe('next')
})

test('a failed call ends the lock and keeps its error', async () => {
  const runner = createSerialRunner()
  await expect(
    runner.run(async () => {
      throw new Error('bad settings')
    }),
  ).rejects.toThrow('bad settings')
  await expect(runner.run(async () => 'next')).resolves.toBe('next')
})

test('the busy message is the text that the renderer shows', () => {
  expect(BUSY_MESSAGE).toBe('Another integration action runs now.')
})
