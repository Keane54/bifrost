// Types, texts and pure rules for the release notes and What's new.
// Main and renderer both import this file. It has no Electron or Node import.

// One line of a section. The scope is the part in bold before the colon, or null.
export interface ReleaseItem {
  scope: string | null
  text: string
}

// A section that the app shows, with its friendly title, for example "New".
export interface ReleaseSection {
  title: string
  items: ReleaseItem[]
}

// One GitHub release. The main process parses the body. The page never gets the raw body.
export interface Release {
  // The version from the tag, with no "v".
  version: string
  // The published_at time of GitHub, as an ISO text.
  date: string
  // The page of the release on GitHub.
  url: string
  // The text before the first heading of the body. It can be empty.
  summary: string
  sections: ReleaseSection[]
}

export type ReleaseNotesResult = { ok: true; releases: Release[] } | { ok: false }

// The versions of a What's new view: the releases after since, up to and including version.
// since is null for the first version with What's new. The view then shows only version.
export interface WhatsNewStart {
  since: string | null
  version: string
}

export const RELEASE_NOTES_TEXTS = {
  button: 'Release notes',
  close: 'Close',
  empty: 'There are no release notes to show yet.',
  failed: "Couldn't load the release notes.",
  internal: 'Small internal changes.',
  loading: 'Loading the release notes…',
  releasesPage: 'Open the Releases page on GitHub',
  title: 'Release notes',
  viewOnGitHub: 'View on GitHub',
  whatsNew: "What's new",
}

export interface Version {
  core: [number, number, number]
  // The dot parts of the pre-release, for example ['beta', '2']. Empty for a release.
  pre: string[]
}

const NUMBER = '(0|[1-9]\\d*)'
// The pre-release part, for example "-beta.2", and the build part, for example "+abc".
const PRE = '(?:-([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?'
const BUILD = '(?:\\+[0-9A-Za-z.-]+)?'
const VERSION = new RegExp(`^v?${NUMBER}\\.${NUMBER}\\.${NUMBER}${PRE}${BUILD}$`)

// The parts of a semver version, with or without a "v". A text that is not a version gives null.
export function parseVersion(text: string): Version | null {
  const match = VERSION.exec(text)
  if (match === null) return null
  return {
    core: [Number(match[1]), Number(match[2]), Number(match[3])],
    pre: match[4] === undefined ? [] : match[4].split('.'),
  }
}

// Compare two pre-release parts as semver does. A number part comes before a text part.
function comparePart(a: string, b: string): number {
  const aNumber = /^\d+$/.test(a)
  const bNumber = /^\d+$/.test(b)
  if (aNumber && bNumber) return Number(a) - Number(b)
  if (aNumber !== bNumber) return aNumber ? -1 : 1
  return a < b ? -1 : a > b ? 1 : 0
}

// Less than 0 when a comes before b, 0 for the same version, more than 0 when a comes after b.
// The rules are those of semver: the build part has no effect, and a pre-release comes before
// its release. null when a value is not a version.
export function compareVersions(a: string, b: string): number | null {
  const left = parseVersion(a)
  const right = parseVersion(b)
  if (left === null || right === null) return null
  for (let i = 0; i < 3; i += 1) {
    const diff = left.core[i] - right.core[i]
    if (diff !== 0) return diff
  }
  if (left.pre.length === 0 || right.pre.length === 0) {
    return right.pre.length - left.pre.length
  }
  const count = Math.min(left.pre.length, right.pre.length)
  for (let i = 0; i < count; i += 1) {
    const diff = comparePart(left.pre[i] ?? '', right.pre[i] ?? '')
    if (diff !== 0) return diff
  }
  return left.pre.length - right.pre.length
}

// The releases of a What's new view, in the order of the list.
export function whatsNewReleases(releases: readonly Release[], start: WhatsNewStart): Release[] {
  return releases.filter(release => {
    const toCurrent = compareVersions(release.version, start.version)
    if (toCurrent === null || toCurrent > 0) return false
    if (start.since === null) return toCurrent === 0
    const toSince = compareVersions(release.version, start.since)
    return toSince !== null && toSince > 0
  })
}
