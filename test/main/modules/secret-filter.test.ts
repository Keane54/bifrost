import { describe, expect, it } from 'vitest'
import { maskToken } from '../../../src/main/log/mask'
import { filterSecrets, filterSecretValue } from '../../../src/main/modules/secret-filter'

// Fake tokens of each known format. The test builds them from parts, so no file holds a value
// that looks like a real secret.
const A20 = 'A1b2C3d4E5f6G7h8I9j0'
const SAMPLES: Record<string, string> = {
  'Anthropic key': `sk-ant-api03-${A20}_-x`,
  'AWS access key': `AKIA${'ABCDEFGHIJ234567'}`,
  'AWS temporary key': `ASIA${'ABCDEFGHIJ234567'}`,
  'GitHub app token (server)': `ghs_${A20}`,
  'GitHub app token (user)': `ghu_${A20}`,
  'GitHub fine-grained token': `github_pat_${A20}_${A20}`,
  'GitHub OAuth token': `gho_${A20}${A20}`,
  'GitHub personal token': `ghp_${A20}`,
  'GitHub refresh token': `ghr_${A20}${A20}`,
  'Google API key': `AIza${'Sy0123456789abcdefghijklmnopqrstu-_'}`,
  'JSON web token': [`eyJ${'hbGciOiJIUzI1NiJ9'}`, `eyJ${'zdWIiOiIxMjM0NTY3ODkwIn0'}`, A20].join(
    '.',
  ),
  'npm token': `npm_${A20}${'abcdefghijklmnop'}`,
  'Slack app token': `xapp-1-A0123456789-${A20}`,
  'Slack bot token': `xoxb-1234567890-${A20}`,
  'Slack config token': `xoxe-1-${A20}`,
  'Slack legacy token': `xoxa-2-${A20}`,
  'Slack refresh token': `xoxr-${A20}`,
  'Slack user token': `xoxp-1234567890-${A20}`,
  'Stripe live key': `sk_live_${A20}${A20}`,
  'Stripe restricted key': `rk_live_${A20}${A20}`,
}

function keyBlock(kind: string): string {
  return [
    `-----BEGIN ${kind}-----`,
    'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7',
    'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAAB',
    `-----END ${kind}-----`,
  ].join('\n')
}

describe('filterSecrets', () => {
  it('masks the value of a Bearer header and keeps the word', () => {
    for (const value of [`${A20}.${A20}-_~+/=`, `abc${A20}`]) {
      expect(filterSecrets(`Authorization: Bearer ${value}`)).toBe('Authorization: Bearer ***')
      expect(filterSecrets(`bearer ${value} end`)).toBe('bearer *** end')
    }
  })

  for (const [name, token] of Object.entries(SAMPLES)) {
    it(`masks a ${name}`, () => {
      expect(filterSecrets(`before ${token} after`)).toBe('before *** after')
      expect(filterSecrets(token)).toBe('***')
    })
  }

  it('masks each private key block', () => {
    for (const kind of [
      'PRIVATE KEY',
      'RSA PRIVATE KEY',
      'EC PRIVATE KEY',
      'OPENSSH PRIVATE KEY',
      'ENCRYPTED PRIVATE KEY',
      'PGP PRIVATE KEY BLOCK',
    ]) {
      expect(filterSecrets(`a\n${keyBlock(kind)}\nb`), kind).toBe('a\n***\nb')
    }
  })

  it('masks a private key block that has no end line', () => {
    const cut = keyBlock('RSA PRIVATE KEY').split('\n').slice(0, 3).join('\n')
    expect(filterSecrets(`key: ${cut}`)).toBe('key: ***')
  })

  it('masks two blocks and keeps the text between them', () => {
    const block = keyBlock('PRIVATE KEY')
    expect(filterSecrets(`${block} middle ${block}`)).toBe('*** middle ***')
  })

  it('masks every token in one text', () => {
    const text = Object.values(SAMPLES).join(' | ')
    expect(filterSecrets(text)).toBe(
      Object.values(SAMPLES)
        .map(() => '***')
        .join(' | '),
    )
  })

  it('masks at least each value that maskToken masks', () => {
    const samples = [
      `ghp_${'A'.repeat(25)}`,
      'gho_abcdefghijklmnopqrstuvwxyz0123',
      `github_pat_${'a'.repeat(22)}`,
      `sk-ant-${'b'.repeat(24)}`,
      'AKIAABCDEFGHIJKLMNOP',
      'xoxb-1234567890',
      'xoxa-1234567890',
      'xoxp-1234567890',
      'xoxr-1234567890',
    ]
    for (const sample of samples) {
      expect(maskToken(sample, null), sample).toBe('***')
      expect(filterSecrets(sample), sample).toBe('***')
    }
  })

  it('keeps plain text as it is', () => {
    for (const text of [
      '',
      'Hello, world.',
      'The ghost_town branch and the sk-antique shop.',
      'AKIA is a prefix, and AIza too.',
      'xoxb- with no token',
      // Made from parts, so that GitHub push protection sees no key-shaped text in the source.
      ['sk', 'test', '123456789012345678901234'].join('_'),
      '-----BEGIN PUBLIC KEY-----\nMIIBIjAN\n-----END PUBLIC KEY-----',
      'Line one\nLine two\t*** stays',
      'Émoji 🙂 and 日本語',
      'The Bearer of bad news, and a Bearer token.',
      'The ghr_ prefix and npm_install and npm_ci.',
      'eyJ alone, a.b.c and eyJabc.def',
    ]) {
      expect(filterSecrets(text)).toBe(text)
    }
  })

  it('gives the same text when it runs a second time', () => {
    const once = filterSecrets(Object.values(SAMPLES).join(' '))
    expect(filterSecrets(once)).toBe(once)
  })
})

describe('filterSecretValue', () => {
  const token = SAMPLES['GitHub personal token']

  it('masks each string inside objects and arrays, also the keys', () => {
    const value = {
      list: [token, 1, true, null, { deep: [`x ${token}`] }],
      name: `a ${token}`,
      [token]: 'key',
    }
    expect(filterSecretValue(value)).toEqual({
      '***': 'key',
      list: ['***', 1, true, null, { deep: ['x ***'] }],
      name: 'a ***',
    })
  })

  it('masks a string at the top', () => {
    expect(filterSecretValue(token)).toBe('***')
  })

  it('keeps numbers, booleans and null, and gives null for undefined', () => {
    expect(filterSecretValue(42)).toBe(42)
    expect(filterSecretValue(false)).toBe(false)
    expect(filterSecretValue(null)).toBe(null)
    expect(filterSecretValue(undefined)).toBe(null)
  })

  it('gives a copy and does not change the value', () => {
    const value = { a: [token] }
    const out = filterSecretValue(value)
    expect(value.a[0]).toBe(token)
    expect(out).not.toBe(value)
  })

  it('keeps a __proto__ key as an own key and does not change the prototype', () => {
    const value = JSON.parse('{"__proto__": {"polluted": true}, "a": 1}')
    const out = filterSecretValue(value) as Record<string, unknown>
    expect(Object.getPrototypeOf(out)).toBe(Object.prototype)
    expect(Object.hasOwn(out, '__proto__')).toBe(true)
    expect(({} as Record<string, unknown>).polluted).toBeUndefined()
  })
})
