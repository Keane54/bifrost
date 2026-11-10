import { describe, expect, it } from 'vitest'
import {
  claudeVersionLine,
  claudeVersionNotice,
  hasWarning,
  INTRO_CHANGE_NOTE,
  introStateLine,
  LIVE_ABOUT,
  LIVE_VERSION_NOTE,
  liveActions,
  liveNotice,
  liveStateLine,
  liveSteps,
  liveVersionNote,
  oldInstallNote,
  RELOAD_NOTE,
  REMOVE_CONFIRM,
  SETUP_INTRO,
  setupChosen,
  setupView,
  shouldShowSetup,
  skipSavesChoice,
  unknownStatus,
  VERSION_CHECK_FAILED,
  versionNotice,
  WITHOUT_LIVE,
} from '../../../src/renderer/src/settings/live-notice'
import type { ClaudeVersion, LiveStatus } from '../../../src/shared/types'

const status = (patch: Partial<LiveStatus> = {}): LiveStatus => ({
  claudeVersion: '2.1.300',
  listening: true,
  liveSessions: 0,
  modCurrent: true,
  oldInstall: false,
  plugin: 'enabled',
  versionOk: true,
  ...patch,
})
const GOOD: ClaudeVersion = { minimum: '2.1.281', ok: true, version: '2.1.300' }
const OLD_STEP =
  "Remove Bifrost's old hooks and statusLine wrapper from ~/.claude/settings.json. Your other hooks stay, and Bifrost saves a backup first."
const COPY_STEP = 'Copy the Live details plugin files to the folder ~/.bifrost/mod.'
const PLUGIN_STEP =
  'Add that folder as the plugin marketplace "bifrost-local", then install the plugin "bifrost-live" for your user with claude plugin.'

