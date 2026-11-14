// The module sandbox (Modules design 8.1, plan Task 4). The test seeds modules/state.json and the
// probe module in the test home. The test then puts sandboxed frames of the probe on the Bifrost
// page, as a module panel does, and runs the probes of the spike in them. Each probe must fail.
//
// Local HTTP, TCP and UDP servers count each request and each connection ("hits"). A probe that
// reaches one of them is a leak. No test reads or writes the real clipboard (ruling S-A4).

import { randomBytes } from 'node:crypto'
import { createSocket } from 'node:dgram'
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { createServer as createTcpServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Script } from 'node:vm'
import { _electron, type ElectronApplication, expect, type Page, test } from '@playwright/test'
import { expectTestHomeOnly, launchOptions, skipSetup } from './app.ts'

const FIXTURE = join(import.meta.dirname, 'fixtures', 'modules', 'probe')
const ENTRY = 'panels/probe.html'
// The client library that the protocol serves at _bifrost/api.js. The main build compiles it from
// src/module-api/api.ts (ruling P10).
const API_FILE = join(import.meta.dirname, '..', '..', 'out', 'main', 'module-api', 'api.js')
// The session of Bifrost's own main-process requests (src/main/main-network.ts).
const MAIN_PARTITION = 'bifrost-main'
const DEAD_PROXY = 'PROXY 127.0.0.1:9'
// The longest wait for a condition. A slow machine gets the time it needs.
const SLOW = 20_000

type Msg = { data: Record<string, unknown>; fromA: boolean; index: number; origin: string }
type Result = { outcome: string } & Record<string, unknown>

function manifest(id: string): Record<string, unknown> {
  return {
    description: 'A probe that checks the module sandbox.',
    id,
    minBifrost: '0.1.0',
    name: 'Sandbox probe',
    panels: [{ entry: ENTRY, icon: 'wrench', id: 'main', title: 'Probe' }],
    permissions: [],
    suggests: { dailyCap: null, model: null },
    version: '1.0.0',
  }
}

// Seed three modules with the probe code: two that are on and one that is off.
async function seedModules(bifrostHome: string): Promise<void> {
  const modules: Record<string, unknown> = {}
  for (const [id, enabled] of [
    ['probe', true],
    ['probe-two', true],
    ['probe-off', false],
  ] as const) {
    await cp(FIXTURE, join(bifrostHome, 'modules', id, 'current'), { recursive: true })
    modules[id] = {
      dailyCap: 10,
      enabled,
      granted: [],
      hash: '0'.repeat(64),
      jobs: { count: 0, day: '' },
      manifest: manifest(id),
      model: 'sonnet',
      pendingUpdate: null,
      source: { kind: 'folder', path: FIXTURE },
    }
  }
  await writeFile(join(bifrostHome, 'modules', 'state.json'), JSON.stringify({ modules }))
}

interface Servers {
  hits: string[]
  httpPort: number
  query: string
  close(): void
}

// The local test servers. Each request and each connection is a hit.
async function startServers(): Promise<Servers> {
  const hits: string[] = []
  const server = createServer((req, res) => {
    hits.push(`${req.method} ${req.url}`)
    res.writeHead(200, { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'text/plain' })
    res.end('remote')
  })
  server.on('upgrade', (req, socket) => {
    hits.push(`UPGRADE ${req.url}`)
    socket.destroy()
  })
  server.on('connection', () => hits.push('TCP connection to the HTTP server'))
  await new Promise<void>(r => server.listen(0, '127.0.0.1', r))
  const httpPort = (server.address() as AddressInfo).port
  const tcp = createTcpServer(socket => {
    hits.push('TCP connection to the TURN port')
    socket.destroy()
  })
  await new Promise<void>(r => tcp.listen(0, '127.0.0.1', r))
  const udp = createSocket('udp4')
  udp.on('message', m => hits.push(`UDP packet (${m.length} bytes) to the STUN port`))
  await new Promise<void>(r => udp.bind(0, '127.0.0.1', r))
  const tcpPort = (tcp.address() as AddressInfo).port
  return {
    close: () => {
      server.close()
      tcp.close()
      udp.close()
    },
    hits,
    httpPort,
    query: `http=${httpPort}&udp=${udp.address().port}&tcp=${tcpPort}`,
  }
}

