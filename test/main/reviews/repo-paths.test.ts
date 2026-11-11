import { describe, expect, it } from 'vitest'
import {
  adminPath,
  clonePath,
  ioPath,
  isInside,
  REFUSED_BAD_REPO,
  reposRoot,
  worktreePath,
} from '../../../src/main/reviews/repo-paths'

describe('repo paths', () => {
  it('lower-cases the owner and the repository', () => {
    expect(reposRoot('/h')).toBe('/h/reviews/repos')
    expect(clonePath('/h', 'Acme', 'My.Repo_x-1')).toBe('/h/reviews/repos/acme/my.repo_x-1')
    expect(REFUSED_BAD_REPO).toBe('refused: bad repository name')
  })

  it('refuses ., .. and a slash in a name', () => {
    const bad: [string, string][] = [
      ['acme', '.'],
      ['acme', '..'],
      ['acme', 'a/b'],
      ['acme', '../x'],
      ['a/b', 'api'],
      ['.', 'api'],
      ['..', 'api'],
      ['', 'api'],
      ['acme', ''],
      ['acme', 'api\n'],
      ['-acme', 'api'],
    ]
    for (const [owner, repo] of bad) {
      expect(() => clonePath('/h', owner, repo), `${owner}/${repo}`).toThrow(REFUSED_BAD_REPO)
    }
    // A dot is valid inside a repository name.
    expect(clonePath('/h', 'acme', '.github')).toBe('/h/reviews/repos/acme/.github')
  })

  it('isInside refuses a path that goes up with ..', () => {
    expect(isInside('/r', '/r/a')).toBe(true)
    expect(isInside('/r', '/r/a/../b')).toBe(true)
    expect(isInside('/r/', '/r/a/b')).toBe(true)
    // A name that starts with two dots is a child, not a step up.
    expect(isInside('/r', '/r/..a')).toBe(true)
    expect(isInside('/r', '/r/a/../../x')).toBe(false)
    expect(isInside('/r', '/r/..')).toBe(false)
    expect(isInside('/r', '/r/a/..')).toBe(false)
    expect(isInside('/r', '/r')).toBe(false)
    expect(isInside('/r', '/rx')).toBe(false)
    expect(isInside('/r', '/')).toBe(false)
    expect(isInside('/r/a', '/r')).toBe(false)
  })

  it('the worktree, input and admin paths are below the clone', () => {
    const clone = clonePath('/h', 'acme', 'api')
    expect(worktreePath(clone, 7)).toBe('/h/reviews/repos/acme/api/.bifrost-worktrees/7')
    expect(ioPath(clone, 7)).toBe('/h/reviews/repos/acme/api/.bifrost-io/7')
    expect(adminPath(clone, 7)).toBe('/h/reviews/repos/acme/api/.git/worktrees/7')
    for (const path of [worktreePath(clone, 7), ioPath(clone, 7), adminPath(clone, 7)]) {
      expect(isInside(clone, path)).toBe(true)
      expect(isInside(reposRoot('/h'), path)).toBe(true)
    }
  })
})