describe('live notice', () => {
  it('keeps the texts that the plan gives', () => {
    expect(RELOAD_NOTE).toBe(
      'Sessions that run now get the change after /reload-plugins or a restart.',
    )
    expect(WITHOUT_LIVE).toBe(
      'Without Live details, Bifrost still lists your sessions and shows their boxes from the session list, a little later, but with no model, context % or cost. You can turn it on later in Settings > Live details.',
    )
    expect(SETUP_INTRO).toBe(
      "Live details lets Bifrost see each session as it happens: a box the moment Claude finishes or needs you, plus the model, context % and cost. It's a small Claude Code plugin that sends events to Bifrost on this Mac. Bifrost makes these changes only if you turn it on:",
    )
    expect(REMOVE_CONFIRM).toEqual({
      body: 'Bifrost turns off Live details, removes the plugin and the folder ~/.bifrost/mod, and removes any old Bifrost hooks (with a backup first).',
      confirm: 'Remove',
      title: 'Remove Live details',
    })
  })

  it('liveNotice gives loading, not-installed, off and on', () => {
    expect(liveNotice(null)).toEqual({ kind: 'loading' })
    expect(liveNotice(status({ plugin: 'not-installed' }))).toEqual({ kind: 'not-installed' })
    expect(liveNotice(status({ listening: false, plugin: 'disabled' }))).toEqual({ kind: 'off' })
    expect(liveNotice(status({ liveSessions: 2 }))).toEqual({ kind: 'on', sessions: 2 })
  })

  it('liveNotice gives problem for unknown, for no listener and for files that do not match', () => {
    expect(
      liveNotice(status({ error: 'claude plugin list failed: x', plugin: 'unknown' })),
    ).toEqual({ kind: 'problem', message: 'claude plugin list failed: x' })
    expect(liveNotice(status({ plugin: 'unknown' }))).toEqual({
      kind: 'problem',
      message: "Bifrost couldn't check Live details.",
    })
    expect(
      liveNotice(
        status({ error: 'Another program listens on /h/.bifrost/live.sock.', listening: false }),
      ),
    ).toEqual({ kind: 'problem', message: 'Another program listens on /h/.bifrost/live.sock.' })
    expect(liveNotice(status({ listening: false }))).toEqual({
      kind: 'problem',
      message: "Live details is on, but Bifrost isn't receiving it. Try Turn off, then Turn on.",
    })
    expect(liveNotice(status({ error: 'x', modCurrent: false }))).toEqual({
      kind: 'problem',
      message:
        "Live details uses files that don't match this Bifrost. Remove it, then install it again.",
    })
  })

  it('unknownStatus gives a problem with the reason and Try again', () => {
    const failed = unknownStatus('Bifrost cannot read the status.')
    expect(liveNotice(failed)).toEqual({
      kind: 'problem',
      message: 'Bifrost cannot read the status.',
    })
    expect(liveActions(failed)).toEqual(['retry'])
    expect(liveVersionNote(failed)).toBeNull()
    expect(oldInstallNote(failed)).toBeNull()
  })

  it('oldInstallNote shows only for an old hook install', () => {
    expect(oldInstallNote(status({ oldInstall: true }))).toBe(
      'Bifrost found its old hooks in ~/.claude/settings.json. Install or Turn on removes them first and saves a backup.',
    )
    expect(oldInstallNote(status({ oldInstall: false }))).toBeNull()
    expect(oldInstallNote(null)).toBeNull()
  })

  it('liveSteps lists the old hook removal only when oldInstall is true', () => {
    expect(liveSteps(status({ oldInstall: true, plugin: 'not-installed' }))).toEqual([
      OLD_STEP,
      COPY_STEP,
      PLUGIN_STEP,
    ])
    expect(liveSteps(status({ oldInstall: false, plugin: 'not-installed' }))).toEqual([
      COPY_STEP,
      PLUGIN_STEP,
    ])
  })

  it('versionNotice gives the two warnings and null for a good version', () => {
    expect(versionNotice({ minimum: '2.1.281', ok: false, version: '2.1.200' })).toBe(
      'Claude Code 2.1.200 is older than 2.1.281, which Bifrost needs. Please update Claude Code.',
    )
    expect(versionNotice({ minimum: '2.1.281', ok: false, version: null })).toBe(
      "Bifrost can't find Claude Code. Check that the claude command works in a terminal.",
    )
    expect(versionNotice(GOOD)).toBeNull()
    // The version is not loaded yet.
    expect(versionNotice(null)).toBeNull()
  })

  it('a failed version check gives its own notice and a warning', () => {
    expect(VERSION_CHECK_FAILED).toBe("Bifrost couldn't check the Claude Code version.")
    expect(claudeVersionNotice(null, true)).toBe(VERSION_CHECK_FAILED)
    expect(claudeVersionNotice(null, false)).toBeNull()
    expect(claudeVersionNotice(GOOD, false)).toBeNull()
    expect(claudeVersionNotice({ ...GOOD, ok: false, version: '2.1.200' }, false)).toBe(
      versionNotice({ ...GOOD, ok: false, version: '2.1.200' }),
    )
    expect(hasWarning(status(), null, true)).toBe(true)
    expect(hasWarning(status(), null, false)).toBe(false)
  })

  it('claudeVersionLine gives the version, a check line or nothing', () => {
    expect(claudeVersionLine(GOOD, false)).toBe('Claude Code 2.1.300')
    expect(claudeVersionLine(null, false)).toBe('Checking Claude Code...')
    // A failed check does not say "Checking" for ever. The notice gives the reason.
    expect(claudeVersionLine(null, true)).toBeNull()
    // Without a version, versionNotice says that Bifrost can't find Claude Code.
    expect(claudeVersionLine({ ...GOOD, ok: false, version: null }, false)).toBeNull()
  })

  it('liveVersionNote shows when Claude Code is too old for Live details', () => {
    expect(LIVE_VERSION_NOTE).toBe('Live details needs Claude Code 2.1.290 or later.')
    expect(liveVersionNote(status({ claudeVersion: '2.1.285', versionOk: false }))).toBe(
      LIVE_VERSION_NOTE,
    )
    expect(liveVersionNote(status({ claudeVersion: '2.1.290', versionOk: true }))).toBeNull()
    // With no version, versionNotice already says that Bifrost can't find Claude Code.
    expect(liveVersionNote(status({ claudeVersion: null, versionOk: false }))).toBeNull()
    expect(liveVersionNote(null)).toBeNull()
  })

  it('hasWarning is true for a problem, an old install, a version notice or an old version', () => {
    expect(hasWarning(null, null)).toBe(false)
    expect(hasWarning(null, GOOD)).toBe(false)
    expect(hasWarning(status(), GOOD)).toBe(false)
    expect(hasWarning(status({ plugin: 'not-installed' }), GOOD)).toBe(false)
    expect(hasWarning(status({ plugin: 'disabled' }), GOOD)).toBe(false)
    expect(hasWarning(status({ plugin: 'unknown' }), GOOD)).toBe(true)
    expect(hasWarning(status({ listening: false }), GOOD)).toBe(true)
    expect(hasWarning(status({ modCurrent: false }), GOOD)).toBe(true)
    expect(hasWarning(status({ oldInstall: true, plugin: 'not-installed' }), GOOD)).toBe(true)
    expect(hasWarning(null, { ...GOOD, ok: false, version: '2.1.200' })).toBe(true)
    expect(hasWarning(null, { ...GOOD, ok: false, version: null })).toBe(true)
    // An old version for Live details warns only when the plugin is installed (D11: after Skip,
    // Live details off is the choice of the user).
    const old = { claudeVersion: '2.1.285', versionOk: false }
    expect(hasWarning(status({ ...old, plugin: 'enabled' }), GOOD)).toBe(true)
    expect(hasWarning(status({ ...old, listening: false, plugin: 'disabled' }), GOOD)).toBe(true)
    expect(hasWarning(status({ ...old, plugin: 'not-installed' }), GOOD)).toBe(false)
  })

  it('liveStateLine gives the state line of each notice', () => {
    expect(liveStateLine({ kind: 'loading' })).toBe('Checking Live details...')
    expect(liveStateLine({ kind: 'not-installed' })).toBe('Not installed.')
    expect(liveStateLine({ kind: 'off' })).toBe('Off.')
    expect(liveStateLine({ kind: 'on', sessions: 0 })).toBe(
      'On. 0 sessions are sending live details.',
    )
    expect(liveStateLine({ kind: 'on', sessions: 1 })).toBe(
      'On. 1 session is sending live details.',
    )
    expect(liveStateLine({ kind: 'on', sessions: 3 })).toBe(
      'On. 3 sessions are sending live details.',
    )
    expect(liveStateLine({ kind: 'problem', message: 'm' })).toBe('m')
  })

  it('liveActions gives the buttons of each state', () => {
    expect(liveActions(null)).toEqual([])
    expect(liveActions(status({ plugin: 'not-installed' }))).toEqual(['install'])
    expect(liveActions(status({ listening: false, plugin: 'disabled' }))).toEqual([
      'enable',
      'remove',
    ])
    expect(liveActions(status())).toEqual(['disable', 'remove'])
    expect(liveActions(status({ plugin: 'unknown' }))).toEqual(['retry'])
    expect(liveActions(status({ listening: false }))).toEqual(['disable', 'enable', 'remove'])
    expect(liveActions(status({ modCurrent: false }))).toEqual(['disable', 'enable', 'remove'])
  })

  it('shouldShowSetup is true only before setup, for not-installed and unknown', () => {
    const before = { setupDone: false }
    const after = { setupDone: true }
    expect(shouldShowSetup(before, status({ plugin: 'not-installed' }))).toBe(true)
    expect(shouldShowSetup(before, status({ plugin: 'unknown' }))).toBe(true)
    expect(shouldShowSetup(before, status({ plugin: 'enabled' }))).toBe(false)
    expect(shouldShowSetup(before, status({ plugin: 'disabled' }))).toBe(false)
    expect(shouldShowSetup(before, null)).toBe(false)
    expect(shouldShowSetup(after, status({ plugin: 'not-installed' }))).toBe(false)
    expect(shouldShowSetup(after, status({ plugin: 'unknown' }))).toBe(false)
  })

  it('setupChosen is true only for enabled and disabled', () => {
    expect(setupChosen(status({ plugin: 'enabled' }))).toBe(true)
    expect(setupChosen(status({ plugin: 'disabled' }))).toBe(true)
    expect(setupChosen(status({ plugin: 'not-installed' }))).toBe(false)
    expect(setupChosen(status({ plugin: 'unknown' }))).toBe(false)
    expect(setupChosen(null)).toBe(false)
  })
})

