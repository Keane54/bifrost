import { describe, expect, it } from 'vitest'
import {
  compareVersions,
  parseVersion,
  type Release,
  whatsNewReleases,
} from '../../src/shared/release-notes'

function release(version: string): Release {
  return {
    date: '2026-11-10T18:10:26Z',
    sections: [],
    summary: '',
    url: `https://github.com/Keane54/bifrost/releases/tag/v${version}`,
    version,
  }
}

describe('parseVersion', () => {
  it('reads a version with or without a v', () => {
    expect(parseVersion('0.4.0')).toEqual({ core: [0, 4, 0], pre: [] })
    expect(parseVersion('v12.30.7')).toEqual({ core: [12, 30, 7], pre: [] })
  })

  it('reads the pre-release part and ignores the build part', () => {
    expect(parseVersion('1.0.0-beta.2+build.5')).toEqual({ core: [1, 0, 0], pre: ['beta', '2'] })
  })

  it('gives null for a text that is not a version', () => {
    for (const bad of [
      '',
      '1',
      '1.2',
      '1.2.3.4',
      'x.y.z',
      '01.2.3',
      '1.2.3-',
      ' 1.2.3',
      'latest',
    ]) {
      expect(parseVersion(bad), bad).toBeNull()
    }
  })
})

describe('compareVersions', () => {
  it('compares each number as a number, not as text', () => {
    expect(compareVersions('0.10.0', '0.9.0')).toBeGreaterThan(0)
    expect(compareVersions('0.9.0', '0.10.0')).toBeLessThan(0)
    expect(compareVersions('1.0.0', '0.99.99')).toBeGreaterThan(0)
    expect(compareVersions('0.4.1', '0.4.0')).toBeGreaterThan(0)
  })

  it('gives 0 for the same version, also with a v or a build part', () => {
    expect(compareVersions('0.4.0', '0.4.0')).toBe(0)
    expect(compareVersions('v0.4.0', '0.4.0')).toBe(0)
    expect(compareVersions('0.4.0+abc', '0.4.0')).toBe(0)
  })

  it('puts a pre-release before its release, as semver does', () => {
    expect(compareVersions('1.0.0-alpha', '1.0.0')).toBeLessThan(0)
    expect(compareVersions('1.0.0-alpha', '1.0.0-alpha.1')).toBeLessThan(0)
    expect(compareVersions('1.0.0-alpha.1', '1.0.0-alpha.beta')).toBeLessThan(0)
    expect(compareVersions('1.0.0-beta.2', '1.0.0-beta.11')).toBeLessThan(0)
    expect(compareVersions('1.0.0-rc.1', '1.0.0-beta.11')).toBeGreaterThan(0)
  })

  it('gives null when a value is not a version', () => {
    expect(compareVersions('0.4.0', 'x')).toBeNull()
    expect(compareVersions('', '0.4.0')).toBeNull()
  })
})

describe('whatsNewReleases', () => {
  const list = ['0.6.0', '0.5.1', '0.5.0', '0.4.0', '0.3.0'].map(release)
  const versions = (releases: Release[]): string[] => releases.map(r => r.version)

  it('gives the releases after the last seen version, up to the current version', () => {
    expect(versions(whatsNewReleases(list, { since: '0.4.0', version: '0.5.1' }))).toEqual([
      '0.5.1',
      '0.5.0',
    ])
  })

  it('gives only the current version with no last seen version', () => {
    expect(versions(whatsNewReleases(list, { since: null, version: '0.5.0' }))).toEqual(['0.5.0'])
  })

  it('gives no release when GitHub does not list the current version', () => {
    expect(whatsNewReleases(list, { since: null, version: '0.7.0' })).toEqual([])
  })

  it('skips a release with a version that it cannot compare', () => {
    expect(
      versions(whatsNewReleases([release('x'), ...list], { since: '0.5.1', version: '0.6.0' })),
    ).toEqual(['0.6.0'])
  })
})
