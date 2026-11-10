// The rules of the Bifrost skills. This file has no imports, so a script can run it with Node.
// Use erasable TypeScript syntax only: no enum and no parameter property.

export const SKILL_PREFIX = 'bifrost-'
export const MAX_SKILL_TEXT = 250
export const MAX_LISTED_TEXT = 1500
export const MAX_SKILL_LINES = 500

// The fields of the Claude Code skills docs, without hooks and metadata.
export const SKILL_FIELDS: readonly string[] = [
  'name',
  'description',
  'when_to_use',
  'argument-hint',
  'arguments',
  'disable-model-invocation',
  'user-invocable',
  'allowed-tools',
  'disallowed-tools',
  'model',
  'effort',
  'context',
  'agent',
  'background',
  'paths',
  'shell',
  'license',
  'compatibility',
]

export const BOOLEAN_FIELDS: readonly string[] = [
  'disable-model-invocation',
  'user-invocable',
  'background',
]

export type SkillGroup = 'called-by-name' | 'listed'
export type SkillFields = Readonly<Record<string, string | boolean>>
export type ParsedSkill =
  | { ok: true; fields: SkillFields; lines: number }
  | { ok: false; reason: string }

export interface PluginSnapshot {
  // All relative POSIX paths in the plugin folder.
  files: string[]
  // The text of .claude-plugin/plugin.json.
  manifest: string
  // Each skills/<folder>/SKILL.md.
  skills: { folder: string; text: string }[]
}

const KEY = /^([a-z_-]+):(?: (.*))?$/
const PLAIN_START = [
  '- ',
  '[',
  ']',
  '{',
  '}',
  '>',
  '|',
  '*',
  '&',
  '!',
  '%',
  '@',
  '#',
  "'",
  '"',
  '`',
]

type Value = { ok: true; value: string | boolean } | { ok: false; reason: string }

function readValue(key: string, raw: string): Value {
  const value = raw.trim()
  if (BOOLEAN_FIELDS.includes(key)) {
    if (value === 'true') return { ok: true, value: true }
    if (value === 'false') return { ok: true, value: false }
    return { ok: false, reason: `the field ${key} must be true or false` }
  }
  if (value.startsWith('"')) {
    let result = ''
    for (let index = 1; index < value.length; index++) {
      const char = value[index]
      if (char === '\\') {
        const next = value[index + 1]
        if (next !== '"' && next !== '\\') {
          return { ok: false, reason: `the field ${key} has an escape that is not allowed` }
        }
        result += next
        index++
      } else if (char === '"') {
        if (index !== value.length - 1) {
          return { ok: false, reason: `the field ${key} has text after the closing quote` }
        }
        return { ok: true, value: result }
      } else {
        result += char
      }
    }
    return { ok: false, reason: `the field ${key} has no closing quote` }
  }
  if (value.startsWith("'")) {
    let result = ''
    for (let index = 1; index < value.length; index++) {
      if (value[index] === "'") {
        if (value[index + 1] === "'") {
          result += "'"
          index++
        } else if (index === value.length - 1) {
          return { ok: true, value: result }
        } else {
          return { ok: false, reason: `the field ${key} has text after the closing quote` }
        }
      } else {
        result += value[index]
      }
    }
    return { ok: false, reason: `the field ${key} has no closing quote` }
  }
  if (PLAIN_START.some(start => value.startsWith(start))) {
    return { ok: false, reason: `the plain value of ${key} starts with a reserved character` }
  }
  if (value.includes(': ') || value.includes(' #') || value.endsWith(':')) {
    return { ok: false, reason: `the plain value of ${key} needs quotes` }
  }
  return { ok: true, value }
}

