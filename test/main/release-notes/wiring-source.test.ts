// Source checks of the release notes wiring (ipc.ts, preload, API). ipc.ts imports Electron, so a
// unit test cannot load it. These checks read its text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const ROOT = join(__dirname, '../../..')
const read = (file: string): string => readFileSync(join(ROOT, file), 'utf8')
const ipc = read('src/main/ipc.ts')

// One space for each run of white space, so a line break of the formatter does not matter.
const flat = (text: string): string =>
  text
    .replace(/\s+/g, ' ')
    .replace(/([([]) /g, '$1')
    .replace(/ ([)\]])/g, '$1')

const RELEASE_BUILD =
  "app.isPackaged && home === null && existsSync(join(process.resourcesPath, 'app-update.yml'))"

describe('the release notes wiring in ipc.ts', () => {
  it("makes What's new only in a release build, as the updater", () => {
    const text = flat(ipc)
    expect(text).toContain(`const releaseBuild = ${RELEASE_BUILD}`)
    expect(text.match(/\bcreateWhatsNew\(/g)).toHaveLength(1)
    expect(text).toMatch(
      /const whatsNew = releaseBuild \? createWhatsNew\(\{[^}]*version: app\.getVersion\(\)/,
    )
    expect(text).toContain(
      "openStore: () => openReleaseNotesStore(releaseNotesFile(app.getPath('userData')))",
    )
    expect(text).toContain('setupDone: async () => (await settings).get().setupDone')
    expect(text).toMatch(/createWhatsNew\(\{[^}]*\}\) : null/)
  })

  it('reads GitHub with net.fetch, and a file of the test home in a test home', () => {
    expect(flat(ipc)).toContain(
      "fetch: home ? fileFetch(join(home.home, 'github-releases.json')) : " +
        '(url, init) => net.fetch(url, init)',
    )
  })

  it('runs each release notes handler only for the Bifrost page', () => {
    const channels = [...ipc.matchAll(/ipcMain\.handle\('(release-notes:[a-z-]+)'/g)].map(m => m[1])
    expect(channels.sort()).toEqual([
      'release-notes:list',
      'release-notes:open',
      'release-notes:whats-new',
    ])
    const text = flat(ipc)
    expect(text).toContain(
      "ipcMain.handle('release-notes:list', e => fromPage(e, () => releaseNotes.list()))",
    )
    expect(text).toContain(
      "ipcMain.handle('release-notes:whats-new', e => " +
        'fromPage(e, async () => (await whatsNew?.take()) ?? null)',
    )
    // The page sends a version or null. The main process finds the URL.
    expect(text).toContain(
      "ipcMain.handle('release-notes:open', (e, version: unknown) => " +
        'fromPage(e, async () => shell.openExternal(releaseNotes.urlOf(version)))',
    )
  })

  it('has the three calls in the API and the preload', () => {
    const api = flat(read('src/shared/api.ts'))
    expect(api).toContain('list(): Promise<ReleaseNotesResult>')
    expect(api).toContain('whatsNew(): Promise<WhatsNewStart | null>')
    expect(api).toContain('open(version: string | null): Promise<void>')
    const preload = read('src/preload/index.ts')
    expect(preload).toContain("list: () => invoke('release-notes:list')")
    expect(preload).toContain("open: version => invoke('release-notes:open', version)")
    expect(preload).toContain("whatsNew: () => invoke('release-notes:whats-new')")
  })
})
