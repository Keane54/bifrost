import { join } from 'node:path'
import type { DailyUpdateSettings } from '../../shared/daily-update'
import { writeJsonAtomic } from '../store/json-file'

export function skillExportFile(bifrostHome: string): string {
  return join(bifrostHome, 'daily-update', 'settings.json')
}

// Write the settings that the skill reads. The file holds only the areas that are on.
// mergedPrs tells the mode by hand of the skill whether to read the merged PRs.
// writeJsonAtomic makes the file with mode 600.
export async function writeSkillExport(file: string, s: DailyUpdateSettings): Promise<void> {
  await writeJsonAtomic(file, {
    areas: s.areas.filter(area => area.on),
    format: s.format,
    mergedPrs: s.mergedPrs,
    source: s.source,
    version: 1,
    you: s.you,
  })
}
