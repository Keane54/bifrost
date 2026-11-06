import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { compareVersions } from '../../../src/main/claude/version'
import {
  createLiveControl,
  type LiveControlDeps,
  RELOAD_NOTE,
} from '../../../src/main/live/live-control'
import type { LiveServer, LiveServerState } from '../../../src/main/live/live-server'
import { MOD_FILES, modFolderCurrent } from '../../../src/main/live/mod-folder'
import type { MarketplaceEntry, PluginCli, PluginEntry } from '../../../src/main/live/plugin-cli'
import { LIVE_MIN_CLAUDE_VERSION } from '../../../src/shared/live'

let root: string
let source: string
let modDir: string

function put(base: string, rel: string, text: string): void {
  mkdirSync(dirname(join(base, rel)), { recursive: true })
  writeFileSync(join(base, rel), text)
}

// Put the four files in the mod folder. old gives text that is not the source text.
function fillModDir(old = false): void {
  for (const f of MOD_FILES) put(modDir, f, old ? `old ${f}` : `content of ${f}`)
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'bifrost-live-control-'))
  source = join(root, 'source')
  modDir = join(root, 'home', 'mod')
  for (const f of MOD_FILES) put(source, f, `content of ${f}`)
  vi.spyOn(console, 'warn').mockImplementation(() => {})
})
afterEach(() => {
  vi.restoreAllMocks()
  rmSync(root, { force: true, recursive: true })
})

interface World {
  plugin: PluginEntry | null
  marketplace: MarketplaceEntry | null
  pluginError?: string
  noCli?: boolean
  version: string | null
  old: { found: boolean; error?: string }
  removeOldError?: string
  serverState: LiveServerState
  serverError?: string
  forceListen?: boolean
  liveSessions?: number
  // plugin() waits for this promise when it is set.
  pluginGate?: Promise<void>
  // The fake call with this name waits at the gate.
  gate?: Gate
}

interface Gate {
  name: string
  reached(): void
  wait: Promise<void>
}

// A gate for one fake call. hit resolves when the call comes to the gate. open lets it go on.
function makeGate(name: string) {
  let open = (): void => {}
  let reached = (): void => {}
  const wait = new Promise<void>(resolve => {
    open = resolve
  })
  const hit = new Promise<void>(resolve => {
    reached = resolve
  })
  const gate: Gate = { name, reached, wait }
  return { gate, hit, open }
}

// The read calls. Each other call in calls changes something.
const READS = new Set(['plugin', 'marketplace', 'oldInstall'])

// A fake CLI, a fake server and fake deps. Each call goes into one calls list.
function setup(over: Partial<World> = {}) {
  const w: World = {
    marketplace: null,
    old: { found: false },
    plugin: null,
    serverState: { listening: false },
    version: '2.1.318',
    ...over,
  }
  const calls: string[] = []
  const seen: { modCurrentAtAdd?: boolean } = {}
  const label = (dir: string) => (dir === modDir ? '/m' : dir)
  const hold = async (name: string): Promise<void> => {
    if (w.gate?.name !== name) return
    w.gate.reached()
    await w.gate.wait
  }
  const cli: PluginCli = {
    async addMarketplace(dir) {
      calls.push(`addMarketplace ${label(dir)}`)
      seen.modCurrentAtAdd = await modFolderCurrent(source, modDir)
      w.marketplace = { path: dir, source: 'directory' }
    },
    async disable() {
      calls.push('disable')
      if (w.plugin) w.plugin = { ...w.plugin, enabled: false }
    },
    async enable() {
      calls.push('enable')
      await hold('enable')
      if (w.plugin) w.plugin = { ...w.plugin, enabled: true }
    },
    async install() {
      calls.push('install')
      await hold('install')
      w.plugin = { enabled: true, errors: [], folder: modDir }
    },
    async marketplace() {
      calls.push('marketplace')
      return w.marketplace
    },
    async plugin() {
      calls.push('plugin')
      if (w.pluginGate) await w.pluginGate
      if (w.pluginError) throw new Error(w.pluginError)
      return w.plugin
    },
    async removeMarketplace() {
      calls.push('removeMarketplace')
      w.marketplace = null
    },
    async uninstall() {
      calls.push('uninstall')
      w.plugin = null
    },
  }
  const server: LiveServer = {
    async start() {
      calls.push('server.start')
      w.serverState = w.serverError
        ? { error: w.serverError, listening: false }
        : { listening: true }
      return w.serverState
    },
    state: () => w.serverState,
    stop() {
      calls.push('server.stop')
      w.serverState = { listening: false }
    },
  }
  const deps: LiveControlDeps = {
    clearLive() {
      calls.push('clearLive')
    },
    cli: async () => (w.noCli ? null : cli),
    forceListen: w.forceListen ?? false,
    liveSessions: () => w.liveSessions ?? 0,
    modDir,
    modSource: source,
    async oldInstall() {
      calls.push('oldInstall')
      return w.old
    },
    async removeOldInstall() {
      calls.push('removeOldInstall')
      if (w.removeOldError) throw new Error(w.removeOldError)
      w.old = { found: false }
    },
    server,
    version: async () => ({
      minimum: LIVE_MIN_CLAUDE_VERSION,
      ok: w.version !== null && compareVersions(w.version, LIVE_MIN_CLAUDE_VERSION) >= 0,
      version: w.version,
    }),
  }
  const writes = () => calls.filter(c => !READS.has(c))
  return { calls, control: createLiveControl(deps), seen, w, writes }
}

