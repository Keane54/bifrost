// The rules of the release notes view. One view has two titles: "What's new" when it opens by
// itself after an update, and "Release notes" when the user opens it from Settings > Updates.
import {
  RELEASE_NOTES_TEXTS,
  type Release,
  type WhatsNewStart,
  whatsNewReleases,
} from '../../../shared/release-notes'

export type ReleaseNotesView = { kind: 'whats-new'; start: WhatsNewStart } | { kind: 'all' }

// The most releases that Release notes shows.
const MAX_SHOWN = 10

export function viewTitle(view: ReleaseNotesView): string {
  return view.kind === 'whats-new' ? RELEASE_NOTES_TEXTS.whatsNew : RELEASE_NOTES_TEXTS.title
}

// The releases of the view, newest first.
export function viewReleases(view: ReleaseNotesView, releases: readonly Release[]): Release[] {
  if (view.kind === 'whats-new') return whatsNewReleases(releases, view.start)
  return releases.slice(0, MAX_SHOWN)
}

// True for a release with no summary and no shown section. The view then shows
// RELEASE_NOTES_TEXTS.internal.
export function internalOnly(release: Release): boolean {
  return release.summary === '' && release.sections.length === 0
}

// "10 Nov 2026", or an empty text for a date that the view cannot read. A time zone argument is
// for tests.
export function formatReleaseDate(iso: string, timeZone?: string): string {
  const at = Date.parse(iso)
  if (Number.isNaN(at)) return ''
  return new Intl.DateTimeFormat('en-GB', {
    day: 'numeric',
    month: 'short',
    timeZone,
    year: 'numeric',
  }).format(at)
}

// What's new waits for the settings, for the setup choice and for the close of the setup dialog.
// The setup dialog stays open in its done phase after it saves setupDone. So the check of
// setupDone alone is not sufficient, and What's new must also wait for setupOpen to be false.
export function whatsNewMayOpen(
  settingsReady: boolean,
  setupDone: boolean,
  setupOpen: boolean,
): boolean {
  return settingsReady && setupDone && !setupOpen
}
