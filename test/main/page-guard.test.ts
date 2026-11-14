// The page check of each IPC handler (global constraint: each handler goes through fromPage).
// Only the top frame of the live Bifrost page can send a message. A frame inside the page, for
// example a module frame, gets a refusal on each channel. The events are fakes.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { createFromPage, REFUSED_NOT_PAGE } from '../../src/main/page-guard'

interface FakeSender {
  id: number
  mainFrame: object
}

const PAGE: FakeSender = { id: 1, mainFrame: { name: 'top' } }
const OTHER: FakeSender = { id: 2, mainFrame: { name: 'other top' } }
const SUBFRAME = { name: 'module frame' }

function setup() {
  let live = true
  const calls: string[] = []
  const fromPage = createFromPage<FakeSender>(sender => live && sender.id === PAGE.id)
  // Ordinary channels, as ipc.ts registers them.
  const handlers = {
    'settings:get': (e: { sender: FakeSender; senderFrame: unknown }) =>
      fromPage(e, async () => {
        calls.push('settings:get')
        return 'the settings'
      }),
  }
  return {
    calls,
    end: () => {
      live = false
    },
    handlers,
  }
}

describe('fromPage', () => {
  it('runs the call for the top frame of the live page', async () => {
    const t = setup()
    const e = { sender: PAGE, senderFrame: PAGE.mainFrame }
    await expect(t.handlers['settings:get'](e)).resolves.toBe('the settings')
    expect(t.calls).toEqual(['settings:get'])
  })

  it('refuses a frame inside the page on an ordinary channel', async () => {
    const t = setup()
    const e = { sender: PAGE, senderFrame: SUBFRAME }
    await expect(t.handlers['settings:get'](e)).rejects.toThrow(REFUSED_NOT_PAGE)
    expect(t.calls).toEqual([])
  })

  it('refuses a sender frame that is gone', async () => {
    const t = setup()
    const e = { sender: PAGE, senderFrame: null }
    await expect(t.handlers['settings:get'](e)).rejects.toThrow(REFUSED_NOT_PAGE)
    expect(t.calls).toEqual([])
  })

  it('refuses the top frame of another web contents, and a page that ended', async () => {
    const t = setup()
    const other = { sender: OTHER, senderFrame: OTHER.mainFrame }
    await expect(t.handlers['settings:get'](other)).rejects.toThrow(REFUSED_NOT_PAGE)
    t.end()
    const top = { sender: PAGE, senderFrame: PAGE.mainFrame }
    await expect(t.handlers['settings:get'](top)).rejects.toThrow(REFUSED_NOT_PAGE)
    expect(t.calls).toEqual([])
  })

  it('checks the live page before it reads the frame', async () => {
    // A destroyed web contents can throw when a call reads its main frame.
    const fromPage = createFromPage<FakeSender>(() => false)
    const gone = {
      id: 1,
      get mainFrame(): object {
        throw new Error('Object has been destroyed')
      },
    }
    await expect(fromPage({ sender: gone, senderFrame: null }, async () => 1)).rejects.toThrow(
      REFUSED_NOT_PAGE,
    )
  })
})

// ipc.ts imports Electron, so a unit test cannot load it. These checks read its text.
describe('the page check wiring', () => {
  const read = (path: string): string =>
    readFileSync(join(__dirname, '../..', path), 'utf8').replace(/\s+/g, ' ')
  const ipc = read('src/main/ipc.ts')
  const index = read('src/main/index.ts')

  it('makes fromPage from the page check and the live page of the window', () => {
    expect(ipc).toContain(
      'const fromPage = createFromPage<WebContents>(sender => isLivePage(sender, page.token()))',
    )
    // One check for each handler. No handler has a check of its own.
    expect(ipc).not.toContain('fromModulePage')
    expect(ipc).not.toContain('senderFrame')
  })

  it('gives the preload only to the top frame of the window', () => {
    // A frame inside the page then has no ipcRenderer, so no Bifrost frame inside the page sends
    // a message.
    expect(index).toContain("preload: join(import.meta.dirname, '../preload/index.cjs')")
    expect(index).not.toContain('nodeIntegrationInSubFrames')
  })
})
