// Read the plugin folder of the Bifrost skills into a PluginSnapshot.
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { PluginSnapshot } from '../../src/shared/skill-check.ts'

function walk(root: string, prefix: string): string[] {
  const result: string[] = []
  for (const entry of readdirSync(join(root, prefix), { withFileTypes: true })) {
    if (entry.name === '.DS_Store') continue
    const path = prefix === '' ? entry.name : `${prefix}/${entry.name}`
    if (entry.isDirectory()) result.push(...walk(root, path))
    else result.push(path)
  }
  return result.sort()
}

export function readPluginSnapshot(dir: string): PluginSnapshot {
  const files = walk(dir, '')
  const manifestPath = join(dir, '.claude-plugin', 'plugin.json')
  const manifest = existsSync(manifestPath) ? readFileSync(manifestPath, 'utf8') : ''
  const skills: PluginSnapshot['skills'] = []
  const skillsDir = join(dir, 'skills')
  if (existsSync(skillsDir)) {
    for (const entry of readdirSync(skillsDir, { withFileTypes: true })) {
      const file = join(skillsDir, entry.name, 'SKILL.md')
      if (entry.isDirectory() && existsSync(file)) {
        skills.push({ folder: entry.name, text: readFileSync(file, 'utf8') })
      }
    }
  }
  skills.sort((a, b) => a.folder.localeCompare(b.folder))
  return { files, manifest, skills }
}
