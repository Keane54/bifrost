// Install, Turn on, Turn off, Remove and the start rule of the Bifrost skills plugin.
// It follows Live details (live-control.ts), without a server and without old hooks.

import { resolve } from 'node:path'
import type { SkillInfo, SkillsStatus } from '../../shared/skills'
import type { LivePluginState } from '../../shared/types'
import type { PluginCli, PluginEntry } from '../live/plugin-cli'
import {
  listSkills,
  removeSkillsFolder,
  skillsFolderCurrent,
  syncSkillsFolder,
} from './skills-folder'

const NOT_FOUND = 'claude was not found.'

export interface SkillsControlDeps {
  cli(): Promise<PluginCli | null>
  // The skills folder in the app.
  source: string
  // The folder that the plugin reads: ~/.bifrost/skills.
  dir: string
}

export interface SkillsControl {
  start(): Promise<void>
  status(): Promise<SkillsStatus>
  install(): Promise<SkillsStatus>
  enable(): Promise<SkillsStatus>
  disable(): Promise<SkillsStatus>
  uninstall(): Promise<SkillsStatus>
}

function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

function samePath(a: string, b: string): boolean {
  return resolve(a) === resolve(b)
}

export function createSkillsControl(deps: SkillsControlDeps): SkillsControl {
  const { dir, source } = deps

  async function needCli(): Promise<PluginCli> {
    const cli = await deps.cli()
    if (cli === null) throw new Error(NOT_FOUND)
    return cli
  }

  async function readPlugin(): Promise<{
    state: LivePluginState
    entry: PluginEntry | null
    error?: string
  }> {
    try {
      const entry = await (await needCli()).plugin()
      if (entry === null) return { entry, state: 'not-installed' }
      return { entry, state: entry.enabled ? 'enabled' : 'disabled' }
    } catch (err) {
      return { entry: null, error: messageOf(err), state: 'unknown' }
    }
  }

  async function status(): Promise<SkillsStatus> {
    const [plugin, current, list] = await Promise.all([
      readPlugin(),
      skillsFolderCurrent(source, dir),
      listSkills(source).then(
        (skills): { skills: SkillInfo[]; error?: string } => ({ skills }),
        (err: unknown) => ({
          error: `Bifrost couldn't read its skills. ${messageOf(err)}`,
          skills: [],
        }),
      ),
    ])
    const folder = plugin.entry?.folder
    const error = [plugin.error, list.error].filter(e => e !== undefined && e !== '').join(' ')
    const result: SkillsStatus = {
      folderCurrent: current && (folder === undefined || samePath(folder, dir)),
      plugin: plugin.state,
      skills: list.skills,
    }
    if (error !== '') result.error = error
    return result
  }

  return {
    async disable() {
      const cli = await needCli()
      if ((await cli.plugin()) !== null) await cli.disable()
      return status()
    },
    async enable() {
      const cli = await needCli()
      if ((await cli.plugin()) === null) throw new Error('Bifrost skills are not installed.')
      await syncSkillsFolder(source, dir)
      await cli.enable()
      return status()
    },
    async install() {
      const cli = await needCli()
      // Refuse a marketplace of another program before any change.
      const market = await cli.marketplace()
      if (market !== null && (market.path === undefined || !samePath(market.path, dir))) {
        throw new Error(
          'A marketplace with the name bifrost-skills already exists at ' +
            `${market.path ?? market.source}. Bifrost did not change it.`,
        )
      }
      await syncSkillsFolder(source, dir)
      if (market === null) await cli.addMarketplace(dir)
      let entry = await cli.plugin()
      if (entry === null) {
        await cli.install()
        // Read the entry again. If the install leaves the plugin off, the next step turns it on.
        entry = await cli.plugin()
      }
      if (entry !== null && !entry.enabled) await cli.enable()
      return status()
    },
    // The start rule (spec 5.4). Update the folder of a plugin that is on or off.
    // A failure goes to console.warn. The start never rejects.
    async start() {
      try {
        const entry = await (await needCli()).plugin()
        if (entry !== null) await syncSkillsFolder(source, dir)
      } catch (err) {
        console.warn('Bifrost skills: the start failed.', messageOf(err))
      }
    },
    status,
    async uninstall() {
      const cli = await needCli()
      if ((await cli.plugin()) !== null) await cli.uninstall()
      // Remove only the marketplace that Bifrost added.
      // Never remove a marketplace with another path.
      const market = await cli.marketplace()
      if (market?.path !== undefined && samePath(market.path, dir)) {
        await cli.removeMarketplace()
      }
      await removeSkillsFolder(dir)
      return status()
    },
  }
}