// The introduction again from Settings > General (spec 11.1).
describe('the introduction again', () => {
  it('the intro text starts with the text about Live details', () => {
    expect(LIVE_ABOUT).toBe(
      "Live details lets Bifrost see each session as it happens: a box the moment Claude finishes or needs you, plus the model, context % and cost. It's a small Claude Code plugin that sends events to Bifrost on this Mac.",
    )
    expect(SETUP_INTRO.startsWith(`${LIVE_ABOUT} `)).toBe(true)
    expect(INTRO_CHANGE_NOTE).toBe('You can change this in Settings > Live details.')
  })

  it('at the first start, the dialog keeps its choice, also for an installed plugin', () => {
    expect(setupView('first', 'ask', status({ plugin: 'not-installed' }))).toBe('ask')
    expect(setupView('first', 'ask', status({ plugin: 'enabled' }))).toBe('ask')
    expect(setupView('first', 'done', status())).toBe('done')
    expect(setupView('first', 'skills', status())).toBe('skills')
    expect(setupView('again', 'skills', status({ plugin: 'enabled' }))).toBe('skills')
  })

  it('again, an installed plugin gives its state and Done, not an install', () => {
    expect(setupView('again', 'ask', status({ plugin: 'enabled' }))).toBe('installed')
    expect(setupView('again', 'ask', status({ listening: false, plugin: 'disabled' }))).toBe(
      'installed',
    )
    expect(setupView('again', 'ask', status({ plugin: 'not-installed' }))).toBe('ask')
    expect(setupView('again', 'ask', status({ plugin: 'unknown' }))).toBe('ask')
    expect(setupView('again', 'ask', null)).toBe('ask')
    expect(setupView('again', 'done', status())).toBe('done')
  })

  it('Skip saves the choice only at the first start', () => {
    expect(skipSavesChoice('first')).toBe(true)
    expect(skipSavesChoice('again')).toBe(false)
  })

  it('introStateLine names Live details, except in a problem message', () => {
    expect(introStateLine({ kind: 'on', sessions: 2 })).toBe(
      'Live details: On. 2 sessions are sending live details.',
    )
    expect(introStateLine({ kind: 'off' })).toBe('Live details: Off.')
    expect(introStateLine({ kind: 'problem', message: 'm' })).toBe('m')
  })
})