describe('constants', () => {
  test('the minimum version and the reload note have the exact texts', () => {
    expect(LIVE_MIN_CLAUDE_VERSION).toBe('2.1.290')
    expect(RELOAD_NOTE).toBe(
      'Sessions that run now get the change after /reload-plugins or a restart.',
    )
  })
})

describe('install', () => {
  test('install removes an old hook install, copies the mod, adds the marketplace, installs and listens', async () => {
    const { calls, control, seen, writes } = setup({ old: { found: true } })
    const status = await control.install()
    expect(writes()).toEqual(['removeOldInstall', 'addMarketplace /m', 'install', 'server.start'])
    // The marketplace check comes before the first change.
    expect(calls.slice(0, calls.indexOf('server.start') + 1)).toEqual([
      'marketplace',
      'oldInstall',
      'removeOldInstall',
      'addMarketplace /m',
      'plugin',
      'install',
      'plugin',
      'server.start',
    ])
    expect(seen.modCurrentAtAdd).toBe(true)
    expect(status).toMatchObject({
      listening: true,
      modCurrent: true,
      oldInstall: false,
      plugin: 'enabled',
    })
  })

  test('install stops when the old hook removal fails', async () => {
    const { control, writes } = setup({ old: { found: true }, removeOldError: 'X' })
    await expect(control.install()).rejects.toThrow('X')
    expect(writes()).toEqual(['removeOldInstall'])
    expect(existsSync(modDir)).toBe(false)
  })

  test('install refuses a bifrost-local marketplace with another path', async () => {
    const { calls, control, writes } = setup({
      marketplace: { path: '/other', source: 'directory' },
      old: { found: true },
    })
    await expect(control.install()).rejects.toThrow(
      'A marketplace with the name bifrost-local already exists at /other. Bifrost did not change it.',
    )
    expect(writes()).toEqual([])
    expect(calls).not.toContain('oldInstall')
    expect(existsSync(modDir)).toBe(false)
  })

  test.each(['stop', 'disable'] as const)(
    'an install that ends after %s does not listen',
    async halt => {
      const g = makeGate('install')
      const { calls, control, w } = setup({ gate: g.gate })
      const installing = control.install()
      await g.hit
      if (halt === 'stop') control.stop()
      else await control.disable()
      g.open()
      await installing
      expect(calls).not.toContain('server.start')
      expect(w.serverState.listening).toBe(false)
    },
  )

  test('install names the source of a bifrost-local marketplace with no path', async () => {
    const { control } = setup({ marketplace: { source: 'github' } })
    await expect(control.install()).rejects.toThrow(
      'A marketplace with the name bifrost-local already exists at github. Bifrost did not change it.',
    )
  })

  test('install skips addMarketplace when bifrost-local has the mod path', async () => {
    const { control, writes } = setup({ marketplace: { path: modDir, source: 'directory' } })
    await control.install()
    expect(writes()).toEqual(['install', 'server.start'])
  })

  test('install turns on a plugin that is installed and off', async () => {
    const { control, writes } = setup({
      marketplace: { path: modDir, source: 'directory' },
      plugin: { enabled: false, errors: [], folder: modDir },
    })
    expect((await control.install()).plugin).toBe('enabled')
    expect(writes()).toEqual(['enable', 'server.start'])
  })

  test('install refuses Claude Code below 2.1.290', async () => {
    const { calls, control } = setup({ version: '2.1.289' })
    await expect(control.install()).rejects.toThrow(
      'Live details needs Claude Code 2.1.290 or later. This Mac has 2.1.289.',
    )
    expect(calls).toEqual([])
  })

  test('install refuses settings that Bifrost cannot read before any change', async () => {
    const { control, writes } = setup({ old: { error: 'E.', found: false } })
    await expect(control.install()).rejects.toThrow(
      "Bifrost can't read ~/.claude/settings.json, so it didn't change anything. E.",
    )
    expect(writes()).toEqual([])
    expect(existsSync(modDir)).toBe(false)
  })

  test('install refuses when claude was not found', async () => {
    const { calls, control } = setup({ noCli: true, version: null })
    await expect(control.install()).rejects.toThrow(
      'Live details needs Claude Code 2.1.290 or later. claude was not found.',
    )
    expect(calls).toEqual([])
  })
})

