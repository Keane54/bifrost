// Pure parsers for the GitHub releases of Bifrost. This file has no Electron import.
// semantic-release writes each body (.releaserc.json): the summary of the Release workflow, a
// "## <version>" heading, and a "### <Title>" heading for each section. Each item of a section is
// a line "* **scope:** text ([hash](url))", or the same line with no scope.

import { isRecord } from '../../shared/plain-object'
import {
  compareVersions,
  parseVersion,
  type Release,
  type ReleaseItem,
  type ReleaseSection,
} from '../../shared/release-notes'
import { UPDATE_OWNER, UPDATE_REPO } from '../updates/updater'

// The maximum number of releases that the app keeps from one answer.
export const MAX_RELEASES = 10

// The sections that the app shows, with their friendly names. The app hides each other section,
// for example Documentation, Code Refactoring and Tests. The app shows the breaking changes as
// "Changed" (user decision, 2026-11-10). The conventionalcommits preset puts a warning sign
// before that title.
export const SHOWN_SECTIONS: Readonly<Record<string, string>> = {
  'BREAKING CHANGES': 'Changed',
  'Bug Fixes': 'Fixed',
  Features: 'New',
  'Performance Improvements': 'Faster',
  Reverts: 'Reverted',
  '⚠ BREAKING CHANGES': 'Changed',
}

// The order of the shown sections. Changed is always first.
const SHOWN_ORDER: readonly string[] = ['Changed', 'New', 'Fixed', 'Faster', 'Reverted']

// Each release page starts with this text. The app opens only these pages.
export const RELEASE_URL_PREFIX = `https://github.com/${UPDATE_OWNER}/${UPDATE_REPO}/releases/`

const VERSION_HEADING = /^## /
const SECTION_HEADING = /^### (.*)$/
// An item line starts with "* " or "- " with no indent.
const ITEM = /^[*-] (.*)$/
const SCOPE = /^\*\*(.+?):\*\*\s+(.*)$/
// The commit link at the end of an item, and all text after it, for example ", closes [#12](..)".
const COMMIT_LINK = /\s*\(\[[0-9a-f]{7,40}\]\([^)\s]*\)\).*$/

export interface BodyParts {
  // The text before the first "## " or "### " heading, trimmed.
  summary: string
  // Each "### " section with its original title.
  sections: ReleaseSection[]
}

function parseItem(line: string): ReleaseItem | null {
  const match = ITEM.exec(line)
  if (match === null) return null
  const text = (match[1] ?? '').replace(COMMIT_LINK, '').trim()
  const scoped = SCOPE.exec(text)
  if (scoped !== null) {
    const rest = (scoped[2] ?? '').trim()
    return rest === '' ? null : { scope: (scoped[1] ?? '').trim(), text: rest }
  }
  return text === '' ? null : { scope: null, text }
}

// Split a release body into the summary and the sections. Lines that are not items are ignored.
export function splitBody(body: string): BodyParts {
  const lines = body.replace(/\r\n?/g, '\n').split('\n')
  const summaryLines: string[] = []
  const sections: ReleaseSection[] = []
  let inSummary = true
  let current: ReleaseSection | null = null
  for (const line of lines) {
    const heading = SECTION_HEADING.exec(line)
    if (heading !== null) {
      inSummary = false
      current = { items: [], title: (heading[1] ?? '').trim() }
      sections.push(current)
      continue
    }
    if (VERSION_HEADING.test(line)) {
      inSummary = false
      current = null
      continue
    }
    if (inSummary) {
      summaryLines.push(line)
      continue
    }
    const item = current === null ? null : parseItem(line)
    if (item !== null) current?.items.push(item)
  }
  return { sections, summary: summaryLines.join('\n').trim() }
}

// The sections that the app shows, with their friendly names, in the order of SHOWN_ORDER. Two
// sections with the same friendly name become one section. A section with no item does not show.
export function shownSections(sections: readonly ReleaseSection[]): ReleaseSection[] {
  const byTitle = new Map<string, ReleaseSection>()
  for (const section of sections) {
    const title = Object.hasOwn(SHOWN_SECTIONS, section.title)
      ? SHOWN_SECTIONS[section.title]
      : undefined
    if (title === undefined || section.items.length === 0) continue
    const items = [...(byTitle.get(title)?.items ?? []), ...section.items]
    byTitle.set(title, { items, title })
  }
  return SHOWN_ORDER.flatMap(title => byTitle.get(title) ?? [])
}

// The summary and the shown sections of a release body.
export function parseReleaseBody(body: string): BodyParts {
  const { summary, sections } = splitBody(body)
  return { sections: shownSections(sections), summary }
}

// One release of the answer, or null for a draft, a prerelease or an entry that the app cannot
// read.
function parseRelease(raw: unknown): Release | null {
  if (!isRecord(raw) || raw.draft === true || raw.prerelease === true) return null
  const { body, html_url: url, published_at: date, tag_name: tag } = raw
  if (typeof tag !== 'string' || typeof url !== 'string' || typeof date !== 'string') return null
  const version = parseVersion(tag)
  if (version === null || version.pre.length > 0) return null
  if (!url.startsWith(RELEASE_URL_PREFIX) || Number.isNaN(Date.parse(date))) return null
  if (body !== null && body !== undefined && typeof body !== 'string') return null
  return {
    date,
    url,
    version: version.core.join('.'),
    ...parseReleaseBody(body ?? ''),
  }
}

// The releases of a GitHub answer, newest version first, at most MAX_RELEASES. An answer that is
// not a list gives null.
export function parseReleases(data: unknown): Release[] | null {
  if (!Array.isArray(data)) return null
  const releases: Release[] = []
  for (const raw of data) {
    const release = parseRelease(raw)
    if (release !== null) releases.push(release)
  }
  releases.sort((a, b) => compareVersions(b.version, a.version) ?? 0)
  return releases.slice(0, MAX_RELEASES)
}
