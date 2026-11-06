// The rows that a search shows in Settings > General (spec 12). Outside a search the value is
// null, and each row shows.
import { createContext, useContext } from 'react'

export const RowFilterContext = createContext<ReadonlySet<string> | null>(null)

// True when the row with this label shows. A row with no label always shows.
export function useRowShown(label: string | null): boolean {
  const only = useContext(RowFilterContext)
  return only === null || label === null || only.has(label)
}
