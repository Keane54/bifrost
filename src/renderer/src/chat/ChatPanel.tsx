// Shows one chat terminal in its panel. The terminal lives in ChatTerminals, outside React.
// A mount moves the terminal element in. An unmount moves it back to the parking element.
// While Take control runs, the panel hides the terminal and shows the Take control loader
// (spec 9.2). The terminal keeps its size and its focus, so the attach does not change.
// A short notice of dictation shows at the top of the panel (DictationNoticeLine).
import { useCallback, useLayoutEffect, useRef, useSyncExternalStore } from 'react'
import type { PrivacyPane } from '../../../shared/dictation-protocol'
import { cx } from '../lib/cx'
import { useChats } from './chat-terminals'
import DictationNoticeLine from './DictationNoticeLine'
import { noticeLine } from './dictation-notice'
import TakeControlLoader from './TakeControlLoader'
import { chatSessionId } from './views'

// A denied permission opens its pane of System Settings. The main process has the address.
function openSettings(pane: PrivacyPane): void {
  window.bifrost.dictation.openSettings(pane).catch((err: unknown) => {
    console.warn('Bifrost cannot open System Settings.', pane, err)
  })
}

export default function ChatPanel({ panelId }: { panelId: string }): React.JSX.Element {
  const chats = useChats()
  const sessionId = chatSessionId(panelId)
  // The terminal can start after the first render of the panel.
  const chat = useSyncExternalStore(chats.subscribe, () =>
    sessionId === null ? undefined : chats.get(sessionId),
  )
  const loading = useSyncExternalStore(
    chats.subscribe,
    () => sessionId !== null && chats.loading(sessionId),
  )
  const box = useRef<HTMLDivElement>(null)
  const subscribeDictation = useCallback(
    (listener: () => void) => chat?.onDictation(listener) ?? (() => {}),
    [chat],
  )
  // The view object changes only when the dictation state changes.
  const dictation = useSyncExternalStore(subscribeDictation, () =>
    chat === undefined ? null : chat.dictationView(),
  )
  const line = dictation === null ? null : noticeLine(dictation)

  useLayoutEffect(() => {
    const container = box.current
    if (!container || !chat) return
    container.append(chat.element)
    // A panel in a minimised frame has no size. Then it does not show the terminal.
    const measure = (): void => {
      const w = container.clientWidth
      const h = container.clientHeight
      chat.setPanel(w > 0 && h > 0 ? { h, w } : null)
    }
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(container)
    return () => {
      observer.disconnect()
      chat.setPanel(null)
      chat.park()
    }
  }, [chat])

  return (
    <>
      <div className={cx('absolute inset-0 overflow-hidden', loading && 'opacity-0')} ref={box} />
      {loading && sessionId !== null && <TakeControlLoader sessionId={sessionId} />}
      {line !== null && <DictationNoticeLine line={line} openSettings={openSettings} />}
    </>
  )
}