// Start Bifrost with the probe modules in the test home, and pass the setup dialog.
async function startApp(
  testHome: string,
  env: Record<string, string> = {},
): Promise<{ app: ElectronApplication; page: Page }> {
  await mkdir(join(testHome, '.bifrost'), { recursive: true })
  await seedModules(join(testHome, '.bifrost'))
  const opts = await launchOptions(testHome)
  opts.env = { ...opts.env, ...env }
  // A fake camera and microphone, so a probe can never open a real device. The user data
  // folder stays the last argument.
  const args = opts.args ?? []
  opts.args = [...args.slice(0, -1), '--use-fake-device-for-media-stream', ...args.slice(-1)]
  const app = await _electron.launch(opts)
  const page = await app.firstWindow()
  // The app uses only the test home.
  await expectTestHomeOnly(app, testHome)
  await skipSetup(page)
  return { app, page }
}

// Put three sandboxed frames on the page, as a module panel does.
async function addFrames(page: Page, query: string, size = { height: 100, width: 300 }) {
  await page.evaluate(
    ([q, w, h]) => {
      const store: { messages: unknown[] } = { messages: [] }
      ;(window as unknown as { __probe: unknown }).__probe = store
      const box = document.createElement('div')
      box.style.cssText = 'position:fixed;left:0;top:0;z-index:2147483647;display:flex'
      const make = (id: string, host: string): HTMLIFrameElement => {
        const f = document.createElement('iframe')
        f.id = id
        f.name = id
        f.setAttribute('sandbox', 'allow-scripts')
        f.src = `bifrost-module://${host}/panels/probe.html?${q}`
        f.style.cssText = `width:${w}px;height:${h}px;border:0;background:white`
        return f
      }
      const a = make('probe-a', 'probe')
      window.addEventListener('message', e => {
        store.messages.push({
          data: e.data,
          fromA: e.source === a.contentWindow,
          index: store.messages.length,
          origin: e.origin,
        })
      })
      box.append(a, make('probe-b', 'probe-two'), make('probe-c', 'probe-off'))
      document.body.append(box)
    },
    [query, size.width, size.height] as const,
  )
}

// Load the probe in frame A again, as the Bifrost page does. Wait for it.
async function reloadProbe(page: Page, query: string, extra: string): Promise<void> {
  const n = (await messages(page)).length - 1
  await page.evaluate(
    ([q, x]) => {
      const f = document.getElementById('probe-a') as HTMLIFrameElement
      f.src = `bifrost-module://probe/panels/probe.html?${q}&${x}`
    },
    [query, extra] as const,
  )
  expect(await waitMsg(page, 'ready', 'probe', n, SLOW)).not.toBeNull()
}

async function frames(app: ElectronApplication) {
  return app.evaluate(({ BrowserWindow }) => {
    const top = BrowserWindow.getAllWindows()[0].webContents.mainFrame
    return top.framesInSubtree.map(f => ({
      name: f.name,
      osProcessId: f.osProcessId,
      top: f === top,
      url: f.url,
    }))
  })
}

async function frameUrl(app: ElectronApplication, name: string): Promise<string | undefined> {
  return (await frames(app)).find(f => f.name === name)?.url
}

// The URL of the document in a frame. An error page gives chrome-error://chromewebdata/.
async function frameDocument(app: ElectronApplication, name: string): Promise<string> {
  return app.evaluate(async ({ BrowserWindow }, n) => {
    const top = BrowserWindow.getAllWindows()[0].webContents.mainFrame
    const frame = top.framesInSubtree.find(f => f.name === n)
    if (frame === undefined) return 'no frame'
    try {
      return String(await frame.executeJavaScript('document.URL'))
    } catch (e) {
      return `no document: ${e}`
    }
  }, name)
}

async function messages(page: Page): Promise<Msg[]> {
  return page.evaluate(
    () => (window as unknown as { __probe: { messages: Msg[] } }).__probe.messages,
  )
}

async function hasMsg(page: Page, type: string, host: string, after: number): Promise<boolean> {
  return (await messages(page)).some(
    m => m.index > after && m.data.type === type && m.data.host === host,
  )
}

// Wait for a message with this type from this module after index `after`.
async function waitMsg(
  page: Page,
  type: string,
  host: string,
  after: number,
  timeout = 5000,
): Promise<Msg | null> {
  try {
    await page.waitForFunction(
      ([t, h, a]) =>
        (window as unknown as { __probe: { messages: Msg[] } }).__probe.messages.some(
          m => m.index > (a as number) && m.data.type === t && m.data.host === h,
        ),
      [type, host, after] as const,
      { timeout },
    )
  } catch {
    return null
  }
  const all = await messages(page)
  return all.find(m => m.index > after && m.data.type === type && m.data.host === host) ?? null
}

// Post a command to frame A. Give the index of the last message before it.
async function post(page: Page, data: Record<string, unknown>): Promise<number> {
  return page.evaluate(d => {
    const w = window as unknown as { __probe: { messages: unknown[] } }
    const last = w.__probe.messages.length - 1
    ;(document.getElementById('probe-a') as HTMLIFrameElement).contentWindow?.postMessage(d, '*')
    return last
  }, data)
}

