// Tests of the IPC wiring of dictation. The handlers run with a fake ipcMain.handle, a fake
// fromPage and a fake service. A source check covers the parts that stay in ipc.ts.
import { readFileSync } from 'node:fs'
import type { IpcMainInvokeEvent } from 'electron'
import { describe, expect, it, vi } from 'vitest'
import {
  chatEventSender,
  REFUSED_PANE,
  registerDictationIpc,
} from '../../../src/main/dictation/dictation-ipc'
import { REFUSED_NO_TERMINAL } from '../../../src/main/dictation/dictation-service'
import { REFUSED_NOT_CHAT } from '../../../src/main/pty/can-attach'

const A = 'chat:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const NOT_PAGE = 'refused: not the Bifrost page'
const CHANNELS = [
  'dictation:warm',
  'dictation:start',
  'dictation:stop',
  'dictation:vim-mode',
  'dictation:open-settings',
] as const
// The two panes of System Settings that dictation can open (dictation design 7).
const MIC_URL = 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'
const SPEECH_URL =
  'x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition'

type Listener = (e: IpcMainInvokeEvent, ...args: unknown[]) => Promise<unknown>

// Register the handlers. page false makes fromPage refuse, as for another webContents.
function setup(opts: { page?: boolean; terminal?: boolean; vim?: boolean } = {}) {
  const handlers = new Map<string, Listener>()
  const service = { start: vi.fn(), stop: vi.fn(), stopAll: vi.fn(), warm: vi.fn() }
  // Counts the calls of fromPage.
  const pageCalls = vi.fn()
  const fromPage = <T>(_e: IpcMainInvokeEvent, fn: () => Promise<T>): Promise<T> => {
    pageCalls()
    if (opts.page === false) return Promise.reject(new Error(NOT_PAGE))
    return fn()
  }
  const hasTerminal = vi.fn((_viewId: string) => opts.terminal ?? true)
  const vimMode = vi.fn(async () => opts.vim ?? false)
  // A fake: no test opens System Settings.
  const openExternal = vi.fn(async (_url: string) => {})
  registerDictationIpc({
    fromPage,
    handle: (channel, listener) => {
      handlers.set(channel, listener)
    },
    hasTerminal,
    openExternal,
    service: () => service,
    vimMode,
  })
  const call = (channel: string, ...args: unknown[]): Promise<unknown> => {
    const listener = handlers.get(channel)
    if (listener === undefined) throw new Error(`no handler for ${channel}`)
    return listener({} as IpcMainInvokeEvent, ...args)
  }
  return { call, handlers, hasTerminal, openExternal, pageCalls, service, vimMode }
}

