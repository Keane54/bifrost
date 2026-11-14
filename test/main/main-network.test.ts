// The hosts that Bifrost's main process may resolve (fix round 3, the DNS block). The app maps
// every other host name to "not found", so a module name hint sends no DNS query. A host that
// src/main fetches must be in the list, or Bifrost's own request fails. The checks read text and
// send no request.
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({ session: { fromPartition: () => ({}) } }))

const { MAIN_NETWORK_HOSTS, hostResolverRules, parseProxyHosts, readSystemProxyHosts } =
  await import('../../src/main/main-network')

const ROOT = join(__dirname, '../..')
const read = (file: string): string => readFileSync(join(ROOT, file), 'utf8')

describe('the host resolver rules', () => {
  it('lists the hosts of src/main, the updater and the dev server', () => {
    expect(MAIN_NETWORK_HOSTS).toEqual([
      'localhost',
      '127.0.0.1',
      'github.com',
      'api.github.com',
      'api.anthropic.com',
      'www.githubstatus.com',
      'status.sentry.io',
      'status.claude.com',
      'objects.githubusercontent.com',
      'release-assets.githubusercontent.com',
    ])
  })

  it('maps every other host to not found', () => {
    expect(hostResolverRules()).toBe(
      `MAP * ~NOTFOUND, ${MAIN_NETWORK_HOSTS.map(h => `EXCLUDE ${h}`).join(', ')}`,
    )
  })

  it('adds an EXCLUDE for each proxy host that is not in the list', () => {
    const base = hostResolverRules()
    expect(
      hostResolverRules(['proxy.corp.example', 'github.com', '10.20.30.40', '[fd00::1]']),
    ).toBe(`${base}, EXCLUDE proxy.corp.example, EXCLUDE 10.20.30.40, EXCLUDE fd00::1`)
  })

  it('never adds a wildcard or a second rule from a proxy host', () => {
    const base = hostResolverRules()
    expect(hostResolverRules(['*', '*.corp.example', 'a.example, MAP * 1.2.3.4', 'a b'])).toBe(base)
  })

  it('reads the proxy before the rules, and sets the rules before the app is ready', () => {
    const index = read('src/main/index.ts')
    expect(index).toContain(
      "app.commandLine.appendSwitch('host-resolver-rules', hostResolverRules(proxy.hosts))",
    )
    const readAt = index.indexOf('readSystemProxyHosts(')
    const switchAt = index.indexOf("appendSwitch('host-resolver-rules'")
    expect(readAt).toBeGreaterThan(-1)
    expect(readAt).toBeLessThan(switchAt)
    expect(switchAt).toBeLessThan(index.indexOf('app.whenReady()'))
    // The test file of the scutil output works only in a test home.
    expect(index).toContain('const proxyFile = testHome ? process.env.BIFROST_TEST_PROXY_FILE')
  })

  it('has each host that a file in src/main names', () => {
    const files = readdirSync(join(ROOT, 'src/main'), { recursive: true })
      .map(String)
      .filter(f => /\.tsx?$/.test(f))
    const missing = files.flatMap(f =>
      [...read(join('src/main', f)).matchAll(/https?:\/\/([A-Za-z0-9.-]+)/g)]
        .map(m => m[1].toLowerCase())
        .filter(h => !MAIN_NETWORK_HOSTS.includes(h))
        .map(h => `${f}: ${h}`),
    )
    expect(missing).toEqual([])
  })

  // electron-updater's GitHub provider reads https://github.com/<owner>/<repo>/releases. GitHub
  // sends each download to its asset hosts. A host option would send it elsewhere.
  it('has the hosts of the updater config', () => {
    const release = read('electron-builder.release.ts')
    const publish = release.match(/publish: \{[^}]*\}/)?.[0] ?? ''
    expect(publish).toContain("provider: 'github'")
    expect(publish).not.toMatch(/\bhost:/)
    expect(read('electron-builder.yml')).toMatch(/^publish: null$/m)
    for (const host of [
      'github.com',
      'objects.githubusercontent.com',
      'release-assets.githubusercontent.com',
      '127.0.0.1',
    ]) {
      expect(MAIN_NETWORK_HOSTS).toContain(host)
    }
  })
})