// Post a command to frame A and wait until the probe answers after it, or the frame shows
// another URL. Then the frame is alive when it answers a ping.
async function runCommand(
  app: ElectronApplication,
  page: Page,
  data: Record<string, unknown>,
): Promise<{ alive: boolean; before: string | undefined; after: string | undefined }> {
  const before = await frameUrl(app, 'probe-a')
  const at = await post(page, data)
  await expect
    .poll(
      async () =>
        (await frameUrl(app, 'probe-a')) !== before || (await hasMsg(page, 'after', 'probe', at)),
      { timeout: SLOW },
    )
    .toBe(true)
  let alive = false
  if ((await frameUrl(app, 'probe-a')) === before) {
    const pingAt = await post(page, { cmd: 'ping', id: `${data.cmd}-ping` })
    alive = (await waitMsg(page, 'pong', 'probe', pingAt, SLOW)) !== null
  }
  return { after: await frameUrl(app, 'probe-a'), alive, before }
}

// Wait until the frame has a document, and give its URL.
async function settledDocument(app: ElectronApplication, name: string): Promise<string> {
  let doc = ''
  await expect
    .poll(
      async () => {
        doc = await frameDocument(app, name)
        return doc.startsWith('no ') ? '' : doc
      },
      { timeout: SLOW },
    )
    .not.toBe('')
  return doc
}

function outcomes(results: Record<string, Result>, names: string[]): Record<string, string> {
  return Object.fromEntries(names.map(n => [n, results[n]?.outcome ?? 'missing']))
}

type LogEvent = { type: string; source: string; phase: number; params: unknown }

// The net log events of each source that names a host: the event type, the source type, the
// phase and the parameters. So the end event with the net error shows too. The type names come
// from the constants of the log. A log that stops early can miss its closing brackets.
function eventsFor(text: string, hosts: string[]): Record<string, LogEvent[]> {
  let log: {
    constants: { logEventTypes: Record<string, number>; logSourceType: Record<string, number> }
    events: {
      type: number
      phase: number
      source: { id: number; type: number }
      params?: unknown
    }[]
  }
  try {
    log = JSON.parse(text)
  } catch {
    log = JSON.parse(`${text.trimEnd().replace(/,$/, '')}]}`)
  }
  const typeName = new Map(Object.entries(log.constants.logEventTypes).map(([k, v]) => [v, k]))
  const sourceName = new Map(Object.entries(log.constants.logSourceType).map(([k, v]) => [v, k]))
  const out: Record<string, LogEvent[]> = {}
  for (const host of hosts) {
    const ids = new Set(
      log.events.filter(e => JSON.stringify(e.params ?? '').includes(host)).map(e => e.source.id),
    )
    out[host] = log.events
      .filter(e => ids.has(e.source.id))
      .map(e => ({
        params: e.params ?? null,
        phase: e.phase,
        source: sourceName.get(e.source.type) ?? String(e.source.type),
        type: typeName.get(e.type) ?? String(e.type),
      }))
  }
  return out
}

// The DNS transaction events of a host. Each one is a DNS query that leaves the Mac.
function dnsTransactions(list: LogEvent[]): string[] {
  return list.map(e => e.type).filter(t => t.startsWith('DNS_TRANSACTION'))
}

