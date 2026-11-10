// The checks of the update files that verify:release uses.
import { describe, expect, it } from 'vitest'
import { feedSha512, namesRepo } from '../../scripts/release/feed'

const ZIP = 'Bifrost-1.2.0-arm64-mac.zip'

// A latest-mac.yml as electron-builder writes it. The ZIP entry has a blockMapSize line, and the
// DMG entry has its own sha512.
const FEED = `version: 1.2.0
files:
  - url: ${ZIP}
    blockMapSize: 1234
    sha512: zipSha==
    size: 100
  - url: Bifrost-arm64.dmg
    sha512: dmgSha==
    size: 200
path: ${ZIP}
sha512: zipSha==
releaseDate: '2026-11-10T10:00:00.000Z'
`

describe('feedSha512', () => {
  it('finds the sha512 of the entry also when it is not the line after the url', () => {
    expect(feedSha512(FEED, ZIP)).toBe('zipSha==')
  })

  it('reads only the lines of the entry of the url', () => {
    expect(feedSha512(FEED, 'Bifrost-arm64.dmg')).toBe('dmgSha==')
    const noSha = FEED.replace('    sha512: zipSha==\n', '')
    // The sha512 of the DMG entry and the top-level sha512 are not the sha512 of the ZIP.
    expect(feedSha512(noSha, ZIP)).toBeNull()
  })

  it('accepts only an entry that starts with "- url:"', () => {
    expect(feedSha512(`url: ${ZIP}\nsha512: zipSha==\n`, ZIP)).toBeNull()
    expect(feedSha512(FEED, 'Bifrost-1.1.0-arm64-mac.zip')).toBeNull()
    expect(feedSha512('', ZIP)).toBeNull()
  })

  it('reads an entry with no indent before the dash', () => {
    const flat = `files:\n- url: ${ZIP}\n  size: 100\n  sha512: zipSha==\npath: ${ZIP}\n`
    expect(feedSha512(flat, ZIP)).toBe('zipSha==')
  })
})

describe('namesRepo', () => {
  const appUpdate = 'owner: Keane54\nrepo: bifrost\nprovider: github\n'

  it('is true when app-update.yml has the owner and the repo', () => {
    expect(namesRepo(appUpdate, 'Keane54', 'bifrost')).toBe(true)
  })

  it('is false for another owner or repo, or a missing file', () => {
    expect(namesRepo(appUpdate, 'Other', 'bifrost')).toBe(false)
    expect(namesRepo(appUpdate, 'Keane54', 'other')).toBe(false)
    expect(namesRepo('owner: Keane54x\nrepo: bifrost\n', 'Keane54', 'bifrost')).toBe(false)
    expect(namesRepo('', 'Keane54', 'bifrost')).toBe(false)
  })
})
