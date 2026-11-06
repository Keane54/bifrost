// Install, Turn on, Turn off and Remove of Live details, and the start rule (D9, D10, D11).
//
// Bifrost listens on the socket only while the plugin is on. Turn off stops the server at once.
// Install, Turn on and Remove also remove an old hook install. A failed removal stops
// Install and Turn on before any plugin command.

import { access } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import type { ClaudeVersion, LivePluginState, LiveStatus } from '../../shared/types'
import type { LiveServer } from './live-server'
import { modFolderCurrent, removeModFolder, syncModFolder } from './mod-folder'
import { MARKETPLACE_NAME, type PluginCli, type PluginEntry } from './plugin-cli'

export const LIVE_MIN_CLAUDE_VERSION = '2.1.290'
export const RELOAD_NOTE =
  'Sessions that run now get the change after /reload-plugins or a restart.'

// The text for a missing claude. The version message and the actions use it.
const NOT_FOUND = 'claude was not found.'

export interface LiveControlDeps {
  cli(): Promise<PluginCli | null>
  version(): Promise<ClaudeVersion>
  server: LiveServer
  modSource: string
  modDir: string
  oldInstall(): Promise<{ found: boolean; error?: string }>
  removeOldInstall(): Promise<void>
  liveSessions(): number
  forceListen: boolean
}

export interface LiveControl {
  start(): Promise<void>
  status(): Promise<LiveStatus>
  install(): Promise<LiveStatus>
  enable(): Promise<LiveStatus>
  disable(): Promise<LiveStatus>
  uninstall(): Promise<LiveStatus>
  stop(): void
}

function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

function samePath(a: string, b: string): boolean {
  return resolve(a) === resolve(b)
}

export function createLiveControl(deps: LiveControlDeps): LiveControl {
  const { modDir, modSource, server } = deps
  // stop() adds 1. A start that sees a new number must not start the server.
  let generation = 0
  // Each action waits for the start first. Then an action and the start never overlap.
  let starting: Promise<void> = Promise.resolve()

  async function needCli(): Promise<PluginCli> {
    const cli = await deps.cli()
    if (cli === null) throw new Error(NOT_FOUND)
    return cli
  }

  async function checkVersion(): Promise<void> {
    const v = await deps.version()
    if (v.ok) return
    const found = v.version === null ? NOT_FOUND : `This Mac has ${v.version}.`
    throw new Error(`Live details needs Claude Code ${LIVE_MIN_CLAUDE_VERSION} or later. ${found}`)
  }

  // A failed removal rejects. Then the action stops here.
  async function removeOldInstall(): Promise<void> {
    if ((await deps.oldInstall()).found) await deps.removeOldInstall()
  }

  async function readPlugin(): Promise<{
    state: LivePluginState
    entry: PluginEntry | null
    error?: string
  }> {
    try {
      const cli = await deps.cli()
      if (cli === null) return { entry: null, error: NOT_FOUND, state: 'unknown' }
      const entry = await cli.plugin()
      if (entry === null) return { entry, state: 'not-installed' }
      return { entry, state: entry.enabled ? 'enabled' : 'disabled' }
    } catch (err) {
      return { entry: null, error: messageOf(err), state: 'unknown' }
    }
  }

  async function status(): Promise<LiveStatus> {
    const [plugin, folderCurrent, old, version] = await Promise.all([
      readPlugin(),
      modFolderCurrent(modSource, modDir),
      deps.oldInstall().catch(err => ({ error: messageOf(err), found: false })),
      deps.version().catch(err => ({
        error: messageOf(err),
        minimum: LIVE_MIN_CLAUDE_VERSION,
        ok: false,
        version: null,
      })),
    ])
    const server = deps.server.state()
    const folder = plugin.entry?.folder
    const errors = [plugin.error, old.error, server.error, 'error' in version && version.error]
    const error = errors.filter((e): e is string => typeof e === 'string' && e !== '').join(' ')
    const result: LiveStatus = {
      claudeVersion: version.version,
      listening: server.listening,
      liveSessions: deps.liveSessions(),
      modCurrent: folderCurrent && (folder === undefined || samePath(folder, modDir)),
      oldInstall: old.found,
      plugin: plugin.state,
      versionOk: version.ok,
    }
    if (error !== '') result.error = error
    return result
  }

  async function listen(gen: number): Promise<void> {
    if (gen !== generation) return
    const state = await server.start()
    if (state.error) console.warn('Live details: the server did not start.', state.error)
  }

  // The start rule (D9). Each failure goes to console.warn.
  async function boot(gen: number): Promise<void> {
    if (deps.forceListen) return listen(gen)
    let entry: PluginEntry | null
    try {
      entry = await needCli().then(cli => cli.plugin())
    } catch (err) {
      // The plugin state is unknown. Listen when the mod folder exists.
      console.warn('Live details: Bifrost could not read the plugin list.', messageOf(err))
      const manifest = join(modDir, '.claude-plugin', 'plugin.json')
      const exists = await access(manifest).then(
        () => true,
        () => false,
      )
      if (exists) await listen(gen)
      return
    }
    if (!entry?.enabled || gen !== generation) return
    try {
      // syncModFolder copies nothing when the folder is current.
      await syncModFolder(modSource, modDir)
    } catch (err) {
      // The old mod files still send lines. So listen also after a failed copy.
      console.warn('Live details: Bifrost could not copy the mod folder.', messageOf(err))
    }
    await listen(gen)
  }

  // Run an action after the start ends.
  function action(fn: () => Promise<LiveStatus>): Promise<LiveStatus> {
    return starting.then(fn)
  }

  return {
    disable: () =>
      action(async () => {
        const cli = await needCli()
        if ((await cli.plugin()) !== null) await cli.disable()
        server.stop()
        return status()
      }),
    enable: () =>
      action(async () => {
        await checkVersion()
        const cli = await needCli()
        if ((await cli.plugin()) === null) throw new Error('Live details is not installed.')
        await removeOldInstall()
        await syncModFolder(modSource, modDir)
        await cli.enable()
        await server.start()
        return status()
      }),
    install: () =>
      action(async () => {
        await checkVersion()
        const cli = await needCli()
        await removeOldInstall()
        await syncModFolder(modSource, modDir)
        const market = await cli.marketplace()
        if (market === null) {
          await cli.addMarketplace(modDir)
        } else if (market.path === undefined || !samePath(market.path, modDir)) {
          throw new Error(
            `A marketplace with the name ${MARKETPLACE_NAME} already exists at ` +
              `${market.path ?? market.source}. Bifrost did not change it.`,
          )
        }
        let entry = await cli.plugin()
        if (entry === null) {
          await cli.install()
          // Read the entry again. If the install leaves the plugin off, the next step turns it on.
          entry = await cli.plugin()
        }
        if (entry !== null && !entry.enabled) await cli.enable()
        await server.start()
        return status()
      }),
    start() {
      const gen = generation
      starting = boot(gen).catch(err => {
        console.warn('Live details: the start failed.', messageOf(err))
      })
      return starting
    },
    status,
    stop() {
      generation += 1
      server.stop()
    },
    uninstall: () =>
      action(async () => {
        server.stop()
        const cli = await needCli()
        if ((await cli.plugin()) !== null) await cli.uninstall()
        // Remove only the marketplace that Bifrost added.
        // Never remove a marketplace with another path.
        const market = await cli.marketplace()
        if (market?.path !== undefined && samePath(market.path, modDir)) {
          await cli.removeMarketplace()
        }
        await removeModFolder(modDir)
        await removeOldInstall()
        return status()
      }),
  }
}