describe('enable', () => {
  test('enable rejects when the plugin is not installed', async () => {
    const { control, writes } = setup({ old: { found: true } })
    await expect(control.enable()).rejects.toThrow('Live details is not installed.')
    expect(writes()).toEqual([])
  })

  test('enable removes an old hook install, copies the mod, turns the plugin on and listens', async () => {
    fillModDir(true)
    const { control, writes } = setup({
      old: { found: true },
      plugin: { enabled: false, errors: [], folder: modDir },
    })
    const status = await control.enable()
    expect(writes()).toEqual(['removeOldInstall', 'enable', 'server.start'])
    expect(await modFolderCurrent(source, modDir)).toBe(true)
    expect(status).toMatchObject({ listening: true, oldInstall: false, plugin: 'enabled' })
  })

  test('enable stops when the old hook removal fails', async () => {
    const { control, writes } = setup({
      old: { found: true },
      plugin: { enabled: false, errors: [], folder: modDir },
      removeOldError: 'X',
    })
    await expect(control.enable()).rejects.toThrow('X')
    expect(writes()).toEqual(['removeOldInstall'])
  })

  test.each(['stop', 'disable'] as const)(
    'a Turn on that ends after %s does not listen',
    async halt => {
      const g = makeGate('enable')
      const { calls, control, w } = setup({
        gate: g.gate,
        plugin: { enabled: false, errors: [], folder: modDir },
      })
      const enabling = control.enable()
      await g.hit
      if (halt === 'stop') control.stop()
      else await control.disable()
      g.open()
      await enabling
      expect(calls).not.toContain('server.start')
      expect(w.serverState.listening).toBe(false)
    },
  )

  test('enable refuses settings that Bifrost cannot read before any change', async () => {
    fillModDir(true)
    const { control, writes } = setup({
      old: { error: 'E.', found: false },
      plugin: { enabled: false, errors: [], folder: modDir },
    })
    await expect(control.enable()).rejects.toThrow(
      "Bifrost can't read ~/.claude/settings.json, so it didn't change anything. E.",
    )
    expect(writes()).toEqual([])
    expect(await modFolderCurrent(source, modDir)).toBe(false)
  })

  test('enable refuses Claude Code below 2.1.290', async () => {
    const { calls, control } = setup({
      plugin: { enabled: false, errors: [] },
      version: '2.1.289',
    })
    await expect(control.enable()).rejects.toThrow(
      'Live details needs Claude Code 2.1.290 or later. This Mac has 2.1.289.',
    )
    expect(calls).toEqual([])
  })
})

