import { expect, test, vi } from 'vitest'
import { PageScope } from '../../../src/main/pty/page-scope'

test('end closes all PTYs each time', () => {
  const closeAll = vi.fn()
  const page = new PageScope(closeAll)
  page.end()
  page.end()
  expect(closeAll).toHaveBeenCalledTimes(2)
})

test('a token stays current until the page ends', () => {
  const page = new PageScope(() => {})
  const token = page.token()
  expect(page.isCurrent(token)).toBe(true)
  page.end()
  expect(page.isCurrent(token)).toBe(false)
  expect(page.isCurrent(page.token())).toBe(true)
})

test('an open that waits across a reload sees that its page is gone', async () => {
  // The order of events in pty:open when a reload occurs during the wait.
  const page = new PageScope(() => {})
  const token = page.token()
  let release = (): void => {}
  const wait = new Promise<void>(r => (release = r))
  const open = wait.then(() => page.isCurrent(token))
  page.end()
  release()
  expect(await open).toBe(false)
})
