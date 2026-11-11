// The content rules of the Bifrost skill files in resources/bifrost-skills.
import { readdirSync, readFileSync } from 'node:fs'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { readPluginSnapshot } from '../../scripts/skills/snapshot'
import { parseDiff } from '../../src/main/reviews/diff-lines'
import type { RepoStore } from '../../src/main/reviews/repo-store'
import { parseReviewResult, placeComments } from '../../src/main/reviews/result-file'
import { writeRoundFiles } from '../../src/main/reviews/review-input'
import type { ReviewContext } from '../../src/main/reviews/review-query'
import { parseSkill, type SkillFields, skillGroup } from '../../src/shared/skill-check'

const ROOT = join(__dirname, '../../resources/bifrost-skills')
const MAX_LINE = 100
const EM_DASH = String.fromCharCode(0x2014)
const AMERICAN = /\b(humaniz|organiz|recogniz|realiz|summariz|prioritiz)\w*/i
// Claude Code puts the folder of the skill in place of this variable.
// The skill text holds it as is.
// biome-ignore lint/suspicious/noTemplateCurlyInString: the test looks for the literal variable.
const SKILL_DIR = '${CLAUDE_SKILL_DIR}'
// Claude Code puts the folder of the plugin in place of this variable.
// biome-ignore lint/suspicious/noTemplateCurlyInString: the test looks for the literal variable.
const HUMANISE_RULES = '${CLAUDE_PLUGIN_ROOT}/skills/bifrost-humanise/rules.md'
const PR_SKILLS = ['bifrost-review', 'bifrost-resolve-comments']
const SKILLS = [
  'bifrost-grill',
  'bifrost-hand-over',
  'bifrost-humanise',
  'bifrost-resolve-comments',
  'bifrost-review',
]
// The nine parts of a hand-over note, in order (spec 7.5).
const NOTE_PARTS = [
  'Goal and scope',
  'User rules',
  'Decisions',
  'State',
  'Done',
  'Next steps',
  'Open questions',
  'Traps',
  'References',
]
const HAND_OVER_RULES = 'skills/bifrost-hand-over/hand-over-rules.md'
const BIFROST_MODE = 'skills/bifrost-review/bifrost-mode.md'
// The fields of the input file that bifrost-mode.md uses.
const INPUT_FIELDS = [
  'pr',
  'pr.key',
  'pr.headSha',
  'viewer',
  'review.kind',
  'review.since',
  'review.note',
  'review.lastReview',
  'changedFiles',
  'earlier.threads',
  'earlier.summaries',
  'files.fullDiff',
  'files.sinceDiff',
  'files.result',
  'files.rules',
]
const SAMPLE_DIFF = readFileSync(join(__dirname, '../fixtures/reviews/sample.diff'), 'utf8')
// The start of a variable. Bifrost puts the rules file in a prompt as it is, so the file has none.
const VARIABLE_START = '${'

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

describe('the skills of the Bifrost plugin', () => {
  it('are exactly the five skill folders', () => {
    const folders = readdirSync(join(ROOT, 'skills'), { withFileTypes: true })
      .filter(entry => entry.isDirectory())
      .map(entry => entry.name)
      .sort()
    expect(folders).toEqual(SKILLS)
  })

  // All five skills run inline (spec 6).
  it.each(SKILLS)('run inline: %s has no context field', folder => {
    expect(fieldsOf(folder)).not.toHaveProperty('context')
  })
})

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

describe.each(PR_SKILLS)('the PR skill %s', folder => {
  it('is in the called-by-name group and takes a PR', () => {
    const fields = fieldsOf(folder)
    expect(fields.name).toBe(folder)
    expect(skillGroup(fields)).toBe('called-by-name')
    expect(fields['argument-hint']).toBe('[PR number or URL]')
  })

  it('reads the humanise rules for the text that a person reads', () => {
    expect(bodyOf(folder)).toContain(HUMANISE_RULES)
  })

  it('uses British spelling in the body and the reference', () => {
    expect(bodyOf(folder)).not.toMatch(AMERICAN)
    expect(read(`skills/${folder}/reference.md`)).not.toMatch(AMERICAN)
  })
})

describe('bifrost-review', () => {
  it('leaves a pending review with a recommendation', () => {
    const body = bodyOf('bifrost-review')
    for (const text of ['pending review', 'Approve', 'Comment', 'Request changes']) {
      expect(body).toContain(text)
    }
  })

  it('skips the reviews that hold only thread replies when it finds the re-review baseline', () => {
    expect(read('skills/bifrost-review/reference.md')).toContain('.replyTo != null')
    expect(bodyOf('bifrost-review')).toContain('tell the user which review is the baseline')
  })

  it('bifrost-review starts its Bifrost mode on bifrost-input= and reads mode.md', () => {
    const body = bodyOf('bifrost-review')
    const start = body.indexOf('## Started by Bifrost')
    const end = body.indexOf('\n## ', start + 1)
    expect(start).toBeGreaterThan(-1)
    // The section comes before the reference file and before the rules.
    expect(start).toBeLessThan(body.indexOf('reference.md'))
    expect(start).toBeLessThan(body.indexOf('## Rules that always apply'))
    // The text can wrap at any space.
    const section = body.slice(start, end).replace(/\s+/g, ' ')
    for (const text of [
      '`$ARGUMENTS` starts with `bifrost-input=`',
      'Read `mode.md` in the folder of that file',
      'sections 1, 8, 9 and 10',
      '`files.rules`',
      'current folder',
    ]) {
      expect(section).toContain(text)
    }
  })
})