describe('disable and uninstall', () => {
  test('disable runs plugin disable and stops the server', async () => {
    const { control, writes } = setup({
      plugin: { enabled: true, errors: [], folder: modDir },
      serverState: { listening: true },
    })
    const status = await control.disable()
    expect(writes()).toEqual(['server.stop', 'clearLive', 'disable'])
    expect(status).toMatchObject({ listening: false, plugin: 'disabled' })
  })

  test('a disable with a failing CLI stops the server and rejects', async () => {
    const failing = setup({ pluginError: 'boom', serverState: { listening: true } })
    await expect(failing.control.disable()).rejects.toThrow('boom')
    expect(failing.w.serverState.listening).toBe(false)
    expect(failing.writes()).toEqual(['server.stop', 'clearLive'])
    const missing = setup({ noCli: true, serverState: { listening: true } })
    await expect(missing.control.disable()).rejects.toThrow('claude was not found.')
    expect(missing.w.serverState.listening).toBe(false)
  })

  test('disable with no plugin only stops the server', async () => {
    const { control, writes } = setup({ serverState: { listening: true } })
    expect((await control.disable()).listening).toBe(false)
    expect(writes()).toEqual(['server.stop', 'clearLive'])
  })

  test('uninstall stops the server, removes the plugin, the marketplace, the mod folder and the old install', async () => {
    fillModDir()
    const { control, writes } = setup({
      marketplace: { path: modDir, source: 'directory' },
      old: { found: true },
      plugin: { enabled: true, errors: [], folder: modDir },
      serverState: { listening: true },
    })
    const status = await control.uninstall()
    expect(writes()).toEqual([
      'server.stop',
      'clearLive',
      'uninstall',
      'removeMarketplace',
      'removeOldInstall',
    ])
    expect(existsSync(modDir)).toBe(false)
    expect(status).toMatchObject({
      listening: false,
      modCurrent: false,
      oldInstall: false,
      plugin: 'not-installed',
    })
  })

  test('uninstall with settings that Bifrost cannot read removes the plugin and then rejects', async () => {
    fillModDir()
    const { control, writes } = setup({
      marketplace: { path: modDir, source: 'directory' },
      old: { error: 'E.', found: false },
      plugin: { enabled: true, errors: [], folder: modDir },
      serverState: { listening: true },
    })
    await expect(control.uninstall()).rejects.toThrow(
      "Bifrost can't read ~/.claude/settings.json, so it didn't remove the old hooks. E.",
    )
    expect(writes()).toEqual(['server.stop', 'clearLive', 'uninstall', 'removeMarketplace'])
    expect(existsSync(modDir)).toBe(false)
  })

  test('uninstall leaves a bifrost-local marketplace with another path', async () => {
    fillModDir()
    const { control, w, writes } = setup({
      marketplace: { path: '/other', source: 'directory' },
      plugin: { enabled: true, errors: [], folder: '/other' },
    })
    await control.uninstall()
    expect(writes()).toEqual(['server.stop', 'clearLive', 'uninstall'])
    expect(w.marketplace).toEqual({ path: '/other', source: 'directory' })
    expect(existsSync(modDir)).toBe(false)
  })
})

