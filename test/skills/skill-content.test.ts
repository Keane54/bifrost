// The content rules of the Bifrost skill files in resources/bifrost-skills.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { readPluginSnapshot } from '../../scripts/skills/snapshot'
import { parseSkill, type SkillFields, skillGroup } from '../../src/shared/skill-check'

const ROOT = join(__dirname, '../../resources/bifrost-skills')
const MAX_LINE = 100
const EM_DASH = String.fromCharCode(0x2014)
const AMERICAN = /\b(humaniz|organiz|recogniz|realiz|summariz|prioritiz)\w*/i
// Claude Code puts the folder of the skill in place of this variable. The skill text holds it as is.
// biome-ignore lint/suspicious/noTemplateCurlyInString: the test looks for the literal variable.
const SKILL_DIR = '${CLAUDE_SKILL_DIR}'

const read = (path: string): string => readFileSync(join(ROOT, path), 'utf8')

function fieldsOf(folder: string): SkillFields {
  const parsed = parseSkill(read(`skills/${folder}/SKILL.md`))
  if (!parsed.ok) throw new Error(parsed.reason)
  return parsed.fields
}

// The lines after the closing --- of the frontmatter. A file with no frontmatter is all body.
function bodyLines(text: string): string[] {
  const lines = text.split('\n')
  if (lines[0] !== '---') return lines
  return lines.slice(lines.indexOf('---', 1) + 1)
}

const bodyOf = (folder: string): string => bodyLines(read(`skills/${folder}/SKILL.md`)).join('\n')

describe('the files of the Bifrost plugin', () => {
  const files = readPluginSnapshot(ROOT).files

  it('have no em dash', () => {
    const withDash = files.filter(file => read(file).includes(EM_DASH))
    expect(withDash).toEqual([])
  })

  it('have skill body lines of 100 characters or less', () => {
    const long: string[] = []
    for (const file of files.filter(path => path.startsWith('skills/'))) {
      bodyLines(read(file)).forEach((line, index) => {
        if (line.length > MAX_LINE) long.push(`${file} body line ${index + 1}: ${line.length}`)
      })
    }
    expect(long).toEqual([])
  })
})

describe.each(['bifrost-humanise', 'bifrost-grill'])('the adapted skill %s', folder => {
  it('is in the listed group', () => {
    const fields = fieldsOf(folder)
    expect(fields.name).toBe(folder)
    expect(skillGroup(fields)).toBe('listed')
  })

  it('keeps the MIT notice of the original and says what changed', () => {
    const licence = read(`skills/${folder}/LICENSE`)
    expect(licence).toMatch(/^MIT License$/m)
    expect(licence).toMatch(/^Copyright \(c\) \d{4} \S/m)
    expect(licence).toContain('Permission is hereby granted, free of charge')
    expect(licence).toMatch(/^Changes: /m)
  })
})

describe('bifrost-humanise', () => {
  it('reads its rules file first', () => {
    expect(bodyOf('bifrost-humanise')).toContain(`${SKILL_DIR}/rules.md`)
  })

  it('uses British spelling in the body and the rules', () => {
    expect(bodyOf('bifrost-humanise')).not.toMatch(AMERICAN)
    expect(read('skills/bifrost-humanise/rules.md')).not.toMatch(AMERICAN)
  })
})

describe('bifrost-grill', () => {
  it('asks one question at a time', () => {
    expect(bodyOf('bifrost-grill').toLowerCase()).toContain('one question at a time')
  })
})
