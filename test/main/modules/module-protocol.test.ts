import { execFileSync } from 'node:child_process'
import { link, mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { MAX_FILE_BYTES } from '../../../src/main/modules/module-files'
import {
  allowFrameNavigation,
  createModuleHandler,
  DEAD_PROXY,
  isModulePermission,
  isModuleUrl,
  MODULE_API_PATH,
  MODULE_CSP,
  MODULE_PERMISSIONS_POLICY,
  MODULE_PRIVILEGES,
  MODULE_SCHEME,
  moduleApiFile,
  moduleProxyConfig,
  moduleUrl,
} from '../../../src/main/modules/module-protocol'
import type {
  ModuleEntry,
  ModuleSource,
  ModulesState,
} from '../../../src/main/modules/module-state'

function entry(
  id: string,
  enabled: boolean,
  source: ModuleSource = { kind: 'folder', path: `/src/${id}` },
): ModuleEntry {
  return {
    dailyCap: 10,
    enabled,
    granted: [],
    hash: 'a'.repeat(64),
    jobs: { count: 0, day: '' },
    manifest: {
      description: 'A test.',
      id,
      minBifrost: '0.1.0',
      name: 'Demo',
      panels: [{ entry: 'panels/main.html', icon: 'bell', id: 'main', title: 'Demo' }],
      permissions: [],
      suggests: { dailyCap: null, model: null },
      version: '1.0.0',
    },
    model: 'sonnet',
    pendingUpdate: null,
    source,
  }
}

// The text of Bifrost's client library in this test.
const API_SOURCE = 'the client library of Bifrost'

let base = ''
let home = ''
let state: ModulesState = { modules: {} }
let handler: (req: Request) => Promise<Response>

// A request object that keeps the URL as given. The Request class resolves "." and "..", and
// the handler must also refuse a URL that the parser did not resolve.
function raw(url: string, method = 'GET'): Request {
  return { headers: new Headers(), method, url } as unknown as Request
}

async function get(url: string): Promise<Response> {
  return handler(new Request(url))
}

beforeAll(async () => {
  base = await mkdtemp(join(tmpdir(), 'bifrost-protocol-'))
  home = join(base, 'home')
  const code = join(home, 'modules', 'demo', 'current')
  const files: Record<string, string> = {
    '_bifrost/api.js': 'not the real api',
    '.git/config.js': 'hidden',
    '.hidden.js': 'hidden',
    'bifrost-module.json': '{}',
    'data.json': '{"a":1}',
    'fonts/a.woff2': 'font',
    'img/logo.png': 'png',
    'img/logo.svg': '<svg/>',
    noext: 'no extension',
    'panels/a#b?c%d.html': 'odd name',
    'panels/app.js': 'console.log(1)',
    'panels/main.html': '<p>main</p>',
    'panels/style.css': 'p{}',
    'tool.exe': 'binary',
  }
  for (const [path, text] of Object.entries(files)) {
    await mkdir(join(code, path, '..'), { recursive: true })
    await writeFile(join(code, path), text)
  }
  await writeFile(join(code, 'big.js'), Buffer.alloc(MAX_FILE_BYTES + 1))
  await writeFile(join(home, 'modules', 'demo', 'secret.txt'), 'secret')
  await writeFile(join(base, 'secret.txt'), 'secret')
  await mkdir(join(base, 'outside'), { recursive: true })
  await writeFile(join(base, 'outside', 'x.js'), 'outside')
  // Links that appeared after the install: one to a file outside, one to a file inside, and
  // one to a folder outside.
  await symlink(join(base, 'secret.txt'), join(code, 'panels', 'out.html'))
  await symlink(join(code, 'panels', 'main.html'), join(code, 'panels', 'in.html'))
  await symlink(join(base, 'outside'), join(code, 'linked'))
  // A module whose code folder is a link.
  await mkdir(join(home, 'modules', 'linked-root'), { recursive: true })
  await symlink(code, join(home, 'modules', 'linked-root', 'current'))
  // A hard link to a file outside, and a named pipe. A read of a pipe waits for a writer.
  await link(join(base, 'outside', 'x.js'), join(code, 'panels', 'hard.js'))
  execFileSync('/usr/bin/mkfifo', [join(code, 'panels', 'pipe.js')])
  state = {
    modules: {
      demo: entry('demo', true),
      'dev-demo': entry('dev-demo', true, { kind: 'dev', path: code }),
      'linked-root': entry('linked-root', true),
      missing: entry('missing', true),
      off: entry('off', false),
    },
  }
  handler = createModuleHandler({
    apiScript: async () => new TextEncoder().encode(API_SOURCE),
    codeDir: id => join(home, 'modules', id === 'dev-demo' ? 'demo' : id, 'current'),
    devAllowed: false,
    state: () => state,
  })
})

afterAll(async () => {
  await rm(base, { force: true, recursive: true })
})

describe('moduleUrl', () => {
  it('gives the URL of a module file', () => {
    expect(MODULE_SCHEME).toBe('bifrost-module')
    expect(moduleUrl('demo', 'panels/main.html')).toBe('bifrost-module://demo/panels/main.html')
  })

  it('encodes each path segment', () => {
    expect(moduleUrl('demo', 'panels/a#b?c%d.html')).toBe(
      'bifrost-module://demo/panels/a%23b%3Fc%25d.html',
    )
  })

  it('knows a module URL', () => {
    expect(isModuleUrl('bifrost-module://demo/panels/main.html')).toBe(true)
    expect(isModuleUrl('BIFROST-MODULE://demo/')).toBe(true)
    expect(isModuleUrl('file:///app/index.html')).toBe(false)
    expect(isModuleUrl('http://localhost:5173/')).toBe(false)
    expect(isModuleUrl('')).toBe(false)
    expect(isModuleUrl(undefined)).toBe(false)
  })
})

describe('the scheme', () => {
  it('has the privileges of the spike and no more', () => {
    expect(MODULE_PRIVILEGES).toEqual({ corsEnabled: true, secure: true, standard: true })
  })

  it('turns off the clipboard API and the devices', () => {
    for (const part of ['clipboard-read=()', 'clipboard-write=()', 'camera=()', 'microphone=()']) {
      expect(MODULE_PERMISSIONS_POLICY.split(', ')).toContain(part)
    }
  })

  it('reserves the path of the client library', () => {
    expect(MODULE_API_PATH).toBe('_bifrost/api.js')
  })

  it('finds the built client library next to the main build, also in the packaged app', () => {
    expect(moduleApiFile('/repo/out/main')).toBe('/repo/out/main/module-api/api.js')
    expect(moduleApiFile('/Applications/Bifrost.app/Contents/Resources/app.asar/out/main')).toBe(
      '/Applications/Bifrost.app/Contents/Resources/app.asar/out/main/module-api/api.js',
    )
  })

  it('has a sandboxed CSP with no network, no forms and no base', () => {
    for (const part of [
      "default-src 'none'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      "font-src 'self'",
      "connect-src 'none'",
      "form-action 'none'",
      "base-uri 'none'",
      'sandbox allow-scripts',
    ]) {
      expect(MODULE_CSP.split('; ')).toContain(part)
    }
  })
})

describe('createModuleHandler', () => {
  it('serves a file of an enabled module with the module headers', async () => {
    const res = await get('bifrost-module://demo/panels/main.html')
    expect(res.status).toBe(200)
    expect(await res.text()).toBe('<p>main</p>')
    expect(res.headers.get('content-security-policy')).toBe(MODULE_CSP)
    expect(res.headers.get('x-content-type-options')).toBe('nosniff')
    expect(res.headers.get('content-type')).toBe('text/html; charset=utf-8')
    expect(res.headers.get('permissions-policy')).toBe(MODULE_PERMISSIONS_POLICY)
    expect(res.headers.get('cache-control')).toBe('no-store')
  })

  it('gives the content type from the extension', async () => {
    const types: Record<string, string> = {
      'data.json': 'application/json',
      'fonts/a.woff2': 'font/woff2',
      'img/logo.png': 'image/png',
      'img/logo.svg': 'image/svg+xml',
      'panels/app.js': 'text/javascript; charset=utf-8',
      'panels/style.css': 'text/css; charset=utf-8',
    }
    for (const [path, type] of Object.entries(types)) {
      const res = await get(moduleUrl('demo', path))
      expect(res.status, path).toBe(200)
      expect(res.headers.get('content-type'), path).toBe(type)
    }
  })

  it('ignores the query and the fragment', async () => {
    const res = await get('bifrost-module://demo/panels/main.html?port=1#top')
    expect(res.status).toBe(200)
  })

  it('serves an entry name with # ? and % through moduleUrl', async () => {
    const res = await get(moduleUrl('demo', 'panels/a#b?c%d.html'))
    expect(res.status).toBe(200)
    expect(await res.text()).toBe('odd name')
  })

  it('gives 404 for an unknown or turned-off module', async () => {
    for (const url of [
      'bifrost-module://nope/panels/main.html',
      'bifrost-module://off/panels/main.html',
      'bifrost-module://missing/panels/main.html',
      'bifrost-module://constructor/panels/main.html',
    ]) {
      expect((await get(url)).status, url).toBe(404)
    }
  })

  it('gives 404 for a host that is not a module id', async () => {
    for (const url of [
      'bifrost-module://Demo/panels/main.html',
      'bifrost-module://demo:80/panels/main.html',
      'bifrost-module://x@demo/panels/main.html',
      'bifrost-module://demo',
      'bifrost-module:demo/panels/main.html',
      'file:///etc/hosts',
    ]) {
      expect((await handler(raw(url))).status, url).toBe(404)
    }
  })

  it('gives 404 for a path with ..', async () => {
    // The parser resolves these. The result must still stay in the code folder.
    for (const url of [
      'bifrost-module://demo/../secret.txt',
      'bifrost-module://demo/panels/../../secret.txt',
      'bifrost-module://demo/%2e%2e/%2e%2e/secret.txt',
      'bifrost-module://demo/panels/%2E%2e/../../../secret.txt',
    ]) {
      expect((await get(url)).status, url).toBe(404)
    }
    // The parser keeps these as they are.
    for (const url of [
      'bifrost-module://demo/panels/../../secret.txt',
      'bifrost-module://demo/panels/%2e%2e/%2e%2e/secret.txt',
      'bifrost-module://demo/..%2fsecret.txt',
      'bifrost-module://demo/%2e%2e%2fsecret.txt',
      'bifrost-module://demo/panels/..%5c..%5csecret.txt',
    ]) {
      expect((await handler(raw(url))).status, url).toBe(404)
    }
  })

  it('gives 404 for a dot segment or a dot file', async () => {
    for (const url of [
      'bifrost-module://demo/.hidden.js',
      'bifrost-module://demo/.git/config.js',
      'bifrost-module://demo/%2egit/config.js',
    ]) {
      expect((await get(url)).status, url).toBe(404)
    }
    for (const url of [
      'bifrost-module://demo/./panels/main.html',
      'bifrost-module://demo/panels/%2e/main.html',
      'bifrost-module://demo/panels//main.html',
    ]) {
      expect((await handler(raw(url))).status, url).toBe(404)
    }
  })

  it('gives 404 for a bad escape or a bad character', async () => {
    for (const url of [
      'bifrost-module://demo/panels/%zz.html',
      'bifrost-module://demo/panels%2fmain.html',
      'bifrost-module://demo/panels%5cmain.html',
      'bifrost-module://demo/panels/main%00.html',
    ]) {
      expect((await handler(raw(url))).status, url).toBe(404)
    }
  })

  it('gives 404 for a path that resolves outside the code folder', async () => {
    expect((await get('bifrost-module://demo/panels/out.html')).status).toBe(404)
    expect((await get('bifrost-module://demo/linked/x.js')).status).toBe(404)
  })

  it('gives 404 for a symbolic link that appeared after the install', async () => {
    expect((await get('bifrost-module://demo/panels/in.html')).status).toBe(404)
    expect((await get('bifrost-module://linked-root/panels/main.html')).status).toBe(404)
  })

  it('gives 404 for a missing file, a folder or an empty path', async () => {
    for (const url of [
      'bifrost-module://demo/panels/gone.html',
      'bifrost-module://demo/panels',
      'bifrost-module://demo/',
    ]) {
      expect((await get(url)).status, url).toBe(404)
    }
  })

  it('gives 404 for an unknown extension or no extension', async () => {
    expect((await get('bifrost-module://demo/tool.exe')).status).toBe(404)
    expect((await get('bifrost-module://demo/noext')).status).toBe(404)
  })

  it('serves the client library of Bifrost at the reserved path, never a module file', async () => {
    const res = await get(`bifrost-module://demo/${MODULE_API_PATH}`)
    expect(res.status).toBe(200)
    expect(await res.text()).toBe(API_SOURCE)
    expect(res.headers.get('content-type')).toBe('text/javascript; charset=utf-8')
    expect(res.headers.get('content-security-policy')).toBe(MODULE_CSP)
    expect(res.headers.get('x-content-type-options')).toBe('nosniff')
    expect(res.headers.get('cache-control')).toBe('no-store')
    expect((await get(`bifrost-module://demo/${MODULE_API_PATH}?v=2`)).status).toBe(200)
  })

  it('gives 404 for any other path in the reserved folder', async () => {
    for (const url of [
      'bifrost-module://demo/_BIFROST/api.js',
      'bifrost-module://demo/_bifrost/API.js',
      'bifrost-module://demo/_Bifrost/api.js',
      'bifrost-module://demo/_bifrost/other.js',
      'bifrost-module://demo/_bifrost/x/api.js',
      'bifrost-module://demo/_bifrost',
    ]) {
      expect((await get(url)).status, url).toBe(404)
    }
    for (const url of [
      'bifrost-module://demo/_bifrost/api.js/',
      'bifrost-module://demo/_bifrost%2fapi.js',
      'bifrost-module://demo/_bifrost/./api.js',
    ]) {
      expect((await handler(raw(url))).status, url).toBe(404)
    }
  })

  it('gives 404 for the client library of a module that is off, gone or dev', async () => {
    for (const id of ['off', 'nope', 'dev-demo', 'constructor']) {
      expect((await get(`bifrost-module://${id}/${MODULE_API_PATH}`)).status, id).toBe(404)
    }
  })

  it('gives 404 for the client library when Bifrost cannot read it', async () => {
    for (const apiScript of [async () => null, () => null]) {
      const noApi = createModuleHandler({
        apiScript,
        codeDir: () => join(home, 'modules', 'demo', 'current'),
        devAllowed: false,
        state: () => state,
      })
      const res = await noApi(new Request(`bifrost-module://demo/${MODULE_API_PATH}`))
      expect(res.status).toBe(404)
    }
  })

  it('gives 404 for a file over the size limit', async () => {
    expect((await get('bifrost-module://demo/big.js')).status).toBe(404)
  })

  it('gives 404 for a file with a second hard link', async () => {
    expect((await get('bifrost-module://demo/panels/hard.js')).status).toBe(404)
  })

  it('gives 404 for a named pipe at once', async () => {
    const res = await Promise.race([
      get('bifrost-module://demo/panels/pipe.js'),
      new Promise<'waited'>(r => setTimeout(() => r('waited'), 2000)),
    ])
    expect(res === 'waited' ? res : res.status).toBe(404)
  })

  it('refuses a dev module in a packaged app', async () => {
    expect((await get('bifrost-module://dev-demo/panels/main.html')).status).toBe(404)
  })

  it('serves a dev module when dev modules are allowed', async () => {
    const dev = createModuleHandler({
      apiScript: () => null,
      codeDir: () => join(home, 'modules', 'demo', 'current'),
      devAllowed: true,
      state: () => state,
    })
    const res = await dev(new Request('bifrost-module://dev-demo/panels/main.html'))
    expect(res.status).toBe(200)
  })

  it('gives 404 for a method other than GET', async () => {
    expect((await handler(raw('bifrost-module://demo/panels/main.html', 'POST'))).status).toBe(404)
  })

  it('gives 404 when the code folder is not an absolute path', async () => {
    const relative = createModuleHandler({
      apiScript: () => null,
      codeDir: () => '',
      devAllowed: false,
      state: () => state,
    })
    expect((await relative(new Request('bifrost-module://demo/panels/main.html'))).status).toBe(404)
  })

  it('sends the module headers with a 404', async () => {
    const res = await get('bifrost-module://nope/panels/main.html')
    expect(res.headers.get('content-security-policy')).toBe(MODULE_CSP)
    expect(res.headers.get('x-content-type-options')).toBe('nosniff')
  })

  it('reads the state at each request', async () => {
    const before = state
    state = { modules: { ...state.modules, demo: entry('demo', false) } }
    expect((await get('bifrost-module://demo/panels/main.html')).status).toBe(404)
    state = before
    expect((await get('bifrost-module://demo/panels/main.html')).status).toBe(200)
  })
})

describe('isModulePermission', () => {
  it('is true for a module frame', () => {
    expect(isModulePermission({ requestingUrl: 'bifrost-module://demo/panels/main.html' })).toBe(
      true,
    )
    expect(
      isModulePermission({ origin: '', requestingUrl: 'bifrost-module://demo/panels/main.html' }),
    ).toBe(true)
    expect(isModulePermission({ origin: 'bifrost-module://demo' })).toBe(true)
    expect(isModulePermission({ securityOrigin: 'bifrost-module://demo/' })).toBe(true)
    expect(isModulePermission({ origin: 'null', requestingUrl: 'about:blank' })).toBe(true)
  })

  it('is false for the Bifrost page', () => {
    expect(isModulePermission({ origin: 'file://', requestingUrl: 'file:///a/index.html' })).toBe(
      false,
    )
    expect(
      isModulePermission({
        origin: 'http://localhost:5173',
        requestingUrl: 'http://localhost:5173/',
      }),
    ).toBe(false)
    expect(isModulePermission({})).toBe(false)
  })
})

describe('allowFrameNavigation', () => {
  const MODULE = 'bifrost-module://demo/panels/main.html'

  it('leaves the main frame to the page guard', () => {
    expect(allowFrameNavigation({ byTop: false, isMainFrame: true, url: 'https://x.test/' })).toBe(
      true,
    )
  })

  it('allows a module load that the Bifrost page starts', () => {
    expect(allowFrameNavigation({ byTop: true, isMainFrame: false, url: MODULE })).toBe(true)
  })

  it('refuses a load that a module starts', () => {
    expect(allowFrameNavigation({ byTop: false, isMainFrame: false, url: MODULE })).toBe(false)
    expect(
      allowFrameNavigation({
        byTop: false,
        isMainFrame: false,
        url: 'bifrost-module://other/panels/main.html',
      }),
    ).toBe(false)
  })

  it('refuses a frame load of another scheme', () => {
    for (const url of ['https://x.test/', 'data:text/html,x', 'file:///etc/hosts', 'about:blank']) {
      expect(allowFrameNavigation({ byTop: true, isMainFrame: false, url }), url).toBe(false)
    }
  })
})

describe('moduleProxyConfig', () => {
  it('sends all requests of the default session to a dead proxy', () => {
    expect(DEAD_PROXY).toBe('http://127.0.0.1:9')
    expect(moduleProxyConfig(null)).toEqual({
      mode: 'fixed_servers',
      proxyBypassRules: '<-loopback>',
      proxyRules: 'http://127.0.0.1:9',
    })
  })

  it('lets only the host of the dev page bypass the proxy', () => {
    expect(moduleProxyConfig('http://localhost:5173/').proxyBypassRules).toBe(
      '<-loopback>,localhost:5173',
    )
    expect(moduleProxyConfig('http://[::1]:5173').proxyBypassRules).toBe('<-loopback>,[::1]:5173')
  })

  it('ignores a dev URL that is not http', () => {
    expect(moduleProxyConfig('not a url').proxyBypassRules).toBe('<-loopback>')
    expect(moduleProxyConfig('file:///x/index.html').proxyBypassRules).toBe('<-loopback>')
  })
})
