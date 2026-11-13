import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from 'node:fs'
import { tmpdir, userInfo } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  findOnPath,
  type PathCheck,
  pluginEnv,
  recordTestPaths,
  refusedTestHome,
  TEST_HEADLESS_ENV,
  TEST_HOME_ENV,
  testHeadless,
  testHomeConfig,
  testHomeError,
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
    expect(refusedTestHome({}, REAL_HOME)).toBeNull()
    expect(refusedTestHome(env(undefined), REAL_HOME)).toBeNull()
  })

  // A variable that is set but empty must not use the real home by mistake.
  it('refusedTestHome refuses an empty value', () => {
    expect(refusedTestHome(env(''), REAL_HOME)).toBe('')
    expect(testHomeError('')).toBe(
      "Bifrost can't use the test home (empty). Use an absolute folder that isn't /, your home folder or a parent of it.",
    )
    expect(testHomeError('/Users')).toBe(
      "Bifrost can't use the test home /Users. Use an absolute folder that isn't /, your home folder or a parent of it.",
    )
  })

  it('testHomeConfig compares the paths without case on darwin', () => {
    const noLinks = (platform: NodeJS.Platform): PathCheck => ({ platform, realpath: () => null })
    for (const bad of ['/USERS/O', '/users/O/', '/USERS']) {
      expect(testHomeConfig(env(bad), REAL_HOME, noLinks('darwin')), bad).toBeNull()
      expect(refusedTestHome(env(bad), REAL_HOME, noLinks('darwin')), bad).toBe(bad)
    }
    // Another platform compares the case.
    expect(testHomeConfig(env('/USERS/O'), REAL_HOME, noLinks('linux'))).toEqual({
      home: '/USERS/O',
      userData: '/USERS/O/user-data',
    })
    // A child folder of the real home in another case is still accepted.
    expect(testHomeConfig(env('/USERS/O/tmp/t'), REAL_HOME, noLinks('darwin'))).toEqual({
      home: '/USERS/O/tmp/t',
      userData: '/USERS/O/tmp/t/user-data',
    })
  })

  it('testHomeConfig refuses a symbolic link to the real home or to a parent of it', () => {
    const dir = mkdtempSync(join(tmpdir(), 'bifrost-th-'))
    try {
      const home = join(dir, 'home')
      const other = join(dir, 'other')
      mkdirSync(home)
      mkdirSync(other)
      symlinkSync(home, join(dir, 'link'))
      symlinkSync(dir, join(dir, 'up'))
      expect(testHomeConfig(env(join(dir, 'link')), home)).toBeNull()
      expect(refusedTestHome(env(join(dir, 'link')), home)).toBe(join(dir, 'link'))
      expect(testHomeConfig(env(join(dir, 'up')), home)).toBeNull()
      // A real home that is a link gives the same result.
      expect(testHomeConfig(env(home), join(dir, 'link'))).toBeNull()
      // A real folder beside the home is accepted, with the path as given.
      expect(testHomeConfig(env(other), home)).toEqual({
        home: other,
        userData: join(other, 'user-data'),
      })
    } finally {
      rmSync(dir, { force: true, recursive: true })
    }
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

  it('uses the variable BIFROST_TEST_HEADLESS for a test home with no window', () => {
    expect(TEST_HEADLESS_ENV).toBe('BIFROST_TEST_HEADLESS')
  })

  it('testHeadless is true only with a test home and the value 1', () => {
    const home = { home: '/tmp/bh', userData: '/tmp/bh/user-data' }
    expect(testHeadless({ BIFROST_TEST_HEADLESS: '1' }, home)).toBe(true)
    // A normal start never hides its window, also with the variable.
    expect(testHeadless({ BIFROST_TEST_HEADLESS: '1' }, null)).toBe(false)
    // Without the value 1, a test home shows its window as before.
    for (const value of [undefined, '', '0', 'true', 'yes', ' 1']) {
      expect(testHeadless({ BIFROST_TEST_HEADLESS: value }, home), String(value)).toBe(false)
    }
    expect(testHeadless({}, home)).toBe(false)
  })

  // A smoke test sets HOME to the test home (user decision, 2026-11-13). So the real home is the
  // home folder in the user database, and HOME does not change it.
  describe('the real home is the home folder in the user database', () => {
    const passwdHome = userInfo().homedir
    const testDir = '/tmp/bifrost-th-home'
    afterEach(() => {
      vi.unstubAllEnvs()
    })

    it('testHomeConfig accepts a test home that is also HOME', () => {
      vi.stubEnv('HOME', testDir)
      expect(testHomeConfig(env(testDir))).toEqual({
        home: testDir,
        userData: `${testDir}/user-data`,
      })
      expect(refusedTestHome(env(testDir))).toBeNull()
    })

    it('testHomeConfig refuses the real home and its parent when HOME is another folder', () => {
      vi.stubEnv('HOME', testDir)
      for (const bad of [passwdHome, dirname(passwdHome)]) {
        expect(testHomeConfig(env(bad)), bad).toBeNull()
        expect(refusedTestHome(env(bad)), bad).toBe(bad)
      }
    })
  })

  it('index.ts reads the test home with the real home of the user database', () => {
    const source = readFileSync(join(__dirname, '../../src/main/index.ts'), 'utf8')
    expect(source).toContain('testHomeConfig(process.env)')
    expect(source).toContain('refusedTestHome(process.env)')
    expect(source).not.toContain('homedir()')
  })

  it('recordTestPaths gives the paths to a smoke test only in a test home', () => {
    const paths = {
      bifrostHome: '/tmp/bh/.bifrost',
      claudeJson: '/tmp/bh/.claude.json',
      claudeSettings: '/tmp/bh/.claude/settings.json',
    }
    try {
      recordTestPaths(null, paths)
      expect('bifrostTestPaths' in globalThis).toBe(false)
      recordTestPaths({ home: '/tmp/bh', userData: '/tmp/bh/user-data' }, paths)
      expect((globalThis as { bifrostTestPaths?: unknown }).bifrostTestPaths).toEqual(paths)
    } finally {
      Reflect.deleteProperty(globalThis, 'bifrostTestPaths')
    }
  })

  it('index.ts moves the logs folder into the test home', () => {
    const source = readFileSync(join(__dirname, '../../src/main/index.ts'), 'utf8')
    const block = source.slice(source.indexOf('if (testHome) {'))
    const end = block.indexOf('\n}\n')
    expect(block.slice(0, end)).toContain("app.setAppLogsPath(join(testHome.home, 'logs'))")
  })
})
