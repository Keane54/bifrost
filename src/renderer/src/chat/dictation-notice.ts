// The texts of the dictation notice of a chat window (dictation design 7). This module reads no
// DOM. Each error code has a text of Bifrost. The message of the helper never shows, because it
// can be wrong (for example "Check your connection" when the reserve of models is full).
import type { DictationErrorCode, PrivacyPane } from '../../../shared/dictation-protocol'
import type { DictationNotice, DictationView } from './dictation-session'

export const VIM_MODE_TEXT = "Dictation doesn't work with Claude's vim mode yet."
export const LANGUAGE_TEXT = 'Your language has no on-device speech model, so Bifrost uses English.'
export const MODEL_READY_TEXT = 'The speech model is ready. Hold the key to dictate.'
export const OPEN_SETTINGS_TEXT = 'Open System Settings'

const ERROR_TEXTS: Readonly<Record<DictationErrorCode, string>> = {
  failed: 'Dictation stopped. Hold the key to try again.',
  'mic-asked':
    'macOS is asking if Bifrost can use the microphone. Answer it, then hold the key again.',
  'mic-denied': "Bifrost can't use the microphone. Allow it in System Settings.",
  'no-helper': "Dictation isn't available in this build of Bifrost.",
  'no-model':
    "Bifrost can't get an on-device speech model right now. Hold the key to try again later.",
  'speech-asked':
    'macOS is asking if Bifrost can use Speech Recognition. Answer it, then hold the key again.',
  'speech-denied':
    "Bifrost can't turn speech into text. Allow Speech Recognition in System Settings.",
}

// The pane of System Settings for each "no" of the user. The prompt of macOS shows only once, so
// System Settings is the only place to change the answer.
const ERROR_PANES: Readonly<Partial<Record<DictationErrorCode, PrivacyPane>>> = {
  'mic-denied': 'microphone',
  'speech-denied': 'speech-recognition',
}

export interface NoticeLine {
  text: string
  // The pane that the "Open System Settings" button opens, or null for no button.
  pane: PrivacyPane | null
}

// The text of the model download. The percent is a whole number from 0 to 100. It shows 100 only
// when the download is complete. The small addition stops a rounding error, for example
// 0.57 * 100 = 56.99999999999999.
export function downloadText(progress: number): string {
  const percent = Math.min(100, Math.max(0, Math.floor(progress * 100 + 1e-6)))
  return `Getting the speech model ready… ${percent}%`
}

// The text of a notice, or null for no notice.
export function noticeText(notice: DictationNotice | null): string | null {
  switch (notice?.kind) {
    case 'vim-mode':
      return VIM_MODE_TEXT
    case 'refused':
      return notice.text
    case 'error':
      return ERROR_TEXTS[notice.code]
    case 'language':
      return LANGUAGE_TEXT
    case 'model-ready':
      return MODEL_READY_TEXT
    default:
      return null
  }
}

// The line that the chat window shows, or null. During a hold in the model download, the line
// shows the progress in place of an older notice.
export function noticeLine(view: DictationView): NoticeLine | null {
  if (view.phase === 'downloading' && view.progress !== null) {
    return { pane: null, text: downloadText(view.progress) }
  }
  const { notice } = view
  const text = noticeText(notice)
  if (text === null) return null
  const pane = notice?.kind === 'error' ? (ERROR_PANES[notice.code] ?? null) : null
  return { pane, text }
}
