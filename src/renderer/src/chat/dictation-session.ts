// The dictation of one chat window (dictation design). It joins the hold key, the speech helper in
// the main process and the typer. This module reads no DOM.
// - A hold reads the vim mode of Claude first. In vim mode, a dictated letter can run as a
//   command, so dictation stays off and the key is a normal key (ruling D7).
// - The final text of an end is typed only when the end answers the stop of a key release. After
//   an early stop, that end and all later events of that dictation do nothing. An end that
//   answers no stop of this window is an early stop too, for example at the 2-minute limit.
// - An early stop or an error cancels the typer. The typed text stays.
// - The ready of the helper opens no microphone: the main process gives it before the helper
//   tries. The first level or text is the good start: the window listens from then (ruling D10).
//   A refused start, or an error or a release before the good start, takes the path before
//   ready: the key acts as a normal key.
// - A start during a model download shows the download, and the microphone stays closed. A new
//   hold after ready opens it (ruling D6). At model-ready, the notice tells the user to hold the
//   key again.
// - The good start removes the notice of an earlier dictation. A notice with the System Settings
//   button stays until then. Each other notice of the helper also goes after HELPER_NOTICE_MS
//   (ruling D11). The first downloading event of a hold also removes the notice. The language
//   notice shows at the good start, once for each window.
// - After a release, the keys of the user wait while the final text types, in their order, and
//   then go to the PTY (ruling D9). A key waits only for the final texts of the dictations that
//   began before it. A final text waits only for the keys from before its dictation began. When
//   the end does not come KEY_WAIT_MS after the release, the end does nothing and the keys go.
//   After the end comes, its final text always types first.
// - Other input of the user during a hold stops only the hold. A final text of an older dictation
//   still types, and the keys wait for it. Escape, Ctrl+C, a blocking choice and the end of the
//   PTY stop each typer at once, and the keys that wait go away (ruling D12).
// - One dictation at a time in a window. A new hold before the end of the last dictation waits
//   for that end, and for the first write of its final text. A new typer writes only when the
//   last typer is done and its gap is over.
import type { BifrostApi } from '../../../shared/api'
import type { DictationErrorCode, DictationViewEvent } from '../../../shared/dictation-protocol'
import { friendlyError } from '../actions/errors'
import { errorMessage } from '../lib/error-message'
import { createTyper, DEL, gapAfter, type Typer } from './dictation-typing'

// The longest wait for the end after a stop. The main process gives the end in 2 s or less.
export const CLOSE_WAIT_MS = 3_000
// The time that the vim mode, refusal and model-ready notices show.
export const NOTICE_MS = 6_000
// The time that a notice of the helper with no button shows (ruling D11).
export const HELPER_NOTICE_MS = 12_000
// The longest wait of the keys for the end, from the release (ruling D9).
export const KEY_WAIT_MS = 2_000
// The keys check the typer at this interval while they wait.
const KEY_CHECK_MS = 10

export type DictationPhase = 'off' | 'starting' | 'downloading' | 'listening' | 'stopping'

export type DictationNotice =
  | { kind: 'vim-mode' }
  // The main process refused the start. The text is the friendly text of the refusal.
  | { kind: 'refused'; text: string }
  // The chat shows a text of Bifrost for the code, never the message of the helper.
  | { kind: 'error'; code: DictationErrorCode }
  // macOS has no speech model for the system language, so the helper uses English.
  | { kind: 'language'; language: string }
  // The speech model download ended during the hold. A new hold opens the microphone.
  | { kind: 'model-ready' }

export interface DictationView {
  phase: DictationPhase
  // The progress of the speech model download, 0 to 1, while the phase is downloading.
  progress: number | null
  notice: DictationNotice | null
}

export interface DictationSessionDeps {
  viewId: string
  api: Pick<BifrostApi['dictation'], 'start' | 'stop' | 'vimMode'>
  // Send one string to the PTY of the chat window.
  write(data: string): void
  // The end of the text that the user typed (typedTail).
  lastSent(): string
  now(): number
  // Call fn one time after ms milliseconds. The result stops the timer.
  after(ms: number, fn: () => void): () => void
  // The held key types its text, as a normal key.
  fallback(): void
  // The view changed.
  changed(): void
}

