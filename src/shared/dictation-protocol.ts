// The protocol of the speech helper (native/dictation). Bifrost writes one command on each line to
// the stdin of the helper. The helper writes one JSON event on each line to its stdout.
//
// Commands:
// - start: open the microphone and start a session. The helper gives level and text events. A
//   start during a session does nothing.
// - stop: close the microphone and give one end event with the final text. A stop with no
//   session also gives an end event, with an empty text.
// - quit: close the microphone and exit, with no end event. EOF on stdin does the same.
// The helper does the commands one at a time, in the order that they come. So a stop that comes
// during a start runs after the microphone is open.
//
// Events:
// - downloading: the speech model of the language is not on the Mac, so the helper downloads it
//   from Apple one time. The first event has the progress 0. Then at most two come each second,
//   until ready. During the download, a start opens no microphone and gives the progress again.
// - ready: the speech model is loaded, once after the helper starts (or after the download).
//   fallback is true when macOS has no speech model for the system language, so the helper uses
//   English.
// - level: the voice level, 0 to 1, about 30 times a second during a session.
// - text: the text so far. final does not change any more. volatile can still change. On macOS 13
//   to 15, final stays empty until the end, because all the text can change.
// - end: the final text of the session, after a stop. When the final text does not come in about
//   1.5 s, end has the text so far.
// - error: in place of ready when the helper cannot start (no-model or failed). In place of a
//   session when start cannot open the microphone or the recognizer. During a session (failed)
//   when the recognition stops. The helper then closes the microphone and ends the session, so a
//   later stop gives an empty end. After an error in place of ready, each start gives the same
//   error again.
//   mic-asked and speech-asked: macOS has no answer yet, so start asks macOS to show its prompt
//   and gives the error at once. It never waits for the answer. The user answers the prompt.
//   mic-denied and speech-denied: the user said no. The user can change it in System Settings.
import { isPlainObject } from './plain-object'

// A longer line is a bad line. The text of a 2-minute dictation is far shorter.
export const MAX_HELPER_LINE = 64_000

export type HelperCommand = 'start' | 'stop' | 'quit'

export type HelperErrorCode =
  | 'mic-asked'
  | 'mic-denied'
  | 'speech-asked'
  | 'speech-denied'
  | 'no-model'
  | 'failed'

export type HelperEvent =
  | { t: 'downloading'; progress: number }
  | { t: 'ready'; language: string; fallback: boolean }
  | { t: 'level'; v: number }
  | { t: 'text'; final: string; volatile: string }
  | { t: 'end'; final: string }
  | { t: 'error'; code: HelperErrorCode; message: string }

// The error codes that a chat view can get: the codes of the helper, and no-helper. The helper
// never prints no-helper. The main process gives it when this build of Bifrost has no helper, for
// example a dev run with no helper build. A new hold cannot help then.
export type DictationErrorCode = HelperErrorCode | 'no-helper'

// The events that the main process gives to a chat view: the events of the helper, model-ready
// and the error no-helper. The helper never prints model-ready. A start that got downloading
// events gets model-ready in place of ready when the download ends, because that start opened no
// microphone. A new hold opens it (ruling D6). When the helper opens a session for that start
// after all, ready comes later, before the first level or text (ruling D6a).
export type DictationViewEvent =
  | HelperEvent
  | { t: 'model-ready' }
  | { t: 'error'; code: 'no-helper'; message: string }

// The panes of System Settings that a notice of dictation can open. The main process has the
// address of each pane. The page sends only the name.
export type PrivacyPane = 'microphone' | 'speech-recognition'

const ERROR_CODES: readonly HelperErrorCode[] = [
  'mic-asked',
  'mic-denied',
  'speech-asked',
  'speech-denied',
  'no-model',
  'failed',
]
// A BCP 47 language ID, for example en-US, is much shorter.
const MAX_LANGUAGE = 64

const isErrorCode = (value: unknown): value is HelperErrorCode =>
  ERROR_CODES.some(code => code === value)

const isFraction = (value: unknown): value is number =>
  typeof value === 'number' && value >= 0 && value <= 1

// True when the object has exactly these keys.
function hasKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const own = Object.keys(value)
  return own.length === keys.length && keys.every(key => Object.hasOwn(value, key))
}

// Read one line of the helper. A line that is not exactly one known event gives null.
export function parseHelperLine(line: string): HelperEvent | null {
  if (line.length > MAX_HELPER_LINE) return null
  let data: unknown
  try {
    data = JSON.parse(line)
  } catch {
    return null
  }
  if (!isPlainObject(data)) return null
  switch (data.t) {
    case 'downloading': {
      const { progress } = data
      if (!hasKeys(data, ['t', 'progress']) || !isFraction(progress)) return null
      return { progress, t: 'downloading' }
    }
    case 'ready': {
      const { fallback, language } = data
      if (!hasKeys(data, ['t', 'language', 'fallback'])) return null
      if (typeof language !== 'string' || language === '' || language.length > MAX_LANGUAGE) {
        return null
      }
      if (typeof fallback !== 'boolean') return null
      return { fallback, language, t: 'ready' }
    }
    case 'level': {
      const { v } = data
      if (!hasKeys(data, ['t', 'v']) || !isFraction(v)) return null
      return { t: 'level', v }
    }
    case 'text': {
      const { final, volatile } = data
      if (!hasKeys(data, ['t', 'final', 'volatile'])) return null
      if (typeof final !== 'string' || typeof volatile !== 'string') return null
      return { final, t: 'text', volatile }
    }
    case 'end': {
      const { final } = data
      if (!hasKeys(data, ['t', 'final']) || typeof final !== 'string') return null
      return { final, t: 'end' }
    }
    case 'error': {
      const { code, message } = data
      if (!hasKeys(data, ['t', 'code', 'message'])) return null
      if (!isErrorCode(code) || typeof message !== 'string') return null
      return { code, message, t: 'error' }
    }
    default:
      return null
  }
}
