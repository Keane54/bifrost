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

test('a call that comes during runFirst waits for it, and then runs', async () => {
  const runner = createSerialRunner()
  const first = gate<void>()
  const order: string[] = []
  const starting = runner.runFirst(async () => {
    await first.promise
    order.push('first')
  })
  const two = runner.run(async () => {
    order.push('two')
    return 'two'
  })
  await new Promise(resolve => setTimeout(resolve, 10))
  expect(order).toEqual([])
  first.open()
  await expect(two).resolves.toBe('two')
  await starting
  expect(order).toEqual(['first', 'two'])
})

test('a call after a failed runFirst still runs', async () => {
  const runner = createSerialRunner()
  const first = gate<void>()
  const starting = runner.runFirst(async () => {
    await first.promise
    throw new Error('start failed')
  })
  const two = runner.run(async () => 'two')
  first.open()
  await expect(starting).rejects.toThrow('start failed')
  await expect(two).resolves.toBe('two')
})

test('of two calls that wait for runFirst, the first runs and the second rejects', async () => {
  const runner = createSerialRunner()
  const first = gate<void>()
  const later = gate<string>()
  void runner.runFirst(() => first.promise)
  const one = runner.run(() => later.promise)
  const two = runner.run(async () => 'two')
  first.open()
  await expect(two).rejects.toThrow(BUSY_MESSAGE)
  later.open('one')
  await expect(one).resolves.toBe('one')
})

test('the busy message is the text that the renderer shows', () => {
  expect(BUSY_MESSAGE).toBe('Another integration action runs now.')
})