describe('the dictation handlers', () => {
  it('register the five channels', () => {
    expect([...setup().handlers.keys()].sort()).toEqual([...CHANNELS].sort())
  })

  it.each(CHANNELS)('%s goes through fromPage, and a refusal calls nothing', async channel => {
    const t = setup({ page: false })
    await expect(t.call(channel, A)).rejects.toThrow(NOT_PAGE)
    expect(t.pageCalls).toHaveBeenCalledTimes(1)
    expect(t.service.warm).not.toHaveBeenCalled()
    expect(t.service.start).not.toHaveBeenCalled()
    expect(t.service.stop).not.toHaveBeenCalled()
    expect(t.vimMode).not.toHaveBeenCalled()
    expect(t.openExternal).not.toHaveBeenCalled()
  })

  it('vim-mode gives the vim mode of Claude to the page', async () => {
    await expect(setup({ vim: true }).call('dictation:vim-mode')).resolves.toBe(true)
    await expect(setup().call('dictation:vim-mode')).resolves.toBe(false)
  })

  it('warm, start and stop call the service for the page', async () => {
    const t = setup()
    await t.call('dictation:warm')
    await t.call('dictation:start', A)
    await t.call('dictation:stop', A)
    expect(t.service.warm).toHaveBeenCalledTimes(1)
    expect(t.service.start).toHaveBeenCalledWith(A)
    expect(t.service.stop).toHaveBeenCalledWith(A)
  })

  it.each([42, null, 'chat:bad', 'send:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', `${A}x`])(
    'start and stop refuse %s, which is not a chat view',
    async value => {
      const t = setup()
      await expect(t.call('dictation:start', value)).rejects.toThrow(REFUSED_NOT_CHAT)
      await expect(t.call('dictation:stop', value)).rejects.toThrow(REFUSED_NOT_CHAT)
      expect(t.service.start).not.toHaveBeenCalled()
      expect(t.service.stop).not.toHaveBeenCalled()
    },
  )

  it('open-settings opens exactly the Microphone or the Speech Recognition pane', async () => {
    const t = setup()
    await t.call('dictation:open-settings', 'microphone')
    await t.call('dictation:open-settings', 'speech-recognition')
    expect(t.openExternal.mock.calls).toEqual([[MIC_URL], [SPEECH_URL]])
  })

  it.each([
    MIC_URL,
    'https://example.com',
    'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera',
    'Microphone',
    'toString',
    '__proto__',
    'constructor',
    42,
    null,
    undefined,
  ])('open-settings refuses %s, which is not a pane name of the list', async value => {
    const t = setup()
    await expect(t.call('dictation:open-settings', value)).rejects.toThrow(REFUSED_PANE)
    expect(t.openExternal).not.toHaveBeenCalled()
  })

  it('start refuses a chat view with no terminal, and stop still stops it', async () => {
    const t = setup({ terminal: false })
    await expect(t.call('dictation:start', A)).rejects.toThrow(REFUSED_NO_TERMINAL)
    expect(t.hasTerminal).toHaveBeenCalledWith(A)
    expect(t.service.start).not.toHaveBeenCalled()
    await t.call('dictation:stop', A)
    expect(t.service.stop).toHaveBeenCalledWith(A)
  })
})

describe('chatEventSender', () => {
  it('sends an event only to a chat view that has a terminal', () => {
    const open = new Set([A])
    const send = vi.fn()
    const give = chatEventSender(viewId => open.has(viewId), send)
    give(A, { t: 'level', v: 0.5 })
    expect(send).toHaveBeenCalledWith('dictation:event', A, { t: 'level', v: 0.5 })
    open.delete(A)
    give(A, { final: '', t: 'end' })
    expect(send).toHaveBeenCalledTimes(1)
  })
})

describe('the dictation wiring in ipc.ts', () => {
  const ipc = readFileSync('src/main/ipc.ts', 'utf8')
  const between = (from: string, to: string): string => {
    const start = ipc.indexOf(from)
    expect(start, from).toBeGreaterThanOrEqual(0)
    return ipc.slice(start, ipc.indexOf(to, start + from.length))
  }

  it('registers the handlers with fromPage and the terminal check', () => {
    const call = between('registerDictationIpc({', '})')
    expect(call).toContain('fromPage')
    expect(call).toContain('hasTerminal')
    expect(call).toContain('vimMode: () => vimMode()')
    expect(call).toContain('openExternal: url => shell.openExternal(url)')
    expect(ipc).toContain('createVimModeCheck(vimFiles, { read: readClaudeJson, stat: fileStamp })')
    expect(ipc).not.toMatch(/ipcMain\.handle\(\s*'dictation:/)
  })

  it('gives the events of the service only to a chat view that has a terminal', () => {
    expect(ipc).toContain('const hasTerminal = (viewId: string): boolean =>')
    expect(between('const hasTerminal', '\n')).toContain('liveManager?.has(viewId)')
    expect(between('createDictationService({', '\n  })')).toContain(
      'send: chatEventSender(hasTerminal, send)',
    )
  })

  it('stops the dictation of a chat when its terminal closes or exits', () => {
    expect(between('m.onClose(', 'm.onExit(')).toContain('dictation?.stop(viewId)')
    expect(between('m.onExit(', 'liveManager = m')).toContain('dictation?.stop(viewId)')
  })

  it('stops the helper in stopRegistry', () => {
    expect(between('export function stopRegistry', '\n}')).toContain('dictation?.stopAll()')
  })
})
