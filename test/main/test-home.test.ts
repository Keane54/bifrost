import { describe, expect, it } from 'vitest'
import {
  findOnPath,
  pluginEnv,
  refusedTestHome,
  TEST_HOME_ENV,
  testHomeConfig,
} from '../../src/main/test-home'

const REAL_HOME = '/Users/o'
const env = (value: string | undefined): Record<string, string | undefined> => ({
  [TEST_HOME_ENV]: value,
})

describe('test home', () => {
  it('uses the variable BIFROST_TEST_HOME', () => {
    expect(TEST_HOME_ENV).toBe('BIFROST_TEST_HOME')
  })

  it('testHomeConfig gives the home and the userData directory', () => {
    expect(testHomeConfig(env('/tmp/bh'), REAL_HOME)).toEqual({
      home: '/tmp/bh',
      userData: '/tmp/bh/user-data',
    })
    // The value is normalised.
    expect(testHomeConfig(env('/tmp//bh/x/../'), REAL_HOME)).toEqual({
      home: '/tmp/bh',
      userData: '/tmp/bh/user-data',
    })
  })

  it('testHomeConfig gives null with no value', () => {
    expect(testHomeConfig({}, REAL_HOME)).toBeNull()
    expect(testHomeConfig(env(undefined), REAL_HOME)).toBeNull()
    expect(testHomeConfig(env(''), REAL_HOME)).toBeNull()
  })

  it('testHomeConfig refuses a relative path, /, the real home and a parent of the real home', () => {
    for (const bad of ['x', 'tmp/bh', './bh', '/', '//', '/Users/o', '/Users/o/', '/Users']) {
      expect(testHomeConfig(env(bad), REAL_HOME), bad).toBeNull()
    }
    // A path that only looks like the real home after normalisation is refused too.
    expect(testHomeConfig(env('/Users/o/tmp/..'), REAL_HOME)).toBeNull()
    // A folder that starts with the same letters is not a parent.
    expect(testHomeConfig(env('/Users/ol'), REAL_HOME)).toEqual({
      home: '/Users/ol',
      userData: '/Users/ol/user-data',
    })
    expect(testHomeConfig(env('/Users/o/tmp/t'), REAL_HOME)).toEqual({
      home: '/Users/o/tmp/t',
      userData: '/Users/o/tmp/t/user-data',
    })
  })

  it('refusedTestHome gives a value that testHomeConfig refuses, so Bifrost does not start', () => {
    for (const bad of ['x', '/', '/Users/o', '/Users']) {
      expect(refusedTestHome(env(bad), REAL_HOME), bad).toBe(bad)
    }
    expect(refusedTestHome(env('/tmp/bh'), REAL_HOME)).toBeNull()
    expect(refusedTestHome(env(undefined), REAL_HOME)).toBeNull()
    expect(refusedTestHome(env(''), REAL_HOME)).toBeNull()
  })

  it('findOnPath gives the first executable on the PATH', () => {
    const executables = new Set(['/b/claude', '/c/claude', 'rel/claude'])
    const isExecutable = (path: string): boolean => executables.has(path)
    expect(findOnPath('claude', '/a:/b', isExecutable)).toBe('/b/claude')
    expect(findOnPath('claude', '/a:/c:/b', isExecutable)).toBe('/c/claude')
    // A relative directory and an empty part are skipped.
    expect(findOnPath('claude', 'rel::/b', isExecutable)).toBe('/b/claude')
    expect(findOnPath('claude', 'rel', isExecutable)).toBeNull()
    // No match gives null.
    expect(findOnPath('claude', '/a:/d', isExecutable)).toBeNull()
    expect(findOnPath('claude', '', isExecutable)).toBeNull()
    expect(findOnPath('claude', undefined, isExecutable)).toBeNull()
  })

  it('pluginEnv gives the test home to plugin commands only', () => {
    const base = { CLAUDE_CONFIG_DIR: '/Users/o/.claude', HOME: '/Users/o', PATH: '/usr/bin' }
    const copy = { ...base }
    expect(pluginEnv(base, null)).toBe(base)
    const env = pluginEnv(base, { home: '/tmp/bh', userData: '/tmp/bh/user-data' })
    expect(env).toEqual({
      CLAUDE_CONFIG_DIR: '/tmp/bh/.claude',
      HOME: '/tmp/bh',
      PATH: '/usr/bin',
    })
    expect(env).not.toBe(base)
    // base does not change.
    expect(base).toEqual(copy)
    // A base without the two keys gets them.
    expect(pluginEnv({ PATH: '/bin' }, { home: '/tmp/bh', userData: '/tmp/bh/user-data' })).toEqual(
      { CLAUDE_CONFIG_DIR: '/tmp/bh/.claude', HOME: '/tmp/bh', PATH: '/bin' },
    )
  })
})