// The output of scutil --proxy on a Mac with a proxy. The __SCOPED__ part repeats settings for
// each network interface, and the parser reads only the top level.
const WITH_PROXY = `<dictionary> {
  ExceptionsList : <array> {
    0 : *.local
    1 : 169.254/16
  }
  FTPPassive : 1
  HTTPEnable : 1
  HTTPPort : 3128
  HTTPProxy : Proxy.Corp.Example
  HTTPSEnable : 1
  HTTPSPort : 3128
  HTTPSProxy : 10.20.30.40
  ProxyAutoConfigEnable : 1
  ProxyAutoConfigURLString : http://pac.corp.example:8080/proxy.pac
  SOCKSEnable : 1
  SOCKSPort : 1080
  SOCKSProxy : fd00::1
  __SCOPED__ : <dictionary> {
    en0 : <dictionary> {
      HTTPEnable : 1
      HTTPProxy : scoped.example
    }
  }
}
`

// The output with no proxy (the macOS default).
const NO_PROXY = `<dictionary> {
  ExceptionsList : <array> {
    0 : *.local
    1 : 169.254/16
  }
  FTPPassive : 1
  HTTPEnable : 0
  HTTPSEnable : 0
  ProxyAutoConfigEnable : 0
  ProxyAutoDiscoveryEnable : 0
  SOCKSEnable : 0
}
`

describe('parseProxyHosts', () => {
  it('gives the HTTP, HTTPS and SOCKS proxy hosts and the PAC host', () => {
    expect(parseProxyHosts(WITH_PROXY)).toEqual({
      hosts: ['proxy.corp.example', '10.20.30.40', 'fd00::1', 'pac.corp.example'],
      refused: [],
    })
  })

  it('gives nothing with no proxy', () => {
    expect(parseProxyHosts(NO_PROXY)).toEqual({ hosts: [], refused: [] })
    expect(parseProxyHosts('')).toEqual({ hosts: [], refused: [] })
    expect(parseProxyHosts('not the scutil output')).toEqual({ hosts: [], refused: [] })
  })

  it('ignores a proxy that is off', () => {
    const off = WITH_PROXY.replace('HTTPEnable : 1', 'HTTPEnable : 0')
      .replace('SOCKSEnable : 1', 'SOCKSEnable : 0')
      .replace('ProxyAutoConfigEnable : 1', 'ProxyAutoConfigEnable : 0')
    expect(parseProxyHosts(off).hosts).toEqual(['10.20.30.40'])
  })

  it('refuses a host with a wildcard, a comma, a space or a port', () => {
    const bad = WITH_PROXY.replace('Proxy.Corp.Example', '*.corp.example')
      .replace('HTTPSProxy : 10.20.30.40', 'HTTPSProxy : a.example, MAP * 1.2.3.4')
      .replace('SOCKSProxy : fd00::1', 'SOCKSProxy : proxy.example:8080')
    expect(parseProxyHosts(bad)).toEqual({
      hosts: ['pac.corp.example'],
      refused: ['*.corp.example', 'a.example, MAP * 1.2.3.4', 'proxy.example:8080'],
    })
  })

  it('reads the host of a PAC URL, and no host from a file PAC URL', () => {
    const v6 = WITH_PROXY.replace(
      'http://pac.corp.example:8080/proxy.pac',
      'http://[fd00::2]/p.pac',
    )
    expect(parseProxyHosts(v6).hosts).toContain('fd00::2')
    const file = WITH_PROXY.replace('http://pac.corp.example:8080/proxy.pac', 'file:///p.pac')
    expect(parseProxyHosts(file).hosts).toEqual(['proxy.corp.example', '10.20.30.40', 'fd00::1'])
  })
})

describe('readSystemProxyHosts', () => {
  it('runs scutil --proxy with a short timeout', () => {
    const calls: unknown[][] = []
    const result = readSystemProxyHosts((...args: unknown[]) => {
      calls.push(args)
      return WITH_PROXY
    })
    expect(calls).toEqual([['/usr/sbin/scutil', ['--proxy'], { encoding: 'utf8', timeout: 1000 }]])
    expect(result).toEqual({ error: null, hosts: parseProxyHosts(WITH_PROXY).hosts, refused: [] })
  })

  it('gives no host and the error when scutil fails or times out', () => {
    const result = readSystemProxyHosts(() => {
      throw new Error('spawnSync /usr/sbin/scutil ETIMEDOUT')
    })
    expect(result).toEqual({
      error: 'Error: spawnSync /usr/sbin/scutil ETIMEDOUT',
      hosts: [],
      refused: [],
    })
  })
})
