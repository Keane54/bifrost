// A test of the launch options of the smoke tests (test/smoke/app.ts). It starts no app.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { launchOptions } from '../smoke/app.ts'

describe('the launch env of a smoke test', () => {
  afterEach(() => vi.unstubAllEnvs())

  it('hides the window by default (user decision, 2026-11-13)', async () => {
    vi.stubEnv('BIFROST_SMOKE_HEADED', undefined)
    const { env } = await launchOptions('/tmp/bh')
    expect(env?.BIFROST_TEST_HOME).toBe('/tmp/bh')
    expect(env?.BIFROST_TEST_HEADLESS).toBe('1')
  })

  it('BIFROST_SMOKE_HEADED=1 shows the window as before', async () => {
    vi.stubEnv('BIFROST_SMOKE_HEADED', '1')
    const { env } = await launchOptions('/tmp/bh')
    expect(env?.BIFROST_TEST_HOME).toBe('/tmp/bh')
    expect(env).not.toHaveProperty('BIFROST_TEST_HEADLESS')
    // The app does not read the variable of the test runner.
    expect(env).not.toHaveProperty('BIFROST_SMOKE_HEADED')
  })

  it('another value of BIFROST_SMOKE_HEADED keeps the window hidden', async () => {
    for (const value of ['', '0', 'true']) {
      vi.stubEnv('BIFROST_SMOKE_HEADED', value)
      const { env } = await launchOptions('/tmp/bh')
      expect(env?.BIFROST_TEST_HEADLESS, value).toBe('1')
    }
  })

  it('a packaged app gets the same env', async () => {
    vi.stubEnv('BIFROST_SMOKE_HEADED', undefined)
    vi.stubEnv('BIFROST_SMOKE_APP', '/tmp/Bifrost.app')
    const { env, executablePath } = await launchOptions('/tmp/bh')
    expect(executablePath).toBe('/tmp/Bifrost.app/Contents/MacOS/Bifrost')
    expect(env?.BIFROST_TEST_HEADLESS).toBe('1')
  })
})
