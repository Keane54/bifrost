import type { Dirent } from 'node:fs'
import { readdir, readFile, rename, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { parseSkill, skillGroup } from '../../shared/skill-check'
import type { SkillInfo } from '../../shared/skills'
import { type SyncOps, writeFolder } from '../live/mod-folder'

// In the packaged app, electron-builder unpacks resources/** next to app.asar.
export function skillsSourceDir(appPath: string): string {
  return join(appPath.replace(/app\.asar$/, 'app.asar.unpacked'), 'resources', 'bifrost-skills')
}

// The regular files under dir, as sorted relative paths. A missing folder gives [].
// A link is not a regular file, so it is not in the list.
export async function listFiles(dir: string): Promise<string[]> {
  let entries: Dirent[]
  try {
    entries = await readdir(dir, { recursive: true, withFileTypes: true })
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return []
    throw e
  }
  const files = entries
    .filter(entry => entry.isFile())
    .map(entry => join(entry.parentPath, entry.name).slice(dir.length + 1))
  return files.sort()
}

// True only when dest has the same files as source, with the same bytes.
export async function skillsFolderCurrent(source: string, dest: string): Promise<boolean> {
  try {
    const [a, b] = await Promise.all([listFiles(source), listFiles(dest)])
    if (a.length === 0 || a.length !== b.length || a.some((file, i) => file !== b[i])) return false
    for (const file of a) {
      const [x, y] = await Promise.all([readFile(join(source, file)), readFile(join(dest, file))])
      if (!x.equals(y)) return false
    }
    return true
  } catch {
    return false
  }
}

// Copy the files of source to a temporary folder. Then swap it with dest.
// An extra file in dest goes. A failure leaves dest as it was.
export async function syncSkillsFolder(
  source: string,
  dest: string,
  ops: SyncOps = { rename, rm },
): Promise<void> {
  if (await skillsFolderCurrent(source, dest)) return
  const files = await listFiles(source)
  if (files.length === 0) throw new Error('The skills folder of the app has no files.')
  const entries = await Promise.all(
    files.map(async file => ({ bytes: await readFile(join(source, file)), file })),
  )
  await writeFolder(dest, entries, ops)
}

// A missing folder is not an error.
export async function removeSkillsFolder(dest: string): Promise<void> {
  await rm(dest, { force: true, recursive: true })
}

// The skills in source, sorted by name. A folder with no SKILL.md, a frontmatter that does not
// parse, or no group is not in the list.
export async function listSkills(source: string): Promise<SkillInfo[]> {
  const root = join(source, 'skills')
  const folders = await readdir(root, { withFileTypes: true })
  const skills: SkillInfo[] = []
  for (const folder of folders) {
    if (!folder.isDirectory()) continue
    let text: string
    try {
      text = await readFile(join(root, folder.name, 'SKILL.md'), 'utf8')
    } catch {
      continue
    }
    const parsed = parseSkill(text)
    if (!parsed.ok) continue
    const group = skillGroup(parsed.fields)
    if (group === null) continue
    const { description, name } = parsed.fields
    skills.push({
      description: typeof description === 'string' ? description : '',
      group,
      name: typeof name === 'string' && name !== '' ? name : folder.name,
    })
  }
  return skills.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
}
