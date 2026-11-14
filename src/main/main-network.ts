// The session of Bifrost's own requests from the main process (ruling S-A1). The default session
// has a dead proxy, so a module frame cannot reach the network. A request of Bifrost itself then
// fails in the default session, so it uses this session. The partition has no "persist:" prefix,
// so it keeps its cookies and its cache in memory only.

import { execFileSync } from 'node:child_process'
import { isIP } from 'node:net'
import { session } from 'electron'

export const MAIN_NETWORK_PARTITION = 'bifrost-main'

// The only hosts that the app resolves (fix round 3, the DNS block). A name hint in a module
// frame (dns-prefetch or preconnect) sends a DNS query past the dead proxy, so the app maps every
// other host name to "not found". The list has the hosts that src/main fetches, the hosts of the
// updater (GitHub, its asset hosts, and the local server of the Mac updater), and the dev server.
// Add a host here before src/main fetches it. A test checks src/main and the updater config
// against this list.
export const MAIN_NETWORK_HOSTS: readonly string[] = Object.freeze([
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

// A host name with letters, digits, hyphens and dots only. No wildcard, comma, space or port, so
// a proxy host can never add a pattern or a second rule.
const HOST_NAME = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$/

// A proxy host in the form of the rules: a lower-case name, an IPv4 address, or an IPv6 address
// with no brackets. Null for any other value.
function proxyHost(value: string): string | null {
  const host = value
    .trim()
    .toLowerCase()
    .replace(/^\[(.*)\]$/, '$1')
  if (isIP(host) !== 0) return host
  return HOST_NAME.test(host) ? host : null
}

// The value of the host-resolver-rules switch. An EXCLUDE rule wins over the MAP rule. The MAP
// rule also maps an IP address, so each proxy host gets its own EXCLUDE. An IPv6 address must be
// in the form with no brackets: a smoke test proves this form, and the form with brackets did not
// work in a test run.
export function hostResolverRules(proxyHosts: readonly string[] = []): string {
  const extra = proxyHosts
    .map(proxyHost)
    .filter((h): h is string => h !== null && !MAIN_NETWORK_HOSTS.includes(h))
  const excluded = [...new Set([...MAIN_NETWORK_HOSTS, ...extra])]
  return ['MAP * ~NOTFOUND', ...excluded.map(h => `EXCLUDE ${h}`)].join(', ')
}

// The proxy hosts in the output of `scutil --proxy`: the HTTP, HTTPS and SOCKS proxies that are
// on, and the host of the PAC URL when the PAC is on. Only the top level counts (the __SCOPED__
// part repeats it for each network interface). A value that is not a plain host is refused.
// Not covered: a PAC script that returns other proxy hosts, proxy auto discovery (WPAD), and a
// proxy change while Bifrost runs (Bifrost reads the settings once, so it needs a restart).
export function parseProxyHosts(text: string): { hosts: string[]; refused: string[] } {
  const top = new Map<string, string>()
  let depth = 0
  for (const line of text.split('\n')) {
    const match = line.match(/^\s*([A-Za-z_]+) : (.*)$/)
    if (match && depth === 1) top.set(match[1], match[2].trim())
    depth += (line.match(/\{/g) ?? []).length - (line.match(/\}/g) ?? []).length
  }
  const values: string[] = []
  for (const kind of ['HTTP', 'HTTPS', 'SOCKS']) {
    const value = top.get(`${kind}Proxy`)
    if (top.get(`${kind}Enable`) === '1' && value) values.push(value)
  }
  const pac = top.get('ProxyAutoConfigURLString')
  if (top.get('ProxyAutoConfigEnable') === '1' && pac) {
    try {
      const host = new URL(pac).hostname
      if (host !== '') values.push(host)
    } catch {
      values.push(pac)
    }
  }
  const hosts: string[] = []
  const refused: string[] = []
  for (const value of values) {
    const host = proxyHost(value)
    if (host === null) refused.push(value)
    else if (!hosts.includes(host)) hosts.push(host)
  }
  return { hosts, refused }
}

type Run = (file: string, args: string[], options: { encoding: 'utf8'; timeout: number }) => string

// Read the system proxy settings once, before the app is ready. A read that fails or times out
// gives no proxy host and the error.
export function readSystemProxyHosts(
  run: Run = (file, args, options) => execFileSync(file, args, options),
): { hosts: string[]; refused: string[]; error: string | null } {
  try {
    const text = run('/usr/sbin/scutil', ['--proxy'], { encoding: 'utf8', timeout: 1000 })
    return { error: null, ...parseProxyHosts(text) }
  } catch (error) {
    return { error: String(error), hosts: [], refused: [] }
  }
}

// Call it only after the app is ready.
export function mainFetch(url: string, init?: RequestInit): Promise<Response> {
  return session.fromPartition(MAIN_NETWORK_PARTITION).fetch(url, init)
}
