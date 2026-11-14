// Tests of the dictation notice of a chat window (dictation design 7, Review Focus 5): the text of
// each notice and of the model download, the "Open System Settings" button of a denied
// permission, and the end of a notice after a time or at the next good start. A fake API stands
// in for the main process. No test opens System Settings.
import { readFileSync } from 'node:fs'
import { createElement, isValidElement, type ReactElement, type ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import DictationNoticeLine from '../../../src/renderer/src/chat/DictationNoticeLine'
import {
  type NoticeLine,
  noticeLine,
  OPEN_SETTINGS_TEXT,
} from '../../../src/renderer/src/chat/dictation-notice'
import {
  createDictationSession,
  type DictationView,
  HELPER_NOTICE_MS,
  NOTICE_MS,
} from '../../../src/renderer/src/chat/dictation-session'
import type {
  DictationErrorCode,
  DictationViewEvent,
  PrivacyPane,
} from '../../../src/shared/dictation-protocol'

const VIEW = 'chat:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const READY: DictationViewEvent = { fallback: false, language: 'en-US', t: 'ready' }
const LEVEL: DictationViewEvent = { t: 'level', v: 0.3 }
const error = (code: DictationErrorCode, message = 'helper text'): DictationViewEvent => ({
  code,
  message,
  t: 'error',
})
const view = (partial: Partial<DictationView>): DictationView => ({
  notice: null,
  phase: 'off',
  progress: null,
  ...partial,
})
const errorView = (code: DictationErrorCode): DictationView =>
  view({ notice: { code, kind: 'error' } })

const MIC_DENIED = "Bifrost can't use the microphone. Allow it in System Settings."
const SPEECH_DENIED =
  "Bifrost can't turn speech into text. Allow Speech Recognition in System Settings."

function setup() {
  const api = {
    start: vi.fn(async (_viewId: string) => {}),
    stop: vi.fn(async (_viewId: string) => {}),
    vimMode: vi.fn(async () => false),
  }
  const fallback = vi.fn()
  const views: DictationView[] = []
  const session = createDictationSession({
    after(ms, fn) {
      const timer = setTimeout(fn, ms)
      return () => clearTimeout(timer)
    },
    api,
    changed: () => views.push(session.view()),
    fallback,
    lastSent: () => '',
    now: () => Date.now(),
    viewId: VIEW,
    write: () => {},
  })
  // The notice line that the chat window shows now.
  const line = (): NoticeLine | null => noticeLine(session.view())
  // A hold whose start the main process takes.
  const hold = async (): Promise<void> => {
    session.start()
    for (let i = 0; i < 10; i++) await Promise.resolve()
  }
  return { api, fallback, hold, line, session, views }
}

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('noticeLine', () => {
  it.each([
    ['mic-denied', MIC_DENIED, 'microphone'],
    ['speech-denied', SPEECH_DENIED, 'speech-recognition'],
    [
      'mic-asked',
      'macOS is asking if Bifrost can use the microphone. Answer it, then hold the key again.',
      null,
    ],
    [
      'speech-asked',
      'macOS is asking if Bifrost can use Speech Recognition. Answer it, then hold the key again.',
      null,
    ],
    [
      'no-model',
      "Bifrost can't get an on-device speech model right now. Hold the key to try again later.",
      null,
    ],
    ['failed', 'Dictation stopped. Hold the key to try again.', null],
    ['no-helper', "Dictation isn't available in this build of Bifrost.", null],
  ] as const)('gives the friendly text of the error %s', (code, text, pane) => {
    expect(noticeLine(errorView(code))).toEqual({ pane, text })
  })

  it('never shows the message of the helper', () => {
    for (const code of ['mic-denied', 'no-model', 'failed'] as const) {
      expect(noticeLine(errorView(code))?.text).not.toContain('connection')
    }
  })

  it('gives the texts of the other notices', () => {
    expect(noticeLine(view({ notice: { kind: 'vim-mode' } }))).toEqual({
      pane: null,
      text: "Dictation doesn't work with Claude's vim mode yet.",
    })
    expect(noticeLine(view({ notice: { kind: 'refused', text: 'No terminal.' } }))).toEqual({
      pane: null,
      text: 'No terminal.',
    })
    expect(noticeLine(view({ notice: { kind: 'language', language: 'en-US' } }))).toEqual({
      pane: null,
      text: 'Your language has no on-device speech model, so Bifrost uses English.',
    })
    expect(noticeLine(view({ notice: { kind: 'model-ready' } }))).toEqual({
      pane: null,
      text: 'The speech model is ready. Hold the key to dictate.',
    })
  })

  it('shows the progress of the model download, in whole percent', () => {
    const at = (progress: number) => noticeLine(view({ phase: 'downloading', progress }))
    expect(at(0)).toEqual({ pane: null, text: 'Getting the speech model ready… 0%' })
    expect(at(0.426)?.text).toBe('Getting the speech model ready… 42%')
    expect(at(0.999)?.text).toBe('Getting the speech model ready… 99%')
    expect(at(1)?.text).toBe('Getting the speech model ready… 100%')
  })

  it('shows the download in place of an older notice, and nothing with no notice', () => {
    const older = errorView('failed').notice
    expect(noticeLine(view({ notice: older, phase: 'downloading', progress: 0.5 }))?.text).toBe(
      'Getting the speech model ready… 50%',
    )
    expect(noticeLine(view({}))).toBeNull()
    expect(noticeLine(view({ phase: 'listening' }))).toBeNull()
    expect(noticeLine(view({ phase: 'downloading', progress: null }))).toBeNull()
  })
})

// The elements of a render with no DOM: the component is a plain function with no hooks.
function elements(node: ReactNode): ReactElement<Record<string, unknown>>[] {
  if (Array.isArray(node)) return node.flatMap(elements)
  if (!isValidElement<Record<string, unknown>>(node)) return []
  const { children } = node.props as { children?: ReactNode }
  return [node, ...elements(children)]
}

describe('DictationNoticeLine', () => {
  const render = (line: NoticeLine, openSettings = vi.fn()) =>
    renderToStaticMarkup(createElement(DictationNoticeLine, { line, openSettings }))

  it('shows the text as a status, with no button for a notice with no pane', () => {
    const html = render({ pane: null, text: 'Dictation stopped. Hold the key to try again.' })
    expect(html).toContain('role="status"')
    expect(html).toContain('Dictation stopped. Hold the key to try again.')
    expect(html).not.toContain('<button')
  })

  it('shows "Open System Settings" for a denied permission', () => {
    const html = render({ pane: 'microphone', text: MIC_DENIED })
    expect(OPEN_SETTINGS_TEXT).toBe('Open System Settings')
    expect(html).toContain('<button')
    expect(html).toContain('Open System Settings')
  })

  it.each([
    ['mic-denied', 'microphone'],
    ['speech-denied', 'speech-recognition'],
  ] as const)('%s opens the %s pane', (code, pane) => {
    const line = noticeLine(errorView(code))
    if (line === null) throw new Error('no line')
    const openSettings = vi.fn((_pane: PrivacyPane) => {})
    const tree = DictationNoticeLine({ line, openSettings })
    const button = elements(tree).find(el => el.type === 'button')
    if (button === undefined) throw new Error('no button')
    ;(button.props.onClick as () => void)()
    expect(openSettings).toHaveBeenCalledTimes(1)
    expect(openSettings).toHaveBeenCalledWith(pane)
  })

  it('is in the chat panel, which opens the pane through the main process', () => {
    const panel = readFileSync('src/renderer/src/chat/ChatPanel.tsx', 'utf8')
    expect(panel).toContain('<DictationNoticeLine')
    expect(panel).toContain('noticeLine(')
    expect(panel).toContain('window.bifrost.dictation.openSettings(pane)')
  })
})

describe('the notice of a chat window (Review Focus 5)', () => {
  it.each([
    ['mic-denied', MIC_DENIED, 'microphone'],
    ['speech-denied', SPEECH_DENIED, 'speech-recognition'],
  ] as const)(
    'a hold after a no to %s shows the notice with its pane',
    async (code, text, pane) => {
      const t = setup()
      await t.hold()
      // The main process gives the ready of the helper at once, then the helper gives the error.
      t.session.event(READY)
      t.session.event(error(code))
      expect(t.line()).toEqual({ pane, text })
      expect(t.session.view().phase).toBe('off')
      // The ready opened no microphone, so the chat never showed the green look (ruling D10).
      expect(t.views.some(v => v.phase === 'listening')).toBe(false)
      // The notice holds the button, so it stays. It does not go after a time (ruling D11).
      vi.advanceTimersByTime(HELPER_NOTICE_MS * 5)
      expect(t.line()).toEqual({ pane, text })
    },
  )

  it('goes after the next good start: the microphone gives its first level', async () => {
    const t = setup()
    await t.hold()
    t.session.event(error('mic-denied'))
    t.session.stop()
    await t.hold()
    // A ready alone is no good start: the main process gives it before the helper tries.
    t.session.event(READY)
    expect(t.line()?.text).toBe(MIC_DENIED)
    t.session.event(LEVEL)
    expect(t.line()).toBeNull()
  })

  it('goes at the first text of the next dictation too', async () => {
    const t = setup()
    await t.hold()
    t.session.event(error('failed'))
    await t.hold()
    t.session.event(READY)
    t.session.event({ final: '', t: 'text', volatile: 'Hi' })
    expect(t.line()).toBeNull()
  })

  it('stays when the next hold fails again, with the new text', async () => {
    const t = setup()
    await t.hold()
    t.session.event(error('mic-asked'))
    await t.hold()
    t.session.event(READY)
    t.session.event(error('mic-denied'))
    expect(t.line()).toEqual({ pane: 'microphone', text: MIC_DENIED })
  })

  it('gives the key back when the build has no speech helper, and shows its own text', async () => {
    const t = setup()
    await t.hold()
    // The main process gives the error at once, with no ready.
    t.session.event(error('no-helper', "Bifrost can't find its speech helper."))
    expect(t.fallback).toHaveBeenCalledTimes(1)
    expect(t.session.view().phase).toBe('off')
    expect(t.line()).toEqual({
      pane: null,
      text: "Dictation isn't available in this build of Bifrost.",
    })
    expect(t.line()?.text).not.toContain('try again')
  })

  it.each(['failed', 'no-model', 'mic-asked', 'speech-asked', 'no-helper'] as const)(
    'the notice of %s has no button and goes after 12 s (ruling D11)',
    async code => {
      const t = setup()
      await t.hold()
      t.session.event(READY)
      t.session.event(error(code))
      expect(t.line()?.pane).toBeNull()
      expect(HELPER_NOTICE_MS).toBe(12_000)
      vi.advanceTimersByTime(HELPER_NOTICE_MS - 1)
      expect(t.line()).not.toBeNull()
      vi.advanceTimersByTime(1)
      expect(t.line()).toBeNull()
    },
  )

  it('shows the language fallback at the first level, once for each window, for 12 s', async () => {
    const t = setup()
    await t.hold()
    t.session.event({ fallback: true, language: 'en-US', t: 'ready' })
    // The ready alone shows nothing.
    expect(t.line()).toBeNull()
    t.session.event(LEVEL)
    expect(t.line()?.text).toBe(
      'Your language has no on-device speech model, so Bifrost uses English.',
    )
    // More levels of the same dictation keep it.
    t.session.event(LEVEL)
    vi.advanceTimersByTime(HELPER_NOTICE_MS - 1)
    expect(t.line()).not.toBeNull()
    vi.advanceTimersByTime(1)
    expect(t.line()).toBeNull()
    t.session.stop()
    t.session.event({ final: '', t: 'end' })
    await t.hold()
    t.session.event({ fallback: true, language: 'en-US', t: 'ready' })
    t.session.event(LEVEL)
    expect(t.line()).toBeNull()
  })

  it('removes the language notice at the next good start', async () => {
    const t = setup()
    await t.hold()
    t.session.event({ fallback: true, language: 'en-US', t: 'ready' })
    t.session.event(LEVEL)
    t.session.stop()
    t.session.event({ final: '', t: 'end' })
    expect(t.line()).not.toBeNull()
    await t.hold()
    t.session.event({ fallback: true, language: 'en-US', t: 'ready' })
    t.session.event(LEVEL)
    expect(t.line()).toBeNull()
  })
})

describe('a hold during the model download (ruling D6)', () => {
  it('shows the progress, then the ready text, and never listens', async () => {
    const t = setup()
    await t.hold()
    t.session.event({ progress: 0, t: 'downloading' })
    expect(t.line()?.text).toBe('Getting the speech model ready… 0%')
    t.session.event({ progress: 0.37, t: 'downloading' })
    expect(t.line()?.text).toBe('Getting the speech model ready… 37%')
    t.session.event({ t: 'model-ready' })
    expect(t.line()).toEqual({
      pane: null,
      text: 'The speech model is ready. Hold the key to dictate.',
    })
    expect(t.session.view().phase).not.toBe('listening')
    // The microphone stays closed. The release types nothing, and the helper gets one stop.
    t.session.stop()
    expect(t.api.stop).toHaveBeenCalledTimes(1)
    t.session.event({ final: '', t: 'end' })
    expect(t.session.view().phase).toBe('off')
    expect(t.fallback).not.toHaveBeenCalled()
    vi.advanceTimersByTime(NOTICE_MS)
    expect(t.line()).toBeNull()
  })

  it('removes an older notice at the first progress', async () => {
    const t = setup()
    await t.hold()
    t.session.event(error('no-model'))
    await t.hold()
    t.session.event({ progress: 0.1, t: 'downloading' })
    t.session.stop()
    t.session.event({ final: '', t: 'end' })
    expect(t.line()).toBeNull()
  })

  it('listens when the helper opens a session after the ready text (ruling D6a)', async () => {
    const t = setup()
    await t.hold()
    t.session.event({ progress: 0.9, t: 'downloading' })
    t.session.event({ t: 'model-ready' })
    t.session.event(READY)
    // The ready alone does not listen. The ready text still shows.
    expect(t.session.view().phase).toBe('downloading')
    expect(t.line()?.text).toBe('The speech model is ready. Hold the key to dictate.')
    t.session.event(LEVEL)
    expect(t.session.view().phase).toBe('listening')
    expect(t.line()).toBeNull()
  })
})