export interface DictationSession {
  // The key is held.
  start(): void
  // The key went up after the start.
  stop(): void
  // Another key, a blur or a close during the hold.
  cancel(): void
  // A key or other input of the user goes to the PTY. A hold stops early. A final text that
  // types, or waits for its end, goes on, and the keys wait for it. With no final text, each
  // typer stops at once, and the keys that wait go to the PTY.
  interrupt(): void
  // Claude shows a blocking choice, the PTY ends, or the user pressed Escape or Ctrl+C. Dictation
  // stops, and each typer stops at once. The keys that wait go away, because they could answer the
  // choice or submit the prompt (ruling D12).
  block(): void
  // Input of the user for the PTY: keys, the text of the hold key and the replies of xterm.js.
  // It waits while the final text of a released dictation types (ruling D9).
  input(data: string): void
  // True when a key must not stop the typer: the final text of a released dictation still types,
  // and no hold runs.
  waits(): boolean
  // An event of the main process for this chat view.
  event(event: DictationViewEvent): void
  // False while a hold waits for its start: the vim mode read, or the first level or text. Then
  // the chat shows nothing yet, so the held key can still type its text (rulings D8, D10).
  heard(): boolean
  view(): DictationView
  dispose(): void
}

// idle: no dictation. checking: the vim mode read runs. stopping: the key went up, and the
// session waits for the end. closing: an early stop waits for the end, and the end does nothing.
type Phase = 'idle' | 'checking' | 'starting' | 'downloading' | 'listening' | 'stopping' | 'closing'

const VIEW_PHASES: Readonly<Record<Phase, DictationPhase>> = {
  checking: 'off',
  closing: 'off',
  downloading: 'downloading',
  idle: 'off',
  listening: 'listening',
  starting: 'starting',
  stopping: 'stopping',
}

function countDeletes(data: string): number {
  let deletes = 0
  while (data[deletes] === DEL) deletes++
  return deletes
}

