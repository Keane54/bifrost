// The frontmatter rules of the Bifrost skills and the CI check that applies them.
import { describe, expect, it } from 'vitest'
import { readPluginSnapshot } from '../../scripts/skills/snapshot'
import {
  checkPlugin,
  type PluginSnapshot,
  parseSkill,
  type SkillFields,
  skillGroup,
} from '../../src/shared/skill-check'

const MANIFEST = JSON.stringify({ description: 'Skills.', name: 'bifrost', version: '1.0.0' })

function skillText(fields: Record<string, string>, bodyLines = 1): string {
  const front = Object.entries(fields).map(([key, value]) => `${key}: ${value}`)
  return ['---', ...front, '---', ...Array.from({ length: bodyLines }, () => 'Body.')].join('\n')
}

function calledByName(folder = 'bifrost-grill'): { folder: string; text: string } {
  return {
    folder,
    text: skillText({
      description: 'Grill a plan.',
      'disable-model-invocation': 'true',
      name: folder,
    }),
  }
}

function listed(folder: string, descriptionLength = 20): { folder: string; text: string } {
  return {
    folder,
    text: skillText({
      description: 'd'.repeat(descriptionLength),
      'disable-model-invocation': 'false',
      name: folder,
    }),
  }
}

function plugin(
  skills: { folder: string; text: string }[],
  extra: Partial<PluginSnapshot> = {},
): PluginSnapshot {
  return {
    files: [
      '.claude-plugin/plugin.json',
      ...skills.map(skill => `skills/${skill.folder}/SKILL.md`),
    ],
    manifest: MANIFEST,
    skills,
    ...extra,
  }
}

function fieldsOf(text: string): SkillFields {
  const parsed = parseSkill(text)
  if (!parsed.ok) throw new Error(parsed.reason)
  return parsed.fields
}

describe('parseSkill', () => {
  it('reads plain, double-quoted and single-quoted values', () => {
    expect(fieldsOf('---\ndescription: "say \\"hi\\""\n---\n').description).toBe('say "hi"')
    expect(fieldsOf("---\ndescription: 'it''s'\n---\n").description).toBe("it's")
    expect(fieldsOf('---\ndescription: plain text\n---\n').description).toBe('plain text')
  })

  it('reads a boolean field as a boolean', () => {
    expect(fieldsOf('---\ndisable-model-invocation: true\n---\n')['disable-model-invocation']).toBe(
      true,
    )
    expect(fieldsOf('---\nbackground: false\n---\n').background).toBe(false)
  })

  it('counts the lines of the file', () => {
    const parsed = parseSkill(skillText({ description: 'x' }, 3))
    expect(parsed).toMatchObject({ lines: 6, ok: true })
    const withNewline = parseSkill(`${skillText({ description: 'x' }, 3)}\n`)
    expect(withNewline).toMatchObject({ lines: 6, ok: true })
  })

  it.each([
    ['no closing marker', '---\ndescription: x\nBody'],
    ['no opening marker', 'description: x\n---\n'],
    ['a colon and a space in a plain value', '---\ndescription: a: b\n---\n'],
    ['a plain value that ends with a colon', '---\ndescription: ab:\n---\n'],
    ['a plain value that starts with [', '---\ndescription: [a]\n---\n'],
    ['a plain value that starts with {', '---\ndescription: {a}\n---\n'],
    ['a plain value that starts with >', '---\ndescription: > a\n---\n'],
    ['a plain value that starts with |', '---\ndescription: | a\n---\n'],
    ['a plain value with a comment', '---\ndescription: a #b\n---\n'],
    ['a duplicate key', '---\ndescription: a\ndescription: b\n---\n'],
    ['a blank line in the frontmatter', '---\ndescription: a\n\nname: b\n---\n'],
    ['CRLF line ends', '---\r\ndescription: a\r\n---\r\n'],
    ['yes as a boolean', '---\ndisable-model-invocation: yes\n---\n'],
    ['an unknown escape', '---\ndescription: "a\\nb"\n---\n'],
    ['text after a closing quote', '---\ndescription: "a" b\n---\n'],
    ['an indented line', '---\ndescription: a\n  more\n---\n'],
  ])('does not parse %s', (_name, text) => {
    expect(parseSkill(text).ok).toBe(false)
  })
})

describe('skillGroup', () => {
  it('maps the boolean to a group', () => {
    expect(skillGroup({ 'disable-model-invocation': true })).toBe('called-by-name')
    expect(skillGroup({ 'disable-model-invocation': false })).toBe('listed')
    expect(skillGroup({})).toBeNull()
  })
})

