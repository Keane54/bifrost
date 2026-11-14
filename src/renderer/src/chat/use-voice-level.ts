// The smoothed voice level of one chat window, and the state "this window dictates".
import { useCallback, useEffect, useState, useSyncExternalStore } from 'react'
import { useChats } from './chat-terminals'
import { dictationShows, smoothLevel } from './dictation-look'
import { chatSessionId } from './views'

// True while the microphone of the chat window is open. The view ID is a chat panel ID.
export function useDictating(viewId: string): boolean {
  const chats = useChats()
  const sessionId = chatSessionId(viewId)
  const chat = useSyncExternalStore(chats.subscribe, () =>
    sessionId === null ? undefined : chats.get(sessionId),
  )
  const subscribe = useCallback(
    (listener: () => void) => chat?.onDictation(listener) ?? (() => {}),
    [chat],
  )
  return useSyncExternalStore(subscribe, () =>
    chat === undefined ? false : dictationShows(chat.dictationView().phase),
  )
}

// The level of the voice, 0 to 1, smoothed with requestAnimationFrame. It runs only while the
// window dictates, and it gives 0 at other times.
export function useVoiceLevel(viewId: string): number {
  const chats = useChats()
  const sessionId = chatSessionId(viewId)
  const dictating = useDictating(viewId)
  const [level, setLevel] = useState(0)

  useEffect(() => {
    if (!dictating || sessionId === null) return
    let current = 0
    let last = performance.now()
    let frame = 0
    const tick = (now: number): void => {
      const target = chats.get(sessionId)?.dictationLevel() ?? 0
      current = smoothLevel(current, target, (now - last) / 1000)
      last = now
      setLevel(current)
      frame = requestAnimationFrame(tick)
    }
    frame = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(frame)
  }, [chats, dictating, sessionId])

  return dictating ? level : 0
}