describe('start', () => {
  test('start listens for an enabled plugin and copies an old mod folder again', async () => {
    fillModDir(true)
    const { calls, control } = setup({ plugin: { enabled: true, errors: [], folder: modDir } })
    await control.start()
    expect(calls).toContain('server.start')
    expect(await modFolderCurrent(source, modDir)).toBe(true)
  })

  test('start listens when the CLI fails and the mod folder exists', async () => {
    fillModDir()
    const failing = setup({ pluginError: 'boom' })
    await failing.control.start()
    expect(failing.calls).toContain('server.start')
    const missing = setup({ noCli: true })
    await missing.control.start()
    expect(missing.calls).toContain('server.start')
    expect(console.warn).toHaveBeenCalled()
  })

  test('start does not listen when the CLI fails and the mod folder is missing', async () => {
    const { calls, control } = setup({ pluginError: 'boom' })
    await control.start()
    expect(calls).not.toContain('server.start')
  })

  test('start does not listen for a disabled plugin', async () => {
    fillModDir()
    const off = setup({ plugin: { enabled: false, errors: [], folder: modDir } })
    await off.control.start()
    expect(off.calls).not.toContain('server.start')
    const none = setup()
    await none.control.start()
    expect(none.calls).not.toContain('server.start')
  })

  test('start listens with forceListen whatever the plugin state', async () => {
    const none = setup({ forceListen: true })
    await none.control.start()
    expect(none.calls).toContain('server.start')
    const off = setup({ forceListen: true, plugin: { enabled: false, errors: [] } })
    await off.control.start()
    expect(off.calls).toContain('server.start')
  })

  test('start never rejects and warns when the server gives an error', async () => {
    const { control } = setup({
      plugin: { enabled: true, errors: [], folder: modDir },
      serverError: 'Another program listens on /x.',
    })
    await expect(control.start()).resolves.toBeUndefined()
    expect(console.warn).toHaveBeenCalled()
  })

  test('a stop during start keeps the server closed', async () => {
    let open = (): void => {}
    const gate = new Promise<void>(resolve => {
      open = resolve
    })
    const { calls, control } = setup({
      plugin: { enabled: true, errors: [], folder: modDir },
      pluginGate: gate,
    })
    const started = control.start()
    await vi.waitFor(() => expect(calls).toContain('plugin'))
    control.stop()
    open()
    await started
    expect(calls).toEqual(['plugin', 'server.stop'])
  })

  test('an action waits until start ends', async () => {
    let open = (): void => {}
    const gate = new Promise<void>(resolve => {
      open = resolve
    })
    const { calls, control, w } = setup({
      plugin: { enabled: true, errors: [], folder: modDir },
      pluginGate: gate,
    })
    const started = control.start()
    const disabled = control.disable()
    await vi.waitFor(() => expect(calls).toContain('plugin'))
    w.pluginGate = undefined
    open()
    await Promise.all([started, disabled])
    const order = calls.filter(c => c === 'server.start' || c === 'server.stop')
    expect(order).toEqual(['server.start', 'server.stop'])
    expect(w.serverState.listening).toBe(false)
  })
})

describe('status', () => {
  test('status gives each field', async () => {
    fillModDir()
    const { control } = setup({
      liveSessions: 2,
      plugin: { enabled: true, errors: [], folder: modDir },
      serverState: { listening: true },
      version: '2.1.318',
    })
    expect(await control.status()).toEqual({
      claudeVersion: '2.1.318',
      listening: true,
      liveSessions: 2,
      modCurrent: true,
      oldInstall: false,
      plugin: 'enabled',
      versionOk: true,
    })
  })

  test('status gives modCurrent false when the plugin reads another folder', async () => {
    fillModDir()
    const { control } = setup({ plugin: { enabled: true, errors: [], folder: '/other' } })
    expect((await control.status()).modCurrent).toBe(false)
  })

  test('status gives unknown and the message when plugin list fails', async () => {
    fillModDir()
    const failed = "Bifrost couldn't read the plugin list from Claude Code: boom"
    const { control } = setup({ pluginError: failed })
    const status = await control.status()
    expect(status.plugin).toBe('unknown')
    expect(status.error).toBe(failed)
    expect(status.modCurrent).toBe(true)
  })

  test('status joins several errors with a space', async () => {
    const { control } = setup({
      old: { error: 'B.', found: false },
      pluginError: 'A.',
      serverState: { error: 'C.', listening: false },
    })
    expect((await control.status()).error).toBe('A. B. C.')
  })

  test('status gives unknown when claude was not found', async () => {
    const { control } = setup({ noCli: true, version: null })
    expect(await control.status()).toMatchObject({
      claudeVersion: null,
      error: 'claude was not found.',
      plugin: 'unknown',
      versionOk: false,
    })
  })
})
