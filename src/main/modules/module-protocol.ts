// The module protocol and the frame rules (Modules design 8.1, spike A rulings S-A1 to S-A5).
// bifrost-module://<id>/<path> serves the files of one enabled module, and nothing else.
// This file has no Electron import. index.ts gives the handler to protocol.handle and uses the
// rules below in the session handlers.

import { constants } from 'node:fs'
import { lstat, open, realpath } from 'node:fs/promises'
import { extname, isAbsolute, join } from 'node:path'
import { MODULE_ID_PATTERN } from '../../shared/module-manifest'
import { isModuleUrl, MODULE_SCHEME } from '../../shared/module-url'
import { MAX_FILE_BYTES } from './module-files'
import type { ModulesState } from './module-state'

export { isModuleUrl, MODULE_SCHEME, moduleUrl } from '../../shared/module-url'

// Module scripts need corsEnabled (ruling S-A2). No bypassCSP, fetch API or service workers.
export const MODULE_PRIVILEGES = Object.freeze({ corsEnabled: true, secure: true, standard: true })

// The path of the client library. The protocol serves Bifrost's file at this path for each
// module that is on. A module file never replaces it.
export const MODULE_API_PATH = '_bifrost/api.js'
const RESERVED_FOLDER = '_bifrost'

// The built client library. The main build compiles src/module-api/api.ts to this file, next to
// the main script (scripts/module-api/build.ts). In the packaged app, the file is in app.asar.
export function moduleApiFile(mainDir: string): string {
  return join(mainDir, 'module-api', 'api.js')
}

// No network, no forms, no base and no frames. The sandbox directive keeps the document
// sandboxed also when a frame has no sandbox attribute.
export const MODULE_CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self'",
  "connect-src 'none'",
  "form-action 'none'",
  "base-uri 'none'",
  'sandbox allow-scripts',
].join('; ')

// Turn off the clipboard API and the devices for the module document. A frame with no "allow"
// attribute already gets none of them, so this is a second layer. It does not stop
// execCommand('copy') after a click in the frame (ruling S-A4, accepted).
export const MODULE_PERMISSIONS_POLICY = [
  'camera=()',
  'clipboard-read=()',
  'clipboard-write=()',
  'display-capture=()',
  'geolocation=()',
  'microphone=()',
].join(', ')

// The content type of each extension that the protocol serves. Other files get 404.
const TYPES: Readonly<Record<string, string>> = Object.freeze({
  '.css': 'text/css; charset=utf-8',
  '.gif': 'image/gif',
  '.html': 'text/html; charset=utf-8',
  '.jpeg': 'image/jpeg',
  '.jpg': 'image/jpeg',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.mjs': 'text/javascript; charset=utf-8',
  '.otf': 'font/otf',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf',
  '.txt': 'text/plain; charset=utf-8',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
})

export interface ModuleHandlerDeps {
  // The newest state. The handler reads it at each request.
  state(): ModulesState
  // The absolute path of the code folder of a module.
  codeDir(id: string): string
  // False in a packaged app. Then the protocol serves no module with a dev source.
  devAllowed: boolean
  // The bytes of the client library, or null when Bifrost cannot read it.
  apiScript(): Uint8Array | null | Promise<Uint8Array | null>
}

function moduleHeaders(type: string): Record<string, string> {
  return {
    'Cache-Control': 'no-store',
    'Content-Security-Policy': MODULE_CSP,
    'Content-Type': type,
    'Permissions-Policy': MODULE_PERMISSIONS_POLICY,
    'X-Content-Type-Options': 'nosniff',
  }
}

function notFound(): Response {
  return new Response('Not found', {
    headers: moduleHeaders('text/plain; charset=utf-8'),
    status: 404,
  })
}

// A segment must not be empty, must not start with a dot, and must not hold a separator, NUL
// or another control character.
function isSafeSegment(segment: string): boolean {
  // biome-ignore lint/suspicious/noControlCharactersInRegex: the check refuses control characters
  return segment !== '' && !segment.startsWith('.') && !/[/\\\u0000-\u001f\u007f]/.test(segment)
}

