// Source checks of the release notes view. The repository has no DOM test. So this test reads the
// source text of the dialog, of Settings > Updates and of the window manager.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { RELEASE_NOTES_TEXTS } from '../../../src/shared/release-notes'

const SRC = join(__dirname, '../../../src/renderer/src')
const read = (file: string): string => readFileSync(join(SRC, file), 'utf8')
const DIALOG = read('release-notes/ReleaseNotesDialog.tsx')
const SECTION = read('settings/UpdatesSection.tsx')
const NAV = read('settings/settings-nav.tsx')
const WM = read('wm/WindowManager.tsx')
const SETUP = read('settings/SetupDialog.tsx')

describe('the release notes dialog source', () => {
  it('uses the dialog of Base UI with the styles of the app dialogs', () => {
    expect(DIALOG).toContain("import { Dialog } from '@base-ui/react/dialog'")
    expect(DIALOG).toMatch(/DIALOG_BACKDROP[\s\S]*DIALOG_BUTTON[\s\S]*DIALOG_POPUP/)
    expect(DIALOG).toContain('<Dialog.Title')
    expect(DIALOG).toContain('{viewTitle(')
  })

  it('never renders HTML, and gives each text to React as text', () => {
    expect(DIALOG).not.toMatch(/dangerouslySetInnerHTML|innerHTML/)
    expect(DIALOG).toContain('inlineParts(')
    // No link element: each GitHub page opens through the main process.
    expect(DIALOG).not.toMatch(/<a[\s>]|href=/)
  })

  it('opens each GitHub page through the main process with a version or null', () => {
    expect(DIALOG).toMatch(/window\.bifrost\.releaseNotes\s*\.open\(version\)/)
    expect(DIALOG).toContain('openOnGitHub(release.version)')
    expect(DIALOG).toContain('openOnGitHub(null)')
  })

  it("asks for What's new one time after the load, and loads the list only when it opens", () => {
    expect(DIALOG.match(/releaseNotes\.whatsNew\(\)/g)).toHaveLength(1)
    expect(DIALOG.match(/releaseNotes\.list\(\)/g)).toHaveLength(1)
    const open = DIALOG.slice(DIALOG.indexOf('const open = useCallback'))
    expect(open.indexOf('releaseNotes.list()')).toBeGreaterThan(-1)
    expect(DIALOG).toContain('whatsNewMayOpen(ready, settings.setupDone, setupOpen)')
    expect(DIALOG).toContain('const { releaseNotesRequest, setupOpen } = useSettingsNav()')
  })

  it('shows the texts of the states', () => {
    for (const name of ['failed', 'loading', 'internal', 'empty', 'viewOnGitHub', 'releasesPage']) {
      expect(DIALOG, name).toContain(`TEXTS.${name}`)
    }
    expect(DIALOG).toContain('data-release-notes=')
    expect(DIALOG).toContain('data-release-notes-state=')
  })

  it('builds each className with cx or a fixed text, never a template literal', () => {
    expect(DIALOG).not.toMatch(/className=\{`/)
  })

  it('is in the window manager, next to the setup dialog', () => {
    expect(WM).toContain("import ReleaseNotesDialog from '../release-notes/ReleaseNotesDialog'")
    expect(WM).toMatch(/<SetupDialog \/>\s*(\{[^}]*\}\s*)?<ReleaseNotesDialog \/>/)
  })
})

describe('the open state of the setup dialog', () => {
  it('is in the settings nav, so the release notes view can wait for it', () => {
    expect(NAV).toContain('setupOpen: boolean')
    expect(NAV).toContain('setSetupOpen(open: boolean): void')
  })

  it('comes from the setup dialog at each change, and goes back to false when it unmounts', () => {
    expect(SETUP).toContain('const { introRequest, setSetupOpen } = useSettingsNav()')
    expect(SETUP).toMatch(
      /useEffect\(\(\) => \{\s*setSetupOpen\(open\)\s*\}, \[open, setSetupOpen\]\)/,
    )
    expect(SETUP).toMatch(/useEffect\(\(\) => \(\) => setSetupOpen\(false\), \[setSetupOpen\]\)/)
  })
})

describe('the Release notes button', () => {
  it('asks the settings nav to show the release notes', () => {
    expect(NAV).toContain('releaseNotesRequest: number')
    expect(NAV).toContain('showReleaseNotes(): void')
    expect(NAV).toContain('setReleaseNotesRequest(n => n + 1)')
  })

  it('is in Settings > Updates, also in a build that does not update itself', () => {
    expect(RELEASE_NOTES_TEXTS.button).toBe('Release notes')
    expect(SECTION).toContain('data-updates-release-notes={true}')
    expect(SECTION).toContain('onClick={showReleaseNotes}')
    expect(SECTION).toContain('{RELEASE_NOTES_TEXTS.button}')
    expect(SECTION).not.toContain('updatesActions(snapshot).length > 0')
  })
})

describe('RELEASE_NOTES_TEXTS', () => {
  it('has friendly texts with no em dash', () => {
    expect(RELEASE_NOTES_TEXTS).toMatchObject({
      failed: "Couldn't load the release notes.",
      internal: 'Small internal changes.',
      title: 'Release notes',
      viewOnGitHub: 'View on GitHub',
      whatsNew: "What's new",
    })
    for (const text of Object.values(RELEASE_NOTES_TEXTS)) {
      expect(text).not.toContain(String.fromCharCode(0x2014))
    }
  })
})