// Read the frontmatter of a SKILL.md. The subset that this function accepts is valid YAML, so
// Claude Code reads each value the same way.
export function parseSkill(text: string): ParsedSkill {
  if (text.includes('\r')) return { ok: false, reason: 'the file has CRLF line ends' }
  const all = text.split('\n')
  if (all[all.length - 1] === '') all.pop()
  if (all[0] !== '---') return { ok: false, reason: 'the frontmatter does not start at line 1' }
  const end = all.indexOf('---', 1)
  if (end === -1) return { ok: false, reason: 'the frontmatter has no closing ---' }
  const fields: Record<string, string | boolean> = {}
  for (let index = 1; index < end; index++) {
    const line = all[index] ?? ''
    if (line.trim() === '') {
      return { ok: false, reason: `line ${index + 1} of the frontmatter is blank` }
    }
    const match = KEY.exec(line)
    if (!match) return { ok: false, reason: `line ${index + 1} is not a key and a value` }
    const key = match[1] ?? ''
    if (Object.hasOwn(fields, key)) return { ok: false, reason: `the key ${key} is twice` }
    const value = readValue(key, match[2] ?? '')
    if (!value.ok) return { ok: false, reason: value.reason }
    fields[key] = value.value
  }
  return { fields, lines: all.length, ok: true }
}

// true: called-by-name. false: listed. No value: no group.
export function skillGroup(fields: SkillFields): SkillGroup | null {
  const value = fields['disable-model-invocation']
  if (value === true) return 'called-by-name'
  if (value === false) return 'listed'
  return null
}

// The description plus when_to_use.
export function skillText(fields: SkillFields): string {
  const part = (key: string): string => {
    const value = fields[key]
    return typeof value === 'string' ? value : ''
  }
  return part('description') + part('when_to_use')
}

// One line per failure. An empty list means the plugin passes.
export function checkPlugin(plugin: PluginSnapshot): string[] {
  const failures: string[] = []
  let listedTotal = 0

  for (const skill of plugin.skills) {
    const where = `skills/${skill.folder}/SKILL.md`
    if (!skill.folder.startsWith(SKILL_PREFIX)) {
      failures.push(`${where}: the folder name must start with ${SKILL_PREFIX}`)
    }
    const parsed = parseSkill(skill.text)
    if (!parsed.ok) {
      failures.push(`${where}: ${parsed.reason}`)
      continue
    }
    const { fields, lines } = parsed
    for (const key of Object.keys(fields)) {
      if (!SKILL_FIELDS.includes(key)) failures.push(`${where}: the field ${key} is not allowed`)
    }
    if (fields.name !== undefined && fields.name !== skill.folder) {
      failures.push(`${where}: the name must be ${skill.folder}`)
    }
    if (typeof fields.description !== 'string' || fields.description.trim() === '') {
      failures.push(`${where}: the description is missing or empty`)
    }
    const text = skillText(fields).length
    if (text > MAX_SKILL_TEXT) {
      failures.push(
        `${where}: description plus when_to_use is ${text} characters, over ${MAX_SKILL_TEXT}`,
      )
    }
    if (lines > MAX_SKILL_LINES) {
      failures.push(`${where}: the file has ${lines} lines, over ${MAX_SKILL_LINES}`)
    }
    const group = skillGroup(fields)
    if (group === null) {
      failures.push(
        `${where}: the skill has no group (set disable-model-invocation to true or false)`,
      )
    } else if (group === 'listed') {
      listedTotal += text
    }
  }
  if (listedTotal > MAX_LISTED_TEXT) {
    failures.push(
      `the listed skills have ${listedTotal} characters in total, over ${MAX_LISTED_TEXT}`,
    )
  }

  if (plugin.files.includes('hooks/hooks.json')) {
    failures.push('hooks/hooks.json: the plugin must have no hooks')
  }
  const withSkillFile = new Set(plugin.skills.map(skill => skill.folder))
  const folders = new Set<string>()
  for (const file of plugin.files) {
    const match = /^skills\/([^/]+)\//.exec(file)
    if (match?.[1]) folders.add(match[1])
  }
  for (const folder of folders) {
    if (!withSkillFile.has(folder)) failures.push(`skills/${folder}: the folder has no SKILL.md`)
  }

  try {
    const manifest: unknown = JSON.parse(plugin.manifest)
    if (typeof manifest !== 'object' || manifest === null || Array.isArray(manifest)) {
      failures.push('.claude-plugin/plugin.json: the file must hold an object')
    } else {
      if ((manifest as Record<string, unknown>).name !== 'bifrost') {
        failures.push('.claude-plugin/plugin.json: the name must be bifrost')
      }
      if ('hooks' in manifest) {
        failures.push('.claude-plugin/plugin.json: the plugin must have no hooks key')
      }
    }
  } catch {
    failures.push('.claude-plugin/plugin.json: the file is not valid JSON')
  }
  return failures
}