// Read the module id and the decoded path segments from the raw URL text. The parser of the
// caller can resolve "." and "..". This check does not depend on it: it refuses each dot
// segment, also an encoded one.
function parseModuleUrl(url: string): { id: string; segments: string[] } | null {
  const prefix = `${MODULE_SCHEME}://`
  if (!url.startsWith(prefix)) return null
  const rest = url.slice(prefix.length)
  const end = rest.search(/[?#]/)
  const main = end === -1 ? rest : rest.slice(0, end)
  const slash = main.indexOf('/')
  if (slash === -1) return null
  const id = main.slice(0, slash)
  if (!MODULE_ID_PATTERN.test(id)) return null
  const segments: string[] = []
  for (const raw of main.slice(slash + 1).split('/')) {
    let segment: string
    try {
      segment = decodeURIComponent(raw)
    } catch {
      return null
    }
    if (!isSafeSegment(segment)) return null
    segments.push(segment)
  }
  return { id, segments }
}

// Read a file of the code folder. Refuse a code folder that is a link, a link at any level
// under it, a file that is not a regular file, a file with a second hard link, and a file over
// the size limit. O_NONBLOCK makes the open of a named pipe return at once.
async function readModuleFile(root: string, segments: string[]): Promise<Buffer | null> {
  if (!isAbsolute(root)) return null
  try {
    if (!(await lstat(root)).isDirectory()) return null
    const expected = join(await realpath(root), ...segments)
    const real = await realpath(join(root, ...segments))
    if (real !== expected) return null
    const flags = constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK
    const handle = await open(real, flags)
    try {
      const info = await handle.stat()
      if (!info.isFile() || info.nlink > 1 || info.size > MAX_FILE_BYTES) return null
      return await handle.readFile()
    } finally {
      await handle.close()
    }
  } catch {
    return null
  }
}

// The handler of the module protocol. It serves a file only of a module that is in the state
// (so the user approved it) and is on. A packaged app serves no dev module. Each refusal is a
// 404 with the module headers.
export function createModuleHandler(deps: ModuleHandlerDeps): (req: Request) => Promise<Response> {
  return async req => {
    if (req.method !== 'GET') return notFound()
    const parsed = parseModuleUrl(req.url)
    if (parsed === null) return notFound()
    const { id, segments } = parsed
    const modules = deps.state().modules
    const entry = Object.hasOwn(modules, id) ? modules[id] : undefined
    if (entry?.enabled !== true) return notFound()
    if (entry.source.kind === 'dev' && !deps.devAllowed) return notFound()
    if (segments.join('/') === MODULE_API_PATH) {
      const api = await Promise.resolve()
        .then(() => deps.apiScript())
        .catch(() => null)
      if (api === null) return notFound()
      return new Response(new Uint8Array(api), {
        headers: moduleHeaders(TYPES['.js'] as string),
        status: 200,
      })
    }
    if (segments[0].toLowerCase() === RESERVED_FOLDER) return notFound()
    const type = TYPES[extname(segments[segments.length - 1]).toLowerCase()]
    if (type === undefined) return notFound()
    const body = await readModuleFile(deps.codeDir(id), segments)
    if (body === null) return notFound()
    return new Response(new Uint8Array(body), { headers: moduleHeaders(type), status: 200 })
  }
}

// The parts of a permission request or check that tell which frame asks.
export interface PermissionAsker {
  origin?: string
  requestingUrl?: string
  securityOrigin?: string
}

// True when a module frame asks. Bifrost refuses each permission then (ruling S-A3). A module
// check can come with the origin "" and the module URL as requestingUrl. A frame with an opaque
// origin gives "null".
export function isModulePermission(asker: PermissionAsker): boolean {
  return (
    isModuleUrl(asker.origin) ||
    isModuleUrl(asker.requestingUrl) ||
    isModuleUrl(asker.securityOrigin) ||
    asker.origin === 'null'
  )
}

// The rule of will-frame-navigate (ruling S-A3). A subframe loads only a module URL, and only
// when the Bifrost page (the top frame) starts the load. A module cannot move any frame.
// The main frame has its own guard (will-navigate).
export function allowFrameNavigation(nav: {
  isMainFrame: boolean
  byTop: boolean
  url: string
}): boolean {
  if (nav.isMainFrame) return true
  return nav.byTop && isModuleUrl(nav.url)
}

// A proxy that does not exist. With the WebRTC policy disable_non_proxied_udp, WebRTC in a
// module frame must use it, so it cannot send a packet (ruling S-A1).
export const DEAD_PROXY = 'http://127.0.0.1:9'

// The proxy of the default session. "<-loopback>" sends loopback requests to the proxy too.
// In a dev run, only the host of the dev page bypasses it. A later rule wins over an earlier
// one, so the dev host comes last.
export function moduleProxyConfig(devUrl: string | null): {
  mode: 'fixed_servers'
  proxyRules: string
  proxyBypassRules: string
} {
  const rules = ['<-loopback>']
  if (devUrl !== null) {
    try {
      const url = new URL(devUrl)
      if (url.protocol === 'http:' || url.protocol === 'https:') rules.push(url.host)
    } catch {
      // Not a URL. No host bypasses the proxy.
    }
  }
  return { mode: 'fixed_servers', proxyBypassRules: rules.join(','), proxyRules: DEAD_PROXY }
}