test('a module frame is sandboxed', async () => {
  test.setTimeout(240_000)
  const servers = await startServers()
  const { hits } = servers
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-modules-'))
  let app: ElectronApplication | null = null
  try {
    const started = await startApp(testHome)
    app = started.app
    const { page } = started

    // The protocol serves an enabled module with the module headers, and nothing for a module
    // that is off.
    const served = await app.evaluate(
      async ({ net }, urls) => {
        const out: Record<string, { status: number; headers: Record<string, string> }> = {}
        for (const url of urls) {
          const res = await net.fetch(url)
          out[url] = { headers: Object.fromEntries(res.headers), status: res.status }
        }
        return out
      },
      [`bifrost-module://probe/${ENTRY}`, `bifrost-module://probe-off/${ENTRY}`],
    )
    const on = served[`bifrost-module://probe/${ENTRY}`]
    expect(on.status).toBe(200)
    expect(on.headers['content-security-policy']).toContain("connect-src 'none'")
    expect(on.headers['x-content-type-options']).toBe('nosniff')
    expect(on.headers['content-type']).toBe('text/html; charset=utf-8')
    expect(served[`bifrost-module://probe-off/${ENTRY}`].status).toBe(404)

    // The protocol serves the client library of Bifrost to a module that is on (plan Task 5).
    const API_ON = 'bifrost-module://probe/_bifrost/api.js'
    const API_OFF = 'bifrost-module://probe-off/_bifrost/api.js'
    const api = await app.evaluate(
      async ({ net }, urls) => {
        const out: Record<string, { status: number; text: string; type: string | null }> = {}
        for (const url of urls) {
          const res = await net.fetch(url)
          const type = res.headers.get('content-type')
          out[url] = { status: res.status, text: await res.text(), type }
        }
        return out
      },
      [API_ON, API_OFF],
    )
    expect(api[API_ON].status).toBe(200)
    expect(api[API_ON].type).toBe('text/javascript; charset=utf-8')
    // The protocol serves the built file. It is a classic script: a script with an import, an
    // export or import.meta does not compile.
    const built = await readFile(API_FILE, 'utf8')
    expect(api[API_ON].text).toBe(built)
    expect(() => new Script(built, { filename: 'api.js' })).not.toThrow()
    expect(built).not.toMatch(/^\s*(import|export)\b/m)
    expect(api[API_OFF].status).toBe(404)

    // The Bifrost page sends module calls through the preload to Heimdall. The storage of the
    // module goes to the test home.
    const calls = await page.evaluate(async () => {
      type Modules = { call(id: string, name: string, args: unknown): Promise<unknown> }
      const modules = (window as unknown as { bifrost: { modules: Modules } }).bifrost.modules
      const settle = (p: Promise<unknown>) =>
        p.then(
          value => ({ value }),
          (error: Error) => ({ error: error.message }),
        )
      const set = await settle(modules.call('probe', 'storage.set', { key: 'k', value: { n: 1 } }))
      const get = await settle(modules.call('probe', 'storage.get', { key: 'k' }))
      const off = await settle(modules.call('probe-off', 'storage.get', { key: 'k' }))
      const notify = await settle(modules.call('probe', 'notify', { title: 'Hi' }))
      return { get, notify, off, set }
    })
    expect(calls).toEqual({
      get: { value: { n: 1 } },
      notify: { error: 'refused: not allowed for this module' },
      off: { error: 'refused: module off' },
      set: { value: null },
    })
    // The store writes the file in the background, as compact JSON.
    const dataFile = join(testHome, '.bifrost', 'modules-data', 'probe.json')
    await expect
      .poll(() => readFile(dataFile, 'utf8').catch(() => ''), { timeout: SLOW })
      .toBe('{"k":{"n":1}}')

    // The default session has the dead proxy, also for loopback. Bifrost's own session reaches
    // the network. The rules of a dev run let only the dev page host bypass the proxy.
    const network = await app.evaluate(
      async ({ BrowserWindow, session }, { partition, port }) => {
        const url = `http://127.0.0.1:${port}`
        let defaultFetch = 'reached'
        try {
          await session.defaultSession.fetch(`${url}/default-session`)
        } catch (e) {
          defaultFetch = String(e)
        }
        const main = await session.fromPartition(partition).fetch(`${url}/main-session`)
        const check = session.fromPartition('bifrost-proxy-check')
        await check.setProxy({
          mode: 'fixed_servers',
          proxyBypassRules: '<-loopback>,localhost:5173',
          proxyRules: 'http://127.0.0.1:9',
        })
        return {
          defaultFetch,
          defaultProxy: await session.defaultSession.resolveProxy(`${url}/`),
          dev: await check.resolveProxy('http://localhost:5173/'),
          devOtherPort: await check.resolveProxy('http://localhost:5174/'),
          devSocket: await check.resolveProxy('ws://localhost:5173/'),
          mainProxy: await session.fromPartition(partition).resolveProxy(`${url}/`),
          mainStatus: main.status,
          webrtc: BrowserWindow.getAllWindows()[0].webContents.getWebRTCIPHandlingPolicy(),
        }
      },
      { partition: MAIN_PARTITION, port: servers.httpPort },
    )
    expect(network.defaultProxy).toBe(DEAD_PROXY)
    expect(network.defaultFetch).not.toBe('reached')
    expect(network.mainProxy).toBe('DIRECT')
    expect(network.mainStatus).toBe(200)
    expect(network.dev).toBe('DIRECT')
    expect(network.devSocket).toBe('DIRECT')
    expect(network.devOtherPort).toBe(DEAD_PROXY)
    expect(network.webrtc).toBe('disable_non_proxied_udp')
    expect(hits.filter(h => h.includes('session'))).toEqual(['GET /main-session'])
    hits.length = 0

    const topUrl = page.url()
    await addFrames(page, servers.query)

    // The probe loads, with its ES module script. The module that is off does not load.
    expect(await waitMsg(page, 'ready', 'probe', -1, SLOW)).not.toBeNull()
    expect(await waitMsg(page, 'ready', 'probe-two', -1, SLOW)).not.toBeNull()
    expect(await waitMsg(page, 'esm-ran', 'probe', -1, SLOW)).not.toBeNull()
    expect(await waitMsg(page, 'ready', 'probe-off', -1, 2000)).toBeNull()

    // The module frame runs in its own process (ruling S-A5).
    const atStart = await frames(app)
    const top = atStart.find(f => f.top)
    const frameA = atStart.find(f => f.name === 'probe-a')
    expect(frameA?.url).toContain('bifrost-module://probe/')
    expect(frameA?.osProcessId).toBeGreaterThan(0)
    expect(frameA?.osProcessId).not.toBe(top?.osProcessId)

    // postMessage works both ways, and event.source identifies the frame.
    let at = await post(page, { cmd: 'ping', id: 'p1' })
    const pong = await waitMsg(page, 'pong', 'probe', at, SLOW)
    expect(pong?.data.fromParent).toBe(true)
    expect(pong?.fromA).toBe(true)
    expect(pong?.origin).toBe('null')

    // The probes with no click.
    at = await post(page, { cmd: 'probes', id: 'all' })
    const probes = await waitMsg(page, 'probes', 'probe', at, 60_000)
    const results = (probes?.data.results ?? {}) as Record<string, Result>
    const mustFail = [
      'bifrostApi',
      'camera',
      'clipboardPermission',
      'clipboardPolicy',
      'crossModuleScript',
      'eventSource',
      'fetchOwnFile',
      'fetchRemote',
      'microphone',
      'notifications',
      'parentDocument',
      'remoteImage',
      'topLocation',
      'webSocket',
      'windowOpen',
      'xhr',
    ]
    expect(outcomes(results, mustFail)).toEqual(
      Object.fromEntries(mustFail.map(n => [n, 'blocked'])),
    )

    // The probes after a real click in the frame.
    const clickAt = (await messages(page)).length - 1
    await page.frameLocator('#probe-a').locator('#gesture').click()
    const clicked = await waitMsg(page, 'gesture', 'probe', clickAt, 30_000)
    const gesture = (clicked?.data.results ?? {}) as Record<string, Result>
    const gestureFail = ['camera', 'notifications', 'queryPaste', 'topLocation', 'windowOpen']
    expect(outcomes(gesture, gestureFail)).toEqual(
      Object.fromEntries(gestureFail.map(n => [n, 'blocked'])),
    )
    // Ruling S-A4: record the result of the copy command. The probe has no selection, so a copy
    // that works writes nothing.
    test.info().annotations.push({
      description: JSON.stringify({
        activation: gesture.activation,
        execCommandCopy: gesture.execCommandCopy,
        queryCopy: gesture.queryCopy,
      }),
      type: 'module copy (S-A4)',
    })

    // The frame cannot move itself, another frame or the top page, and cannot post a form.
    // A load of a remote, data: or blob: URL stops at the frame-src rule of the Bifrost page:
    // the frame then shows an error page, and no request goes out. The module stops, and
    // nothing of the target loads.
    const commands = [
      'form',
      'navRemote',
      'navOtherModule',
      'navSameModule',
      'navData',
      'navJavascript',
      'navBlob',
      'anchorTop',
      'anchorBlank',
    ]
    const moved: { cmd: string; doc: string; url: string | undefined }[] = []
    for (const cmd of commands) {
      const run = await runCommand(app, page, { cmd, id: cmd })
      if (run.after !== run.before || !run.alive) {
        moved.push({ cmd, doc: await settledDocument(app, 'probe-a'), url: run.after })
        await reloadProbe(page, servers.query, `again=${cmd}`)
      }
    }
    expect(moved.filter(m => !m.doc.startsWith('chrome-error://'))).toEqual([])
    expect(moved.map(m => m.cmd)).toEqual(
      moved.map(m => m.cmd).filter(c => ['navBlob', 'navData', 'navRemote'].includes(c)),
    )
    test.info().annotations.push({ description: JSON.stringify(moved), type: 'error pages' })
    expect(page.url()).toBe(topUrl)
    expect(await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length)).toBe(1)

    // No probe reached a test server: no request, no TCP connection and no UDP packet. This
    // includes WebRTC with STUN and TURN (ruling S-A1).
    expect(hits).toEqual([])
  } finally {
    await app?.close().catch(() => {})
    servers.close()
    await rm(testHome, { force: true, recursive: true })
  }
})

