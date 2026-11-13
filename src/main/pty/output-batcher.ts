// Joins the output chunks of a chat terminal into one message for each frame.
// The first chunk after a quiet time goes at once, so a key echo does not wait.

export const FLUSH_MS = 8
export const QUIET_MS = 50
export const MAX_BATCH = 65_536

export interface OutputBatcher {
  push(viewId: string, chunk: string): void
  // Send the waiting text of the view now. Forget the view.
  flush(viewId: string): void
}

interface ViewState {
  text: string
  timer: ReturnType<typeof setTimeout> | null
  lastAt: number
}

export function createOutputBatcher(deps: {
  send(viewId: string, data: string): void
  now?: () => number
}): OutputBatcher {
  const now = deps.now ?? Date.now
  const views = new Map<string, ViewState>()

  // Send the waiting text of a view. The state stays, so the quiet time still counts.
  function drain(viewId: string, state: ViewState): void {
    if (state.timer) clearTimeout(state.timer)
    state.timer = null
    if (state.text === '') return
    const text = state.text
    state.text = ''
    deps.send(viewId, text)
  }

  return {
    flush(viewId) {
      const state = views.get(viewId)
      if (!state) return
      drain(viewId, state)
      views.delete(viewId)
    },
    push(viewId, chunk) {
      const t = now()
      let state = views.get(viewId)
      if (!state) {
        state = { lastAt: Number.NEGATIVE_INFINITY, text: '', timer: null }
        views.set(viewId, state)
      }
      const quiet = state.text === '' && t - state.lastAt >= QUIET_MS
      state.lastAt = t
      state.text += chunk
      if (quiet || state.text.length >= MAX_BATCH) {
        drain(viewId, state)
        return
      }
      if (!state.timer) {
        const s = state
        state.timer = setTimeout(() => drain(viewId, s), FLUSH_MS)
      }
    },
  }
}