describe('the Bifrost mode of bifrost-review', () => {
  const mode = (): string => read(BIFROST_MODE)

  it('the JSON example in bifrost-mode.md is a valid result', () => {
    const block = /```json\n([\s\S]*?)\n```/.exec(mode())
    expect(block).not.toBeNull()
    const files = parseDiff(SAMPLE_DIFF)
    const out = parseReviewResult(block?.[1] ?? '', {
      files,
      headSha: 'a'.repeat(40),
      pr: 'acme/api#7',
    })
    expect(out.ok ? 'valid' : out.reason).toBe('valid')
    if (!out.ok) return
    expect(out.result.recommendation).toBe('request-changes')
    expect(out.result.comments).toEqual([
      expect.objectContaining({ line: 12, path: 'src/limit.ts', side: 'RIGHT' }),
    ])
    expect(placeComments(out.result, files).moved).toBe(0)
  })

  it('bifrost-mode.md names each input field that it uses', async () => {
    for (const field of INPUT_FIELDS) expect(mode()).toContain(`\`${field}\``)
    // Each field is in the input file that Bifrost writes.
    const base = await mkdtemp(join(tmpdir(), 'bifrost-mode-fields-'))
    try {
      const repos = {
        hasCommit: async () => true,
        isAncestor: async () => true,
        async resetIo(): Promise<string> {
          const io = join(base, 'io')
          await mkdir(io, { recursive: true })
          return io
        },
        async writeDiff(_c: string, _f: string, _t: string, file: string): Promise<void> {
          await writeFile(file, SAMPLE_DIFF)
        },
      } as unknown as RepoStore
      const old = 'c'.repeat(40)
      const context = {
        author: 'someone',
        baseRef: 'main',
        baseSha: 'b'.repeat(40),
        body: '',
        headRef: 'feature',
        headSha: 'a'.repeat(40),
        number: 7,
        owner: 'acme',
        pending: null,
        repo: 'api',
        reviews: [
          {
            body: 'Fix it.',
            commit: old,
            replyOnly: false,
            state: 'COMMENTED',
            submittedAt: 1,
            url: '',
          },
        ],
        state: 'OPEN',
        threads: [],
        title: 'A title',
        truncated: false,
        url: '',
      } as unknown as ReviewContext
      const out = await writeRoundFiles(
        { repos, skillsDir: ROOT },
        {
          clone: join(base, 'clone'),
          context,
          fetched: { base: 'b'.repeat(40), head: 'a'.repeat(40), mergeBase: 'b'.repeat(40) },
          number: 7,
          viewer: 'me',
        },
      )
      expect(out.ok).toBe(true)
      if (!out.ok) return
      expect(out.input.review.kind).toBe('re-review')
      for (const field of INPUT_FIELDS) {
        let value: unknown = out.input
        for (const key of field.split('.')) {
          expect(value).toHaveProperty([key])
          value = (value as Record<string, unknown>)[key]
        }
      }
    } finally {
      await rm(base, { force: true, recursive: true })
    }
  })

  // Bifrost copies the file into the input folder, and the session reads it as it is.
  it('bifrost-mode.md has no frontmatter, no variable and British spelling', () => {
    expect(mode().startsWith('---')).toBe(false)
    expect(mode()).not.toContain(VARIABLE_START)
    expect(mode()).not.toMatch(AMERICAN)
  })
})

describe('bifrost-resolve-comments', () => {
  it('acts for trusted authors only and names the outcomes', () => {
    const body = bodyOf('bifrost-resolve-comments')
    for (const text of ['OWNER', 'MEMBER', 'COLLABORATOR', 'Fixed by', 'Needs you']) {
      expect(body).toContain(text)
    }
  })

  it('stops on a working tree with uncommitted changes', () => {
    expect(bodyOf('bifrost-resolve-comments')).toContain('If `git status --porcelain` prints')
  })
})

describe('bifrost-hand-over', () => {
  const rules = (): string => read(HAND_OVER_RULES)

  it('is in the called-by-name group and takes a path', () => {
    const fields = fieldsOf('bifrost-hand-over')
    expect(fields.name).toBe('bifrost-hand-over')
    expect(skillGroup(fields)).toBe('called-by-name')
    expect(fields['argument-hint']).toBe('[path]')
  })

  // The Hand over button puts the rules file in its prompt as it is (spec 8).
  it('has a rules file with no frontmatter and no variable', () => {
    expect(rules().startsWith('---')).toBe(false)
    expect(rules()).not.toContain(VARIABLE_START)
  })

  it('names the nine parts of the note as headings, in order', () => {
    const at = NOTE_PARTS.map(part => rules().indexOf(`## ${part}`))
    expect(at).not.toContain(-1)
    expect(at).toEqual([...at].sort((a, b) => a - b))
  })

  it('keeps secrets out of the note, also out of an identifier', () => {
    expect(rules()).toMatch(/^- Never write a secret, a token, a password/m)
    expect(rules()).toContain('This rule comes before all other rules in this file.')
    expect(rules()).toContain('The one exception is a credential')
  })

  it('reads the rules file and saves the note, but does not repeat the rules', () => {
    const body = bodyOf('bifrost-hand-over')
    expect(body).toContain(`${SKILL_DIR}/hand-over-rules.md`)
    expect(body).toContain('~/.bifrost/handovers/')
    expect(body).not.toContain('Open questions')
    expect(body).not.toContain('Traps')
  })

  it('uses British spelling in the body and the rules', () => {
    expect(bodyOf('bifrost-hand-over')).not.toMatch(AMERICAN)
    expect(rules()).not.toMatch(AMERICAN)
  })
})
