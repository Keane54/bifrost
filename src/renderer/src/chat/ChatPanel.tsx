// Shows one chat terminal in its panel. The terminal lives in ChatTerminals, outside React.
// A mount moves the terminal element in. An unmount moves it back to the parking element.
// While Take control runs, the panel hides the terminal and shows the Take control loader
// (spec 9.2). The terminal keeps its size and its focus, so the attach does not change.
import { useLayoutEffect, useRef, useSyncExternalStore } from 'react'
import { cx } from '../lib/cx'
import { useChats } from './chat-terminals'
import TakeControlLoader from './TakeControlLoader'
import { chatSessionId } from './views'

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
    </>
  )
}
