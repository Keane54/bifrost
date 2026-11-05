// The dialog history for the app (spec 8.9, 9.6). The window manager owns the state and saves it
// in ui-state.json with the layout.
import { createContext, useContext, useMemo } from 'react'
import type { History } from './history'

export interface HistoryValue {
  history: History
  update(fn: (h: History) => History): void
}

const HistoryContext = createContext<HistoryValue | null>(null)

export function HistoryProvider({
  history,
  update,
  children,
}: {
  history: History
  update(fn: (h: History) => History): void
  children: React.ReactNode
}): React.JSX.Element {
  const value = useMemo(() => ({ history, update }), [history, update])
  return <HistoryContext value={value}>{children}</HistoryContext>
}

export function useHistory(): HistoryValue {
  const value = useContext(HistoryContext)
  if (!value) throw new Error('useHistory needs a HistoryProvider.')
  return value
}