// A name hint can make a DNS query that goes past the proxy (fix rounds 1 to 3). The net log of
// the default session shows each lookup. Each probe host has a random part, so only the probe
// names it. The hints: a dns-prefetch and a preconnect in the HTML (dns.html), the same two that
// the script adds after load, and an anchor to a second host. A cache-only lookup of localhost
// is the control: it sends no query, and the log must record it. No test sends a DNS query for a
// host of MAIN_NETWORK_HOSTS.
test('a module frame makes no DNS request', async () => {
  test.setTimeout(120_000)
  const servers = await startServers()
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-modules-'))
  const host = `n${randomBytes(8).toString('hex')}.bifrost-probe.test`
  const anchorHost = `a${randomBytes(8).toString('hex')}.bifrost-probe.test`
  const control = 'localhost:0'
  const logPath = join(testHome, 'net-log.json')
  let app: ElectronApplication | null = null
  try {
    const started = await startApp(testHome)
    app = started.app
    const { page } = started
    const dnsFile = join(testHome, '.bifrost', 'modules', 'probe', 'current', 'panels', 'dns.html')
    await writeFile(dnsFile, (await readFile(dnsFile, 'utf8')).replaceAll('__DNS_HOST__', host))
    await app.evaluate(
      async ({ session }, path) => session.defaultSession.netLog.startLogging(path),
      logPath,
    )
    // Frame A loads dns.html, with the static hints.
    await page.evaluate(q => {
      const store: { messages: unknown[] } = { messages: [] }
      ;(window as unknown as { __probe: unknown }).__probe = store
      const a = document.createElement('iframe')
      a.id = 'probe-a'
      a.name = 'probe-a'
      a.setAttribute('sandbox', 'allow-scripts')
      a.src = `bifrost-module://probe/panels/dns.html?${q}`
      a.style.cssText = 'position:fixed;left:0;top:0;width:300px;height:100px;border:0'
      window.addEventListener('message', e => {
        store.messages.push({
          data: e.data,
          fromA: e.source === a.contentWindow,
          index: store.messages.length,
          origin: e.origin,
        })
      })
      document.body.append(a)
    }, servers.query)
    expect(await waitMsg(page, 'ready', 'probe', -1, SLOW)).not.toBeNull()
    // The hints that the script adds after load.
    const run = await runCommand(app, page, {
      anchor: anchorHost,
      cmd: 'dnsHints',
      host,
      id: 'dns',
    })
    expect(run.alive).toBe(true)
    await app.evaluate(async ({ session }) => {
      await session.defaultSession
        .resolveHost('localhost', { source: 'localOnly' })
        .catch(() => null)
    })
    // A hint runs later than the command. Give it time before the log stops.
    await page.waitForTimeout(3000)
    await app.evaluate(async ({ session }) => session.defaultSession.netLog.stopLogging())
    const found = eventsFor(await readFile(logPath, 'utf8'), [host, anchorHost, control])
    test.info().annotations.push({ description: JSON.stringify(found), type: 'net log' })
    // The control proves that the log records a lookup.
    expect(found[control].map(e => e.type)).toContain('HOST_RESOLVER_MANAGER_REQUEST')
    // No DNS query for a probe host.
    expect(dnsTransactions(found[host])).toEqual([])
    expect(dnsTransactions(found[anchorHost])).toEqual([])
    expect(servers.hits).toEqual([])
  } finally {
    await app?.close().catch(() => {})
    servers.close()
    await rm(testHome, { force: true, recursive: true })
  }
})