describe('checkPlugin', () => {
  it('passes a good called-by-name skill and a good listed skill', () => {
    expect(checkPlugin(plugin([calledByName(), listed('bifrost-review')]))).toEqual([])
  })

  it('fails a folder without the prefix', () => {
    const failures = checkPlugin(plugin([calledByName('review')]))
    expect(failures.some(line => line.includes('bifrost-'))).toBe(true)
  })

  it('fails a name that differs from the folder', () => {
    const skill = {
      folder: 'bifrost-grill',
      text: skillText({ description: 'x', 'disable-model-invocation': 'true', name: 'other' }),
    }
    expect(checkPlugin(plugin([skill])).length).toBeGreaterThan(0)
  })

  it('fails an unknown field and a hooks field and names the field', () => {
    for (const field of ['metadata', 'hooks']) {
      const skill = {
        folder: 'bifrost-grill',
        text: skillText({ description: 'x', 'disable-model-invocation': 'true', [field]: 'x' }),
      }
      const failures = checkPlugin(plugin([skill]))
      expect(failures.some(line => line.includes(field))).toBe(true)
    }
  })

  it('fails a skill that does not parse', () => {
    const skill = { folder: 'bifrost-grill', text: '---\ndescription: a: b\n---\n' }
    expect(checkPlugin(plugin([skill])).length).toBeGreaterThan(0)
  })

  it('fails a skill with no group', () => {
    const skill = { folder: 'bifrost-grill', text: skillText({ description: 'x' }) }
    const failures = checkPlugin(plugin([skill]))
    expect(failures.some(line => line.includes('has no group'))).toBe(true)
  })

  it('fails a missing or empty description', () => {
    for (const fields of [{ 'disable-model-invocation': 'true' }, { description: '' }]) {
      const skill = {
        folder: 'bifrost-grill',
        text: skillText({ 'disable-model-invocation': 'true', ...fields }),
      }
      expect(checkPlugin(plugin([skill])).length).toBeGreaterThan(0)
    }
  })

  it('limits description plus when_to_use to 250 characters', () => {
    const make = (when: number) => ({
      folder: 'bifrost-grill',
      text: skillText({
        description: 'd'.repeat(200),
        'disable-model-invocation': 'true',
        when_to_use: 'w'.repeat(when),
      }),
    })
    const failures = checkPlugin(plugin([make(51)]))
    expect(failures.some(line => line.includes('251'))).toBe(true)
    expect(checkPlugin(plugin([make(50)]))).toEqual([])
  })

  it('limits the listed skills to 1500 characters in total', () => {
    const seven = Array.from({ length: 7 }, (_, index) => listed(`bifrost-l${index}`, 250))
    const failures = checkPlugin(plugin(seven))
    expect(failures.some(line => line.includes('1750'))).toBe(true)
    expect(checkPlugin(plugin(seven.slice(0, 6)))).toEqual([])
  })

  it('does not count called-by-name skills in the listed total', () => {
    const skills = Array.from({ length: 8 }, (_, index) => ({
      folder: `bifrost-c${index}`,
      text: skillText({
        description: 'd'.repeat(250),
        'disable-model-invocation': 'true',
        name: `bifrost-c${index}`,
      }),
    }))
    expect(checkPlugin(plugin(skills))).toEqual([])
  })

  it('limits a SKILL.md to 500 lines', () => {
    const make = (body: number) => ({
      folder: 'bifrost-grill',
      text: skillText({ description: 'x', 'disable-model-invocation': 'true' }, body),
    })
    // Four lines of frontmatter and markers, so 496 body lines make 500 lines.
    expect(checkPlugin(plugin([make(496)]))).toEqual([])
    expect(checkPlugin(plugin([make(497)])).length).toBeGreaterThan(0)
  })

  it('fails a hooks file and a hooks key in the manifest', () => {
    const base = plugin([calledByName()])
    expect(checkPlugin({ ...base, files: [...base.files, 'hooks/hooks.json'] }).length).toBe(1)
    const withKey = JSON.stringify({ hooks: {}, name: 'bifrost' })
    expect(checkPlugin({ ...base, manifest: withKey }).length).toBe(1)
  })

  it('fails a manifest with another name or that is not JSON', () => {
    const base = plugin([calledByName()])
    expect(checkPlugin({ ...base, manifest: JSON.stringify({ name: 'other' }) }).length).toBe(1)
    expect(checkPlugin({ ...base, manifest: '{' }).length).toBe(1)
  })

  it('fails a skill folder with no SKILL.md', () => {
    const base = plugin([calledByName()])
    const failures = checkPlugin({ ...base, files: [...base.files, 'skills/bifrost-x/notes.md'] })
    expect(failures.some(line => line.includes('bifrost-x'))).toBe(true)
  })
})

describe('the Bifrost plugin folder', () => {
  it('passes the checks', () => {
    expect(checkPlugin(readPluginSnapshot('resources/bifrost-skills'))).toEqual([])
  })
})
