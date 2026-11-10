import { describe, expect, it } from 'vitest'
import { causeText, EMPTY_UPDATES, UPDATE_TEXTS, type UpdateCause } from '../../src/shared/updates'

describe('UPDATE_TEXTS', () => {
  it('holds the fixed texts', () => {
    expect(UPDATE_TEXTS.ready('0.3.1')).toBe('Bifrost 0.3.1 is available, click to update.')
    expect(UPDATE_TEXTS.failed).toBe('Update failed. Click for details.')
    expect(UPDATE_TEXTS.notifyTitle).toBe('Bifrost update ready')
    expect(UPDATE_TEXTS.switchLabel).toBe('Check for updates automatically')
    expect(UPDATE_TEXTS.check).toBe('Check for updates')
    expect(UPDATE_TEXTS.restart).toBe('Restart to update')
    expect(UPDATE_TEXTS.retry).toBe('Try again')
    expect(UPDATE_TEXTS.showLog).toBe('Show log')
  })
})

describe('EMPTY_UPDATES', () => {
  it('starts idle and unavailable', () => {
    expect(EMPTY_UPDATES).toEqual({
      available: false,
      lastCheckAt: null,
      state: { kind: 'idle' },
      version: '',
    })
  })
})

describe('causeText', () => {
  it('asks for a gh sign-in', () => {
    expect(causeText('gh-logged-out', '')).toBe('Sign in with gh auth login to get updates.')
    expect(causeText('gh-missing', '')).toBe(
      'Install the GitHub CLI (gh) first. Sign in with gh auth login to get updates.',
    )
  })
  it('names the other fixed causes', () => {
    expect(causeText('location', '')).toBe(
      'Move Bifrost to the Applications folder to get updates.',
    )
    expect(causeText('no-access', '')).toBe("Your GitHub account can't read the Bifrost releases.")
  })
  it('includes the detail for download, install and github', () => {
    for (const cause of ['download', 'install', 'github'] as UpdateCause[]) {
      expect(causeText(cause, 'boom')).toContain('"boom"')
    }
  })
  it('stays friendly without a detail', () => {
    for (const cause of ['download', 'install', 'github'] as UpdateCause[]) {
      expect(causeText(cause, '')).not.toContain('""')
    }
  })
})
