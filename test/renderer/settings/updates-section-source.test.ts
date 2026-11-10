import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  UPDATES_ROWS,
  updatesActions,
  updatesStateLine,
} from '../../../src/renderer/src/settings/updates-rows'
import { EMPTY_UPDATES, type UpdatesSnapshot } from '../../../src/shared/updates'

// The repository has no DOM test. So this test reads the source text of the section.
const SETTINGS = join(__dirname, '../../../src/renderer/src/settings')
const SECTION = readFileSync(join(SETTINGS, 'UpdatesSection.tsx'), 'utf8')
const PANEL = readFileSync(join(SETTINGS, 'SettingsPanel.tsx'), 'utf8')

const base: UpdatesSnapshot = { ...EMPTY_UPDATES, available: true, version: '1.1.0' }
const withState = (state: UpdatesSnapshot['state'], more: Partial<UpdatesSnapshot> = {}) => ({
  ...base,
  ...more,
  state,
})

describe('UPDATES_ROWS', () => {
  it('has the label of the switch', () => {
    expect(UPDATES_ROWS).toEqual({ auto: 'Check for updates automatically' })
  })
})

describe('updatesStateLine', () => {
  it('gives the line of each state', () => {
    expect(updatesStateLine(withState({ kind: 'idle' }))).toBe("You're up to date.")
    expect(updatesStateLine(withState({ kind: 'checking' }))).toBe('Checking for updates…')
    expect(
      updatesStateLine(withState({ kind: 'downloading', percent: 42, version: '1.2.0' })),
    ).toBe('Downloading Bifrost 1.2.0 (42%)…')
    expect(updatesStateLine(withState({ kind: 'ready', version: '1.2.0' }))).toBe(
      'Bifrost 1.2.0 is ready.',
    )
    expect(
      updatesStateLine(withState({ at: 1, cause: 'location', kind: 'failed', message: 'Text.' })),
    ).toBe('Text.')
    expect(updatesStateLine(withState({ kind: 'off' }))).toBe('Automatic updates are off.')
  })

  it('says the build does not update itself when it is not available', () => {
    expect(updatesStateLine({ ...base, available: false })).toBe(
      "This build doesn't update itself.",
    )
  })
})

describe('updatesActions', () => {
  it('shows check and show-log for an idle state', () => {
    expect(updatesActions(withState({ kind: 'idle' }))).toEqual(['check', 'show-log'])
  })

  it('adds restart for ready and retry for failed', () => {
    expect(updatesActions(withState({ kind: 'ready', version: '1.2.0' }))).toEqual([
      'check',
      'restart',
      'show-log',
    ])
    expect(
      updatesActions(withState({ at: 1, cause: 'download', kind: 'failed', message: 'x' })),
    ).toEqual(['check', 'retry', 'show-log'])
  })

  it('shows no button when the build cannot update', () => {
    expect(updatesActions({ ...base, available: false })).toEqual([])
  })
})

describe('Settings > Updates source', () => {
  it('has a CheckRow with the label from UPDATES_ROWS that saves autoUpdate', () => {
    expect(SECTION).toMatch(/<CheckRow[\s\S]*?label=\{UPDATES_ROWS\.auto\}/)
    expect(SECTION).toContain('update({ autoUpdate: value })')
    expect(SECTION).not.toMatch(/label='/)
  })

  it('has the status block, the version and the last check', () => {
    expect(SECTION).toContain('data-updates-state=')
    expect(SECTION).toContain('Version {')
    expect(SECTION).toContain('Last checked')
    expect(SECTION).toContain('lastCheckAt')
  })

  it('has the buttons with DIALOG_BUTTON and data-updates-action', () => {
    expect(SECTION).toContain('data-updates-action={id}')
    expect(SECTION).toContain('DIALOG_BUTTON')
    expect(SECTION).toContain('showLog()')
    expect(SECTION).toContain('<ErrorLine')
  })

  it('is registered in the panel with a warning square for the failed state', () => {
    expect(PANEL).toContain("'updates'")
    expect(PANEL).toContain('<UpdatesSection')
    expect(PANEL).toMatch(/id === 'updates' && updatesFailed[\s\S]*?data-settings-warning/)
    expect(PANEL).toContain("kind === 'failed'")
  })
})
