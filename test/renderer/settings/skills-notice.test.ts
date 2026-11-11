import { describe, expect, it } from 'vitest'
import {
  GROUP_HINT,
  GROUP_LABELS,
  nextSetupPhase,
  SKILLS_ABOUT,
  SKILLS_REMOVE_CONFIRM,
  SKILLS_SETUP_INTRO,
  SKILLS_STEPS,
  skillsActions,
  skillsDoneLine,
  skillsNotice,
  skillsStateLine,
  skillsStepNeeded,
  WITHOUT_SKILLS,
} from '../../../src/renderer/src/settings/skills-notice'
import type { SkillsStatus } from '../../../src/shared/skills'

function status(more: Partial<SkillsStatus> = {}): SkillsStatus {
  return { folderCurrent: true, plugin: 'enabled', skills: [], ...more }
}

describe('the texts', () => {
  it('give the exact in-app text', () => {
    expect(SKILLS_ABOUT).toBe(
      'Bifrost skills give Claude tested steps for common jobs: review a PR, ' +
        'resolve PR comments, humanise text, grill a plan and ' +
        'hand over a session. Start one by typing its name in a ' +
        "chat, for example /bifrost-review. They're a small Claude Code plugin that Bifrost " +
        'keeps up to date.',
    )
    expect(SKILLS_SETUP_INTRO).toBe(
      `${SKILLS_ABOUT} Bifrost makes these changes only if you install them:`,
    )
    expect(SKILLS_STEPS).toEqual([
      'Copy the skills plugin files to the folder ~/.bifrost/skills.',
      'Add that folder as the plugin marketplace "bifrost-skills", then install the plugin ' +
        '"bifrost" for your user with claude plugin.',
    ])
    expect(WITHOUT_SKILLS).toBe(
      'You can install the skills later in Settings > Skills. ' +
        'The Hand over button works without them.',
    )
    expect(SKILLS_REMOVE_CONFIRM).toEqual({
      body:
        'Bifrost turns off its skills, removes the plugin "bifrost" and the marketplace ' +
        '"bifrost-skills", and deletes the folder ~/.bifrost/skills.',
      confirm: 'Remove',
      title: 'Remove skills',
    })
    expect(GROUP_LABELS).toEqual({ 'called-by-name': 'Called by name', listed: 'Listed' })
    expect(GROUP_HINT).toBe(
      "Listed skills are in Claude's skill list, so Claude can start them by itself. " +
        'Skills called by name cost no context until you type their name.',
    )
  })
})

describe('skillsNotice and skillsStateLine', () => {
  it('gives each kind and its exact line', () => {
    expect(skillsNotice(null)).toEqual({ kind: 'loading' })
    expect(skillsStateLine({ kind: 'loading' })).toBe('Checking the skills...')
    expect(skillsNotice(status({ plugin: 'not-installed' }))).toEqual({ kind: 'not-installed' })
    expect(skillsStateLine({ kind: 'not-installed' })).toBe('Not installed.')
    expect(skillsNotice(status({ plugin: 'disabled' }))).toEqual({ kind: 'off' })
    expect(skillsStateLine({ kind: 'off' })).toBe('Off.')
    expect(skillsNotice(status())).toEqual({ kind: 'on' })
    expect(skillsStateLine({ kind: 'on' })).toBe('On.')
  })

  it('gives a problem for an unknown state, with the error or a default', () => {
    expect(skillsNotice(status({ error: 'claude failed', plugin: 'unknown' }))).toEqual({
      kind: 'problem',
      message: 'claude failed',
    })
    expect(skillsNotice(status({ plugin: 'unknown' }))).toEqual({
      kind: 'problem',
      message: "Bifrost couldn't check the skills.",
    })
    expect(skillsStateLine({ kind: 'problem', message: 'x' })).toBe('x')
  })

  it('gives a problem when the files do not match', () => {
    expect(skillsNotice(status({ folderCurrent: false }))).toEqual({
      kind: 'problem',
      message: "The skills use files that don't match this Bifrost. Turn them off, then on again.",
    })
  })
})

describe('skillsNotice with a foreign marketplace', () => {
  it('shows the problem text, not the files text', () => {
    const error = 'A marketplace with the name bifrost-skills already exists at /other.'
    expect(skillsNotice(status({ error, folderCurrent: false }))).toEqual({
      kind: 'problem',
      message: error,
    })
  })
})

describe('skillsDoneLine', () => {
  it('names the skills, except in a problem', () => {
    expect(skillsDoneLine({ kind: 'on' })).toBe('Skills: On.')
    expect(skillsDoneLine({ kind: 'problem', message: 'bad' })).toBe('bad')
  })
})

describe('skillsActions', () => {
  it('follows the table of Live details', () => {
    expect(skillsActions(null)).toEqual([])
    expect(skillsActions(status({ plugin: 'unknown' }))).toEqual(['retry'])
    expect(skillsActions(status({ plugin: 'not-installed' }))).toEqual(['install'])
    expect(skillsActions(status({ plugin: 'disabled' }))).toEqual(['enable', 'remove'])
    expect(skillsActions(status())).toEqual(['disable', 'remove'])
    expect(skillsActions(status({ folderCurrent: false }))).toEqual(['disable', 'enable', 'remove'])
  })
})

describe('skillsStepNeeded', () => {
  it('is true only for not-installed', () => {
    expect(skillsStepNeeded(status({ plugin: 'not-installed' }))).toBe(true)
    for (const plugin of ['enabled', 'disabled', 'unknown'] as const) {
      expect(skillsStepNeeded(status({ plugin }))).toBe(false)
    }
    expect(skillsStepNeeded(null)).toBe(false)
  })
})

describe('nextSetupPhase', () => {
  const none = { live: false, skills: false }
  const missing = status({ plugin: 'not-installed' })

  it('goes from live to the skills step when the skills are not installed', () => {
    expect(nextSetupPhase('live', missing, none)).toBe('skills')
    expect(nextSetupPhase('live', missing, { live: true, skills: false })).toBe('skills')
  })

  it('goes from live to done when something was installed, else close', () => {
    expect(nextSetupPhase('live', status(), { live: true, skills: false })).toBe('done')
    expect(nextSetupPhase('live', status(), none)).toBe('close')
    expect(nextSetupPhase('live', status({ plugin: 'unknown' }), none)).toBe('close')
    expect(nextSetupPhase('live', null, none)).toBe('close')
  })

  it('goes from skills to done when something was installed, else close', () => {
    expect(nextSetupPhase('skills', missing, none)).toBe('close')
    expect(nextSetupPhase('skills', missing, { live: true, skills: false })).toBe('done')
    expect(nextSetupPhase('skills', status(), { live: false, skills: true })).toBe('done')
    expect(nextSetupPhase('skills', status(), { live: true, skills: true })).toBe('done')
  })
})
