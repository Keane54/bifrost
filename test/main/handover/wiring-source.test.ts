// Source checks of the Hand over wiring (ipc.ts, preload, API). ipc.ts imports Electron, so a unit
// test cannot load it. These checks read its text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const ROOT = join(__dirname, '../../..')
const read = (file: string): string => readFileSync(join(ROOT, file), 'utf8')

// One space for each run of white space, so a line break of the formatter does not matter.
const flat = (text: string): string =>
  text
    .replace(/\s+/g, ' ')
    .replace(/([([{]) /g, '$1')
    .replace(/ ([)\]}])/g, '$1')

const ipc = flat(read('src/main/ipc.ts'))

// The text of the object that a call gets, up to the first "})".
function argsOf(text: string, call: string): string {
  const at = text.indexOf(`${call}({`)
  expect(at, call).toBeGreaterThan(-1)
  return text.slice(at, text.indexOf('})', at))
}

describe('the Hand over wiring in ipc.ts', () => {
  it('runs the handler only for the Bifrost page', () => {
    expect(ipc.split("ipcMain.handle('sessions:hand-over'")).toHaveLength(2)
    expect(ipc).toContain(
      "ipcMain.handle('sessions:hand-over', (e, sessionId: unknown) => " +
        'fromPage(e, () => sessions.handOver(sessionId))',
    )
  })

  it('makes the run with the deps of the brief', () => {
    expect(ipc.match(/\bcreateHandOver\(/g)).toHaveLength(1)
    const deps = argsOf(ipc, 'createHandOver')
    expect(deps).toContain('rows: () => liveService?.rows() ?? []')
    expect(deps).toContain('send: (id, text) => input.send(id, text)')
    expect(deps).toContain("readFile(handOverRulesPath(app.getAppPath()), 'utf8')")
    expect(deps).toContain('transcript: row => findTranscript(projectsDir, row)')
    expect(deps).toContain('size: async file => (await stat(file)).size')
    expect(deps).toContain(
      'readTail: (file, offset) => readTail(file, offset, TRANSCRIPT_TAIL_MAX)',
    )
    expect(deps).toContain('requestId: () => randomUUID().slice(0, 8)')
    expect(deps).toContain('now: () => Date.now()')
  })

  it('writes each note to the handovers folder under paths.bifrostHome', () => {
    const deps = argsOf(ipc, 'createHandOver')
    expect(deps).toContain(
      "writeNoteFile(join(paths.bifrostHome, 'handovers'), noteFileName(name, at), note)",
    )
  })

  it('passes the run to createSessionActions', () => {
    expect(argsOf(ipc, 'createSessionActions')).toMatch(/\bhandOver,/)
  })
})

describe('the Hand over API', () => {
  it('has the preload entry and the API type', () => {
    expect(flat(read('src/preload/index.ts'))).toContain(
      "handOver: sessionId => invoke('sessions:hand-over', sessionId)",
    )
    expect(flat(read('src/shared/api.ts'))).toContain(
      'handOver(sessionId: string): Promise<HandOverResult>',
    )
  })
})
