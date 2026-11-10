import { expect, test } from 'vitest'
import { createSerialRunner } from '../../../src/main/integration/serial'
import { BUSY_MESSAGE } from '../../../src/shared/live'

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

test('afterFirst with no runFirst runs at once', async () => {
  const runner = createSerialRunner()
  await expect(runner.afterFirst(async () => 'read')).resolves.toBe('read')
})

test('afterFirst waits for runFirst, and then runs', async () => {
  const runner = createSerialRunner()
  const first = gate<void>()
  const order: string[] = []
  const starting = runner.runFirst(async () => {
    await first.promise
    order.push('first')
  })
  const read = runner.afterFirst(async () => {
    order.push('read')
    return 'read'
  })
  await new Promise(resolve => setTimeout(resolve, 10))
  expect(order).toEqual([])
  first.open()
  await expect(read).resolves.toBe('read')
  await starting
  expect(order).toEqual(['first', 'read'])
})

test('afterFirst runs after a failed runFirst', async () => {
  const runner = createSerialRunner()
  const first = gate<void>()
  const starting = runner.runFirst(async () => {
    await first.promise
    throw new Error('start failed')
  })
  const read = runner.afterFirst(async () => 'read')
  first.open()
  await expect(starting).rejects.toThrow('start failed')
  await expect(read).resolves.toBe('read')
})

test('afterFirst takes no lock: it runs during a run, and a run runs during it', async () => {
  const runner = createSerialRunner()
  const action = gate<string>()
  const reading = gate<string>()
  const one = runner.run(() => action.promise)
  await expect(runner.afterFirst(async () => 'read')).resolves.toBe('read')
  action.open('one')
  await expect(one).resolves.toBe('one')
  const read = runner.afterFirst(() => reading.promise)
  await expect(runner.run(async () => 'two')).resolves.toBe('two')
  reading.open('read')
  await expect(read).resolves.toBe('read')
})

test('the busy message is the text that the renderer shows', () => {
  expect(BUSY_MESSAGE).toBe('Another change is still running. Try again in a moment.')
})
