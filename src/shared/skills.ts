// The Bifrost skills plugin (spec 5). The main process and the page share these names and types.
import type { SkillGroup } from './skill-check'
import type { LivePluginState } from './types'

export const SKILLS_MARKETPLACE = 'bifrost-skills'
export const SKILLS_PLUGIN_ID = 'bifrost@bifrost-skills'

export type { SkillGroup } from './skill-check'

export interface SkillInfo {
  name: string
  description: string
  group: SkillGroup
}

export interface SkillsStatus {
  plugin: LivePluginState
  // The folder has the files of this app, and the plugin reads that folder.
  folderCurrent: boolean
  // The skills in the app folder, sorted by name. Also when the plugin is not installed.
  skills: SkillInfo[]
  error?: string
}