export function createDictationSession(deps: DictationSessionDeps): DictationSession {
  let phase: Phase = 'idle'
  // The number of the current dictation. A late answer for an older one does nothing.
  let turn = 0
  // True when a hold waits for the end of the last dictation.
  let waitingStart = false
  // True after the good start: the text events and the end type text.
  let heard = false
  let progress: number | null = null
  let notice: DictationNotice | null = null
  // True after the language notice showed in this window.
  let languageShown = false
  // The language of a ready with fallback true in the current dictation, or null.
  let fallbackLanguage: string | null = null
  let view: DictationView = { notice, phase: 'off', progress }
  let disposed = false
  // The typer of the current or the last dictation, and the typer before it.
  let typer: Typer | null = null
  let previous: Typer | null = null
  // The text that waits for the first write of a new typer.
  let pending: { final: string; volatile: string; end: boolean } | null = null
  // The time when the gap after the last write of a typer ends.
  let quietAt = 0
  let stopFlush: (() => void) | null = null
  let stopClose: (() => void) | null = null
  let stopNotice: (() => void) | null = null
  // The number of dictations that began. The current dictation has this number.
  let begun = 0
  // The time of the key release of the current dictation.
  let releasedAt = 0
  // The typer that types the final text of a released dictation, and the number of its dictation.
  let finalTyper: Typer | null = null
  let finalOf = 0
  // The input of the user that waits for a final text. Each part has the number of the last
  // dictation that began before it.
  let keys: { data: string; after: number }[] = []
  let stopKeys: (() => void) | null = null

  function publish(): void {
    if (disposed) return
    const shown = VIEW_PHASES[phase]
    if (view.notice === notice && view.phase === shown && view.progress === progress) return
    view = { notice, phase: shown, progress }
    deps.changed()
  }

  // True while the key is held and the dictation did not stop.
  function holding(): boolean {
    return phase === 'starting' || phase === 'downloading' || phase === 'listening'
  }

  // True while the final text of dictation number n or of an older one types, or waits to type.
  function finishing(n: number): boolean {
    if (begun <= n && phase === 'stopping' && heard) return true
    if (begun <= n && pending?.end) return true
    if (finalTyper === null || finalOf > n) return false
    if (finalTyper.busy() || deps.now() < quietAt) return true
    finalTyper = null
    return false
  }

  function waits(): boolean {
    return phase !== 'checking' && !holding() && finishing(begun)
  }

  function armKeys(): void {
    if (stopKeys !== null) return
    stopKeys = deps.after(KEY_CHECK_MS, () => {
      stopKeys = null
      releaseKeys()
    })
  }

  // Send each key, in order, when the final texts before it are typed. When the end does not
  // come KEY_WAIT_MS after the release, the end does nothing. The live text stays.
  function releaseKeys(): void {
    if (phase === 'stopping' && heard && deps.now() - releasedAt >= KEY_WAIT_MS) {
      phase = 'closing'
      dropTyping()
      publish()
    }
    while (keys.length > 0 && !finishing(keys[0].after)) {
      const next = keys.shift()
      if (next) deps.write(next.data)
    }
    if (keys.length > 0) armKeys()
  }

  function sendKeys(): void {
    stopKeys?.()
    stopKeys = null
    const out = keys
    keys = []
    for (const part of out) deps.write(part.data)
  }

  function dropKeys(): void {
    stopKeys?.()
    stopKeys = null
    keys = []
  }

  // Show a notice. With ms, the notice goes after that time. With null, it stays.
  function setNotice(next: DictationNotice | null, ms: number | null = null): void {
    stopNotice?.()
    stopNotice = null
    notice = next
    if (next === null || ms === null) return
    stopNotice = deps.after(ms, () => {
      stopNotice = null
      if (notice !== next) return
      notice = null
      publish()
    })
  }

  function write(data: string): void {
    deps.write(data)
    quietAt = deps.now() + gapAfter(countDeletes(data))
  }

  // Give the text to the typer of this dictation. Its first write waits for the last typer.
  function type(final: string, volatile: string, end: boolean): void {
    if (typer !== null) {
      if (end) {
        typer.finish(final)
        finalTyper = typer
        finalOf = begun
      } else {
        typer.update(final, volatile)
      }
      return
    }
    pending = { end, final, volatile }
    flush()
  }

  function flush(): void {
    stopFlush?.()
    stopFlush = null
    if (pending === null) return
    const wait = quietAt - deps.now()
    // The keys from before this dictation began go first.
    const olderKeys = keys.length > 0 && keys[0].after < begun
    if (previous?.busy() || wait > 0 || olderKeys) {
      stopFlush = deps.after(Math.max(wait, 1), flush)
      return
    }
    const next = pending
    pending = null
    previous = null
    if (finalTyper !== null && !finalTyper.busy()) finalTyper = null
    typer = createTyper({ after: deps.after, lastSent: deps.lastSent, write })
    if (next.end) {
      typer.finish(next.final)
      finalTyper = typer
      finalOf = begun
    } else {
      typer.update(next.final, next.volatile)
    }
    // A hold that waits for this final text starts now.
    if (phase === 'idle') startWaiting()
  }

  // Stop the writes of this dictation that did not start. The typed text stays.
  function dropTyping(): void {
    typer?.cancel()
    pending = null
    stopFlush?.()
    stopFlush = null
  }

  function sendStop(): void {
    deps.api.stop(deps.viewId).catch((err: unknown) => {
      console.warn('Bifrost cannot stop the dictation of a chat window.', deps.viewId, err)
    })
  }

  function armClose(): void {
    stopClose?.()
    stopClose = deps.after(CLOSE_WAIT_MS, () => {
      stopClose = null
      // No end came, for example because the PTY of the view closed. The typed text stays, and
      // the typer stops, so a key cannot go between its writes.
      if (phase === 'stopping') dropTyping()
      if (phase === 'stopping' || phase === 'closing') settle()
    })
  }

  // The dictation ended. A hold that waits for it starts now.
  function settle(): void {
    stopClose?.()
    stopClose = null
    phase = 'idle'
    progress = null
    publish()
    startWaiting()
  }

  // Start a hold that waits. A final text that waits for an older typer goes first, because a
  // start makes a new typer.
  function startWaiting(): void {
    if (!waitingStart || pending !== null) return
    waitingStart = false
    check()
  }

  function check(): void {
    const id = ++turn
    phase = 'checking'
    deps.api
      .vimMode()
      .catch(() => false)
      .then(vim => {
        if (disposed || id !== turn || phase !== 'checking') return
        if (!vim) {
          begin(id)
          return
        }
        phase = 'idle'
        setNotice({ kind: 'vim-mode' }, NOTICE_MS)
        publish()
        deps.fallback()
      })
  }

  function begin(id: number): void {
    begun += 1
    phase = 'starting'
    heard = false
    progress = null
    fallbackLanguage = null
    // The typer of the last dictation can still type. The new typer waits for it.
    if (typer !== null) previous = typer
    typer = null
    publish()
    deps.api.start(deps.viewId).catch((err: unknown) => {
      if (disposed || id !== turn || phase === 'idle' || phase === 'checking') return
      // The main process refused the start, so no event of it comes.
      setNotice({ kind: 'refused', text: friendlyError(errorMessage(err)) }, NOTICE_MS)
      if (!holding()) {
        settle()
        return
      }
      phase = 'idle'
      publish()
      deps.fallback()
    })
  }

  function cancel(): void {
    waitingStart = false
    if (phase === 'checking') {
      turn += 1
      phase = 'idle'
      publish()
    } else if (holding()) {
      phase = 'closing'
      dropTyping()
      sendStop()
      armClose()
      publish()
    }
  }

  // Stop a hold. A final text that types, or waits for its end, goes on (ruling D9).
  function interrupt(): void {
    cancel()
    if (!finishing(begun)) stopAll()
  }

  // Stop the dictation and each typer at once. The keys that wait go first, in their order.
  function stopAll(): void {
    cancel()
    if (phase === 'stopping') {
      // The end of the release does nothing now. The close timer runs already.
      phase = 'closing'
      publish()
    }
    dropTyping()
    previous?.cancel()
    previous = null
    finalTyper = null
    // The keys that waited go first, in their order.
    sendKeys()
  }

  // The good start: the first level or text shows that the microphone is open. The notice of an
  // earlier dictation goes.
  function hear(): void {
    phase = 'listening'
    heard = true
    progress = null
    setNotice(null)
    if (fallbackLanguage !== null && !languageShown) {
      languageShown = true
      setNotice({ kind: 'language', language: fallbackLanguage }, HELPER_NOTICE_MS)
    }
    publish()
  }

  function onEvent(event: DictationViewEvent): void {
    if (phase === 'closing') {
      if (event.t === 'end' || event.t === 'error') settle()
      return
    }
    switch (event.t) {
      case 'ready':
        // The microphone is not open yet. The first level or text opens the window (ruling D10).
        if (phase !== 'starting' && phase !== 'downloading') return
        fallbackLanguage = event.fallback ? event.language : null
        publish()
        return
      case 'downloading':
        if (phase !== 'starting' && phase !== 'downloading') return
        // The helper runs, so the notice of an earlier failure goes.
        if (phase === 'starting') setNotice(null)
        phase = 'downloading'
        progress = event.progress
        publish()
        return
      case 'model-ready':
        // The microphone stays closed. The key is still held (ruling D6).
        if (phase !== 'downloading') return
        progress = null
        setNotice({ kind: 'model-ready' }, NOTICE_MS)
        publish()
        return
      case 'level':
        if (phase === 'starting' || phase === 'downloading') hear()
        return
      case 'text':
        // A text can come with no level before it (ruling D6a).
        if (phase === 'starting' || phase === 'downloading') hear()
        if (phase === 'listening') type(event.final, event.volatile, false)
        return
      case 'end':
        if (phase === 'stopping') {
          if (heard) type(event.final, '', true)
        } else {
          // An end with no stop of this window. A stop closes the microphone, in case the end
          // was a late end of an older dictation.
          dropTyping()
          sendStop()
        }
        settle()
        return
      case 'error': {
        dropTyping()
        // A "no" of the user keeps its System Settings button until the next good start.
        const denied = event.code === 'mic-denied' || event.code === 'speech-denied'
        setNotice({ code: event.code, kind: 'error' }, denied ? null : HELPER_NOTICE_MS)
        if (!holding()) {
          settle()
          return
        }
        phase = 'idle'
        progress = null
        publish()
        // An error in place of the start gives the key back.
        if (!heard) deps.fallback()
        return
      }
    }
  }

  return {
    block() {
      if (disposed) return
      dropKeys()
      stopAll()
    },
    cancel() {
      if (!disposed) cancel()
    },
    dispose() {
      if (disposed) return
      disposed = true
      dropKeys()
      waitingStart = false
      turn += 1
      if (holding()) sendStop()
      phase = 'idle'
      typer?.cancel()
      previous?.cancel()
      pending = null
      stopFlush?.()
      stopClose?.()
      stopNotice?.()
    },
    event(event) {
      if (disposed || phase === 'idle' || phase === 'checking') return
      onEvent(event)
    },
    heard: () => phase !== 'checking' && phase !== 'starting',
    input(data) {
      if (disposed) return
      if (keys.length === 0 && !waits()) {
        deps.write(data)
        return
      }
      keys.push({ after: begun, data })
      armKeys()
    },
    interrupt() {
      if (!disposed) interrupt()
    },
    start() {
      if (disposed) return
      // A final text that waits for an older typer goes first.
      const textWaits = phase === 'idle' && pending !== null
      if (phase === 'stopping' || phase === 'closing' || textWaits) waitingStart = true
      else if (phase === 'idle') check()
    },
    stop() {
      if (disposed) return
      if (phase === 'stopping' || phase === 'closing' || phase === 'idle') {
        waitingStart = false
      } else if (phase === 'checking') {
        turn += 1
        phase = 'idle'
        publish()
      } else if (holding()) {
        phase = 'stopping'
        releasedAt = deps.now()
        sendStop()
        armClose()
        publish()
      }
    },
    view: () => view,
    waits: () => !disposed && waits(),
  }
}
