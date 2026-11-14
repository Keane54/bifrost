import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

// The repository has no DOM test. So this test reads the source text.
const RENDERER = join(__dirname, '../../../src/renderer/src')
const read = (path: string): string => readFileSync(join(RENDERER, path), 'utf8')
const SECTION = read('settings/SkillsSection.tsx')
const PANEL = read('settings/SettingsPanel.tsx')
const SETUP = read('settings/SetupDialog.tsx')
const NAV = read('settings/settings-nav.tsx')
const MANAGER = read('wm/WindowManager.tsx')

describe('SkillsSection', () => {
  it('has the data attributes', () => {
    expect(SECTION).toContain('data-skills-state=')
    expect(SECTION).toContain('data-skills-action=')
    expect(SECTION).toContain("'install-confirm'")
    expect(SECTION).toContain("'install-cancel'")
    expect(SECTION).toContain('data-skill-name=')
    expect(SECTION).toContain('data-skill-group=')
  })

  it('lists the skills of the status with the group labels', () => {
    expect(SECTION).toContain('status.skills.map(')
    expect(SECTION).toContain('GROUP_LABELS[')
    expect(SECTION).toContain('GROUP_HINT')
  })

  it('confirms the remove and shows the reload note after a change', () => {
    expect(SECTION).toContain('confirm(SKILLS_REMOVE_CONFIRM)')
    expect(SECTION).toMatch(/changed && \([\s\S]*RELOAD_NOTE/)
  })

  it('reads the status one time for each view of Settings', () => {
    expect(SECTION).toContain('readStatus()')
    expect(PANEL).toContain('readSkills')
  })
})

describe('the tab and the providers', () => {
  it('puts the skills tab between live and modules', () => {
    expect(PANEL).toContain("'daily-update',\n  'live',\n  'skills',\n  'modules',\n  'updates',")
    expect(PANEL).toContain('<SkillsSection readStatus={readSkills} />')
    expect(NAV).toContain("| 'skills'")
  })

  it('mounts SkillsProvider inside LiveProvider', () => {
    const live = MANAGER.indexOf('<LiveProvider>')
    const skills = MANAGER.indexOf('<SkillsProvider>')
    expect(live).toBeGreaterThan(-1)
    expect(skills).toBeGreaterThan(live)
    expect(MANAGER.indexOf('</SkillsProvider>')).toBeLessThan(MANAGER.indexOf('</LiveProvider>'))
  })
})

describe('SetupDialog', () => {
  it('has the skills step buttons and waits for the skills status', () => {
    expect(SETUP).toContain("data-setup-action='skip-skills'")
    expect(SETUP).toContain("data-setup-action='install-skills'")
    expect(SETUP).toContain('skills.status !== null')
    expect(SETUP).toContain('nextSetupPhase(')
  })

  it('moves the focus to Skip in the skills step and to Done in the done view', () => {
    expect(SETUP).toContain('skipSkillsRef.current?.focus()')
    expect(SETUP).toContain('doneRef.current?.focus()')
  })

  it('keeps setupOpen true for the skills step and the done view', () => {
    // setSetupOpen follows the open state only. A phase change never closes the dialog.
    expect(SETUP).toMatch(
      /useEffect\(\(\) => \{\s*setSetupOpen\(open\)\s*\}, \[open, setSetupOpen\]\)/,
    )
    const phases = SETUP.match(/setPhase\(([^)]*)\)/g) ?? []
    expect(phases.length).toBeGreaterThan(0)
    expect(SETUP).not.toMatch(/setSetupOpen\((?!open\)|false\))/)
    // Only close() calls setOpen(false).
    expect(SETUP.match(/setOpen\(false\)/g)).toHaveLength(1)
  })
})