// The host resolver rules map every host that is not listed to "not found" (fix round 4). These
// checks find whether that also applies to a proxy at an IP address, and whether the EXCLUDE that
// Bifrost adds for a system proxy host fixes it. Two local servers act as proxies: one at [::1],
// which is not listed, and one at 127.0.0.1, which is listed. A scratch session sends one request
// through each. The target host is a test name, and a client that uses a proxy does not look up
// the target, so no DNS query goes out.
async function proxyCheck(scutilOutput: string | null) {
  const got: string[] = []
  const proxy = (name: string) =>
    createServer((req, res) => {
      got.push(`${name} ${req.method} ${req.url}`)
      res.writeHead(200, { 'Content-Type': 'text/plain' })
      res.end('proxied')
    })
  const v6 = proxy('v6')
  const v4 = proxy('v4')
  await new Promise<void>(r => v6.listen(0, '::1', r))
  await new Promise<void>(r => v4.listen(0, '127.0.0.1', r))
  const ports = { v4: (v4.address() as AddressInfo).port, v6: (v6.address() as AddressInfo).port }
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-modules-'))
  let app: ElectronApplication | null = null
  try {
    const env: Record<string, string> = {}
    if (scutilOutput !== null) {
      env.BIFROST_TEST_PROXY_FILE = join(testHome, 'scutil-proxy.txt')
      await writeFile(env.BIFROST_TEST_PROXY_FILE, scutilOutput)
    }
    app = (await startApp(testHome, env)).app
    const result = await app.evaluate(async ({ session }, p) => {
      const through = async (partition: string, rules: string) => {
        const s = session.fromPartition(partition)
        await s.setProxy({ mode: 'fixed_servers', proxyRules: rules })
        try {
          const res = await s.fetch('http://target.bifrost-probe.test/x')
          return `status ${res.status}`
        } catch (e) {
          return String(e)
        }
      }
      const literal = await session.defaultSession
        .resolveHost('192.0.2.1', { source: 'localOnly' })
        .then(
          r => `resolved ${r.endpoints.map(e => e.address).join(' ')}`,
          e => String(e),
        )
      return {
        literal,
        v4: await through('bifrost-proxy-v4', `http://127.0.0.1:${p.v4}`),
        v6: await through('bifrost-proxy-v6', `http://[::1]:${p.v6}`),
      }
    }, ports)
    test.info().annotations.push({ description: JSON.stringify({ got, result }), type: 'ip proxy' })
    return { got, result }
  } finally {
    await app?.close().catch(() => {})
    v6.close()
    v4.close()
    await rm(testHome, { force: true, recursive: true })
  }
}

