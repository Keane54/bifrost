import { describe, expect, it } from 'vitest'
import { githubCommentUrl } from '../../src/shared/github-url'

describe('githubCommentUrl', () => {
  it('accepts an https URL on github.com', () => {
    const url = 'https://github.com/acme/web/pull/412#discussion_r123'
    expect(githubCommentUrl(url)).toBe(url)
  })

  it('returns the parsed href, so a tab or a line break never goes on', () => {
    expect(githubCommentUrl('https://github.com/a/b\n/c\td')).toBe('https://github.com/a/b/cd')
    expect(githubCommentUrl(' https://github.com/a ')).toBe('https://github.com/a')
  })

  it('refuses http, another host, a look-alike host, a user name and a port', () => {
    for (const bad of [
      'http://github.com/acme/web/pull/1',
      'https://example.com/acme',
      'https://github.com.evil.example/acme',
      'https://evil.example/https://github.com/',
      'https://user@github.com/acme',
      'https://user:pass@github.com/acme',
      'https://github.com:8443/acme',
      'https://www.github.com/acme',
      'javascript:alert(1)',
      'file:///etc/passwd',
      '//github.com/acme',
      'github.com/acme',
      '',
    ]) {
      expect(githubCommentUrl(bad), bad).toBeNull()
    }
  })

  it('refuses a value that is not a string, and a URL that is too long', () => {
    for (const bad of [undefined, null, 7, {}, ['https://github.com/a'], true]) {
      expect(githubCommentUrl(bad)).toBeNull()
    }
    expect(githubCommentUrl(`https://github.com/${'a'.repeat(600)}`)).toBeNull()
  })
})
