// The links of a chat window (spec 8.5). Claude Code prints its links as terminal hyperlinks
// (OSC 8). A click on a link sends it here, and Bifrost opens it outside the app, with no dialog
// (user decision, 2026-11-10):
// - An http or https link opens in the default browser.
// - A file link of this Mac opens the file or the folder in its default app.
// - A file that can run code (an app, an executable file or a script) does not open. Finder
//   shows it instead, so a click on a link never runs a program.
// All other links do nothing.

// The longest link that Bifrost opens. A longer text is not a real link.
export const MAX_LINK_LENGTH = 4096

// The extensions of files and bundles that macOS can run or install when it opens them.
const RUNNABLE_EXTENSIONS: ReadonlySet<string> = new Set([
  '.action',
  '.app',
  '.applescript',
  '.bash',
  '.command',
  '.csh',
  '.fileloc',
  '.inetloc',
  '.jar',
  '.kext',
  '.ksh',
  '.mpkg',
  '.pkg',
  '.pl',
  '.prefpane',
  '.py',
  '.rb',
  '.scpt',
  '.scptd',
  '.sh',
  '.shortcut',
  '.terminal',
  '.tool',
  '.webloc',
  '.workflow',
  '.zsh',
])

export type LinkTarget = { kind: 'web'; url: string } | { kind: 'file'; path: string }

// The target of a link, or null when Bifrost must not open it. A file link must have no host,
// "localhost" or the host name of this Mac.
export function linkTarget(uri: unknown, localHost: string): LinkTarget | null {
  if (typeof uri !== 'string' || uri.length === 0 || uri.length > MAX_LINK_LENGTH) return null
  let url: URL
  try {
    url = new URL(uri)
  } catch {
    return null
  }
  if (url.protocol === 'http:' || url.protocol === 'https:') return { kind: 'web', url: url.href }
  if (url.protocol !== 'file:') return null
  const host = url.hostname.toLowerCase()
  if (host !== '' && host !== 'localhost' && host !== localHost.toLowerCase()) return null
  let path: string
  try {
    path = decodeURIComponent(url.pathname)
  } catch {
    return null
  }
  return path.startsWith('/') ? { kind: 'file', path } : null
}

// The extension of the last part of a path, in lower case, or ''.
function extension(path: string): string {
  const name = path.slice(path.lastIndexOf('/') + 1)
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot).toLowerCase() : ''
}

export interface LinkDeps {
  hostname(): string
  openExternal(url: string): Promise<void>
  // Electron's shell.openPath gives an error text, or '' when the open worked.
  openPath(path: string): Promise<string>
  showItemInFolder(path: string): void
  stat(path: string): Promise<{ isDirectory(): boolean; mode: number }>
}

// Open the link of a chat window, or do nothing. A missing file does nothing.
export async function openLink(uri: unknown, deps: LinkDeps): Promise<void> {
  const target = linkTarget(uri, deps.hostname())
  if (target === null) return
  if (target.kind === 'web') {
    await deps.openExternal(target.url)
    return
  }
  let info: { isDirectory(): boolean; mode: number }
  try {
    info = await deps.stat(target.path)
  } catch {
    return
  }
  const executable = !info.isDirectory() && (info.mode & 0o111) !== 0
  if (executable || RUNNABLE_EXTENSIONS.has(extension(target.path))) {
    deps.showItemInFolder(target.path)
    return
  }
  await deps.openPath(target.path)
}
