import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import type { MarketplaceEntry, PluginCli, PluginEntry } from '../../../src/main/live/plugin-cli'
import { createSkillsControl } from '../../../src/main/skills/skills-control'
import { skillsFolderCurrent, syncSkillsFolder } from '../../../src/main/skills/skills-folder'

let root: string
let source: string
let dir: string

function put(base: string, rel: string, text: string): void {
  mkdirSync(dirname(join(base, rel)), { recursive: true })
  writeFileSync(join(base, rel), text)
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'bifrost-skills-control-'))
  source = join(root, 'source')
  dir = join(root, 'home', 'skills')
  put(source, '.claude-plugin/plugin.json', '{"name":"bifrost"}')
  put(
    source,
    'skills/bifrost-a/SKILL.md',
    '---\nname: bifrost-a\ndescription: About a.\ndisable-model-invocation: false\n---\n\nBody\n',
  )
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
  // install() leaves the plugin off.
  installOff?: boolean
}

function setup(over: Partial<World> = {}) {
  const w: World = { marketplace: null, plugin: null, ...over }
  const calls: string[] = []
  const label = (d: string) => (d === dir ? '/d' : d)
  const cli: PluginCli = {
    async addMarketplace(d) {
      calls.push(`addMarketplace ${label(d)}`)
      w.marketplace = { path: d, source: 'directory' }
    },
    async disable() {
      calls.push('disable')
      if (w.plugin) w.plugin = { ...w.plugin, enabled: false }
    },
    async enable() {
      calls.push('enable')
      if (w.plugin) w.plugin = { ...w.plugin, enabled: true }
    },
    async install() {
      calls.push('install')
      w.plugin = { enabled: !w.installOff, errors: [], folder: dir }
    },
    async marketplace() {
      calls.push('marketplace')
      return w.marketplace
    },
    async plugin() {
      calls.push('plugin')
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
  const control = createSkillsControl({
    cli: async () => (w.noCli ? null : cli),
    dir,
    source,
  })
  const writes = (): string[] => calls.filter(c => c !== 'plugin' && c !== 'marketplace')
  return { calls, control, w, writes }
}

const on: PluginEntry = { enabled: true, errors: [] }
const off: PluginEntry = { enabled: false, errors: [] }

describe('install', () => {
  test('rejects with no claude, before any change', async () => {
    const { control } = setup({ noCli: true })
    await expect(control.install()).rejects.toThrow('claude was not found.')
    expect(existsSync(dir)).toBe(false)
  })
  test('syncs the folder, adds the marketplace and installs the plugin', async () => {
    const { control, writes } = setup()
    const status = await control.install()
    expect(writes()).toEqual(['addMarketplace /d', 'install'])
    expect(await skillsFolderCurrent(source, dir)).toBe(true)
    expect(status.plugin).toBe('enabled')
    expect(status.folderCurrent).toBe(true)
    expect(status.skills.map(s => s.name)).toEqual(['bifrost-a'])
  })
  test('does not add a marketplace that exists at the folder', async () => {
    const { control, writes } = setup({ marketplace: { path: dir, source: 'directory' } })
    await control.install()
    expect(writes()).toEqual(['install'])
  })
  test('turns on a plugin that is off, and does not install it again', async () => {
    const { control, writes } = setup({
      marketplace: { path: dir, source: 'directory' },
      plugin: off,
    })
    const status = await control.install()
    expect(writes()).toEqual(['enable'])
    expect(status.plugin).toBe('enabled')
  })
  test('a plugin that is on needs no command, but the folder is synced', async () => {
    const { control, writes } = setup({
      marketplace: { path: dir, source: 'directory' },
      plugin: on,
    })
    await control.install()
    expect(writes()).toEqual([])
    expect(await skillsFolderCurrent(source, dir)).toBe(true)
  })
  test('refuses a marketplace at another path, and writes nothing (Review Focus 5)', async () => {
    const { control, writes } = setup({ marketplace: { path: '/other', source: 'directory' } })
    await expect(control.install()).rejects.toThrow(
      'A marketplace with the name bifrost-skills already exists at /other. ' +
        'Bifrost did not change it.',
    )
    expect(writes()).toEqual([])
    expect(existsSync(dir)).toBe(false)
  })
  test('refuses a marketplace with no path and names its source', async () => {
    const { control, writes } = setup({ marketplace: { source: 'github:x/y' } })
    await expect(control.install()).rejects.toThrow(
      'A marketplace with the name bifrost-skills already exists at github:x/y. ' +
        'Bifrost did not change it.',
    )
    expect(writes()).toEqual([])
    expect(existsSync(dir)).toBe(false)
  })
})

describe('enable', () => {
  test('rejects when the plugin is not installed, and writes nothing', async () => {
    const { control, writes } = setup()
    await expect(control.enable()).rejects.toThrow('Bifrost skills are not installed.')
    expect(writes()).toEqual([])
    expect(existsSync(dir)).toBe(false)
  })
  test('syncs the folder and turns the plugin on', async () => {
    const { control, writes } = setup({ plugin: off })
    await syncSkillsFolder(source, dir)
    put(dir, 'extra.txt', 'x')
    const status = await control.enable()
    expect(writes()).toEqual(['enable'])
    expect(await skillsFolderCurrent(source, dir)).toBe(true)
    expect(status.plugin).toBe('enabled')
  })
  test('rejects with no claude', async () => {
    await expect(setup({ noCli: true }).control.enable()).rejects.toThrow('claude was not found.')
  })
})

describe('disable', () => {
  test('turns off an installed plugin', async () => {
    const { control, writes } = setup({ plugin: on })
    const status = await control.disable()
    expect(writes()).toEqual(['disable'])
    expect(status.plugin).toBe('disabled')
  })
  test('runs no command when the plugin is not installed', async () => {
    const { control, writes } = setup()
    await control.disable()
    expect(writes()).toEqual([])
  })
})

describe('uninstall', () => {
  test('removes the plugin, the marketplace of the folder and the folder', async () => {
    const { control, writes } = setup({
      marketplace: { path: `${dir}/`, source: 'directory' },
      plugin: on,
    })
    await syncSkillsFolder(source, dir)
    const status = await control.uninstall()
    expect(writes()).toEqual(['uninstall', 'removeMarketplace'])
    expect(existsSync(dir)).toBe(false)
    expect(status.plugin).toBe('not-installed')
  })
  test('refuses a marketplace at another path, keeps it and its folder (Review Focus 5)', async () => {
    const other = join(root, 'other')
    put(other, 'keep.txt', 'mine')
    await syncSkillsFolder(source, dir)
    const { control, writes } = setup({
      marketplace: { path: other, source: 'directory' },
      plugin: on,
    })
    await expect(control.uninstall()).rejects.toThrow(`already exists at ${other}. Bifrost did`)
    expect(writes()).toEqual([])
    expect(existsSync(join(other, 'keep.txt'))).toBe(true)
    expect(await skillsFolderCurrent(source, dir)).toBe(true)
  })
  test('refuses a marketplace with no path', async () => {
    const { control, writes } = setup({ marketplace: { source: 'github:x/y' }, plugin: on })
    await expect(control.uninstall()).rejects.toThrow('already exists at github:x/y.')
    expect(writes()).toEqual([])
  })
  test('runs no uninstall when the plugin is not installed', async () => {
    const { control, writes } = setup()
    await control.uninstall()
    expect(writes()).toEqual([])
  })
})

describe('start', () => {
  test('syncs an old folder when the plugin is on', async () => {
    const { control } = setup({ plugin: on })
    put(dir, 'old.txt', 'old')
    await control.start()
    expect(await skillsFolderCurrent(source, dir)).toBe(true)
  })
  test('syncs a missing folder when the plugin is off', async () => {
    const { control, writes } = setup({ plugin: off })
    await control.start()
    expect(await skillsFolderCurrent(source, dir)).toBe(true)
    expect(writes()).toEqual([])
  })
  test('writes nothing and does not warn for a foreign marketplace with a plugin', async () => {
    const { control, writes } = setup({
      marketplace: { path: '/other', source: 'directory' },
      plugin: on,
    })
    await control.start()
    expect(writes()).toEqual([])
    expect(existsSync(dir)).toBe(false)
    expect(console.warn).not.toHaveBeenCalled()
  })
  test('writes nothing when the plugin is not installed', async () => {
    const { control } = setup()
    await control.start()
    expect(existsSync(dir)).toBe(false)
  })
  test('writes nothing and warns once when the CLI fails', async () => {
    const { control } = setup({ plugin: on, pluginError: 'boom' })
    await expect(control.start()).resolves.toBeUndefined()
    expect(existsSync(dir)).toBe(false)
    expect(console.warn).toHaveBeenCalledTimes(1)
  })
  test('writes nothing and does not reject with no claude', async () => {
    const { control } = setup({ noCli: true })
    await expect(control.start()).resolves.toBeUndefined()
    expect(existsSync(dir)).toBe(false)
  })
  test('does not reject when the sync fails', async () => {
    const { control } = setup({ plugin: on })
    rmSync(source, { force: true, recursive: true })
    await expect(control.start()).resolves.toBeUndefined()
    expect(console.warn).toHaveBeenCalledTimes(1)
  })
})

describe('status', () => {
  test('not installed: the skills come from the app folder', async () => {
    const status = await setup().control.status()
    expect(status).toEqual({
      folderCurrent: false,
      plugin: 'not-installed',
      skills: [{ description: 'About a.', group: 'listed', name: 'bifrost-a' }],
    })
  })
  test('shows enabled and disabled', async () => {
    expect((await setup({ plugin: on }).control.status()).plugin).toBe('enabled')
    expect((await setup({ plugin: off }).control.status()).plugin).toBe('disabled')
  })
  test('is unknown with the error when the list fails', async () => {
    const status = await setup({ pluginError: 'boom' }).control.status()
    expect(status.plugin).toBe('unknown')
    expect(status.error).toBe('boom')
  })
  test('is unknown when claude is missing', async () => {
    const status = await setup({ noCli: true }).control.status()
    expect(status.plugin).toBe('unknown')
    expect(status.error).toBe('claude was not found.')
  })
  test('a failed skill read gives an empty list and adds to the error', async () => {
    const { control } = setup({ pluginError: 'boom' })
    rmSync(join(source, 'skills'), { force: true, recursive: true })
    const status = await control.status()
    expect(status.skills).toEqual([])
    expect(status.error).toMatch(/^boom /)
    expect(status.error).toMatch(/skills/)
  })
})

describe('a foreign marketplace bifrost-skills', () => {
  const foreign = { path: '/other', source: 'directory' }
  test.each(['enable', 'disable'] as const)('%s refuses and makes no change', async name => {
    const { control, writes } = setup({ marketplace: foreign, plugin: on })
    await expect(control[name]()).rejects.toThrow(
      'A marketplace with the name bifrost-skills already exists at /other. ' +
        'Bifrost did not change it.',
    )
    expect(writes()).toEqual([])
    expect(existsSync(dir)).toBe(false)
  })
  test('status reports the foreign marketplace as its error', async () => {
    const { control } = setup({ marketplace: foreign, plugin: on })
    const status = await control.status()
    expect(status.error).toBe(
      'A marketplace with the name bifrost-skills already exists at /other. ' +
        'Bifrost did not change it.',
    )
  })
  test('status has no foreign error for an own or missing marketplace', async () => {
    expect((await setup({ plugin: on }).control.status()).error).toBeUndefined()
  })
})

describe('more install and status rules', () => {
  test('an install that leaves the plugin off reads it again and turns it on', async () => {
    const { control, writes } = setup({ installOff: true })
    const status = await control.install()
    expect(writes()).toEqual(['addMarketplace /d', 'install', 'enable'])
    expect(status.plugin).toBe('enabled')
  })
  test('the folder is synced before the marketplace is added', async () => {
    const { calls, control } = setup()
    const cli = await (async () => {
      let seen: boolean | undefined
      return { get: () => seen, set: (v: boolean) => (seen = v) }
    })()
    const original = calls.push.bind(calls)
    calls.push = (...items: string[]) => {
      if (items[0]?.startsWith('addMarketplace')) {
        cli.set(existsSync(join(dir, '.claude-plugin', 'plugin.json')))
      }
      return original(...items)
    }
    await control.install()
    expect(cli.get()).toBe(true)
  })
  test('folderCurrent is false when the plugin reads another folder', async () => {
    await syncSkillsFolder(source, dir)
    const status = await setup({
      plugin: { enabled: true, errors: [], folder: join(root, 'other') },
    }).control.status()
    expect(status.folderCurrent).toBe(false)
    const same = await setup({
      plugin: { enabled: true, errors: [], folder: dir },
    }).control.status()
    expect(same.folderCurrent).toBe(true)
  })
})