test('the host rules apply to a proxy at an IP address', async () => {
  test.setTimeout(90_000)
  const { got, result } = await proxyCheck(null)
  // The rules map an IP address that is not listed, so it does not resolve.
  expect(result.literal).toBe('Error: net::ERR_NAME_NOT_RESOLVED')
  // A proxy at a listed IP address works.
  expect(result.v4).toBe('status 200')
  expect(got).toContain('v4 GET http://target.bifrost-probe.test/x')
  // A proxy at an IP address that is not listed fails, and gets no request.
  expect(result.v6).not.toBe('status 200')
  expect(got.filter(g => g.startsWith('v6'))).toEqual([])
})

test('a system proxy at an IP address gets its own EXCLUDE', async () => {
  test.setTimeout(90_000)
  // The scutil output of a Mac whose HTTP proxy is [::1].
  const { got, result } = await proxyCheck(
    ['<dictionary> {', '  HTTPEnable : 1', '  HTTPPort : 3128', '  HTTPProxy : ::1', '}', ''].join(
      '\n',
    ),
  )
  expect(result.v6).toBe('status 200')
  expect(got).toContain('v6 GET http://target.bifrost-probe.test/x')
  // Other addresses stay mapped.
  expect(result.literal).toBe('Error: net::ERR_NAME_NOT_RESOLVED')
})

// More probes (fix round 1): a download, an external scheme, history.back(), a file input and a
// dropped file. The test records each result. A download is cancelled at once, a file chooser is
// cancelled at once, and the dropped file is a file of the test home.
test('more probes in a module frame', async () => {
  test.setTimeout(180_000)
  const servers = await startServers()
  const testHome = await mkdtemp(join(tmpdir(), 'bifrost-modules-'))
  let app: ElectronApplication | null = null
  const report: Record<string, unknown> = {}
  try {
    const started = await startApp(testHome)
    app = started.app
    const { page } = started
    const consoleLines: string[] = []
    page.on('console', m => consoleLines.push(m.text()))
    // Record each download (and cancel it) and each frame navigation.
    await app.evaluate(({ BrowserWindow, session }) => {
      const log: unknown[] = []
      ;(globalThis as unknown as { __extra: unknown[] }).__extra = log
      session.defaultSession.on('will-download', (e, item) => {
        log.push({ kind: 'download', url: item.getURL() })
        e.preventDefault()
      })
      const wc = BrowserWindow.getAllWindows()[0].webContents
      wc.on('will-frame-navigate', e => {
        log.push({ initiator: e.initiator?.url ?? null, kind: 'will-frame-navigate', url: e.url })
      })
      wc.on('did-frame-navigate', (_e, url, code, _status, isMainFrame) => {
        log.push({ code, isMainFrame, kind: 'did-frame-navigate', url })
      })
    })
    const mainLog = () =>
      app?.evaluate(() => (globalThis as unknown as { __extra: unknown[] }).__extra.splice(0))
    const topUrl = page.url()
    await addFrames(page, servers.query, { height: 320, width: 420 })
    expect(await waitMsg(page, 'ready', 'probe', -1, SLOW)).not.toBeNull()
    await mainLog()
    const frameA = page.frameLocator('#probe-a')
    // Run one probe and record its result or its error. Then load the probe again if the step
    // moved it or stopped it, and record that.
    const step = async (name: string, run: () => Promise<Record<string, unknown>>) => {
      let result: Record<string, unknown>
      try {
        result = await run()
      } catch (e) {
        result = { error: String(e).slice(0, 400) }
      }
      const pingAt = await post(page, { cmd: 'ping', id: `${name}-ping` })
      const alive = (await waitMsg(page, 'pong', 'probe', pingAt, 5000)) !== null
      const url = await frameUrl(app as ElectronApplication, 'probe-a')
      report[name] = { ...result, alive, frameUrl: url, main: await mainLog() }
      if (!alive || !url?.startsWith('bifrost-module://probe/')) {
        await reloadProbe(page, servers.query, `after=${name}`)
        await mainLog()
      }
    }

    // history.back(): the page loads a second probe URL, then the module goes back.
    await reloadProbe(page, servers.query, 'step=2')
    await mainLog()
    await step('historyBack', async () => ({
      ...(await runCommand(app as ElectronApplication, page, { cmd: 'historyBack', id: 'b' })),
      top: page.url(),
    }))

    // A download and an external scheme, each after a real click.
    for (const name of ['downloadBlob', 'downloadOwn', 'mailto', 'appScheme']) {
      await step(name, async () => {
        const at = (await messages(page)).length - 1
        const lines = consoleLines.length
        await frameA.locator(`#${name}`).click({ timeout: 10_000 })
        const msg = await waitMsg(page, 'click', 'probe', at, SLOW)
        return { console: consoleLines.slice(lines), probe: msg?.data ?? null }
      })
    }

    // A file input. Playwright takes the file chooser, so no dialog shows. The test cancels it.
    await step('fileInput', async () => {
      const at = (await messages(page)).length - 1
      const chooser = page.waitForEvent('filechooser', { timeout: 5000 }).catch(() => null)
      await frameA.locator('#file').click({ timeout: 10_000 })
      const opened = await chooser
      if (opened !== null) await opened.setFiles([])
      await page.waitForTimeout(500)
      return {
        chooser: opened !== null,
        probe: (await messages(page)).filter(m => m.index > at).map(m => m.data),
      }
    })

    // A file dropped on the frame, as the system drops it: on the drop zone, which takes it,
    // and on the page of the module, which does not.
    const dropFile = join(testHome, 'drop.txt')
    await writeFile(dropFile, 'probe drop')
    const cdp = await page.context().newCDPSession(page)
    const data = { dragOperationsMask: 1, files: [dropFile], items: [] }
    const drop = async (x: number, y: number) => {
      for (const type of ['dragEnter', 'dragOver', 'drop'] as const) {
        await cdp.send('Input.dispatchDragEvent', { data, type, x, y })
      }
    }
    await step('dropOnZone', async () => {
      const zone = await frameA.locator('#drop').boundingBox()
      if (zone === null) return { error: 'no drop zone' }
      const at = (await messages(page)).length - 1
      await drop(zone.x + zone.width / 2, zone.y + zone.height / 2)
      return { probe: (await waitMsg(page, 'drop', 'probe', at, 5000))?.data ?? null }
    })
    await step('dropOnPage', async () => {
      const box = await page.locator('#probe-a').boundingBox()
      if (box === null) return { error: 'no frame' }
      await drop(box.x + box.width - 10, box.y + box.height - 10)
      await page.waitForTimeout(1000)
      return { doc: await frameDocument(app as ElectronApplication, 'probe-a') }
    })
    report.end = {
      hits: [...servers.hits],
      top: page.url() === topUrl,
      windows: await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length),
    }
    // The results that keep the sandbox. The file chooser and the drop on the zone are only
    // recorded: a module can ask for a file that the user picks or drops.
    type Step = { alive?: boolean; console?: string[]; main?: { kind: string }[] }
    const r = report as Record<string, Step>
    expect(r.historyBack.alive).toBe(true)
    expect(r.historyBack.main?.map(e => e.kind)).toEqual(['will-frame-navigate'])
    expect(r.dropOnPage.alive).toBe(true)
    for (const name of ['downloadBlob', 'downloadOwn', 'mailto', 'appScheme', 'dropOnPage']) {
      expect(
        r[name].main?.filter(e => e.kind !== 'will-frame-navigate'),
        name,
      ).toEqual([])
    }
    // An external scheme stops at the frame-src rule of the Bifrost page, as a remote URL does.
    for (const name of ['mailto', 'appScheme']) {
      expect(r[name].console?.join(' '), name).toContain('frame-src bifrost-module:')
    }
    expect(page.url()).toBe(topUrl)
    expect(r.end).toEqual({ hits: [], top: true, windows: 1 })
  } finally {
    test.info().annotations.push({ description: JSON.stringify(report), type: 'more probes' })
    await app?.close().catch(() => {})
    servers.close()
    await rm(testHome, { force: true, recursive: true })
  }
})
