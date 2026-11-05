import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { SessionRow } from '../../../shared/types'

export interface RegistryValue {
  rows: SessionRow[]
  error: string | null
  selectedId: string | null
  select(id: string | null): void
}

const RegistryContext = createContext<RegistryValue | null>(null)

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

// One subscription to the session registry for the whole app. It also keeps the selection.
export function RegistryProvider({ children }: { children: React.ReactNode }): React.JSX.Element {
  const [rows, setRows] = useState<SessionRow[]>([])
  const [error, setError] = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    let updated = false
    // One call at mount. An update that arrived first is newer, so keep it.
    window.bifrost.registry
      .rows()
      .then(r => active && !updated && setRows(r))
      .catch(() => {})
    const unsubscribe = window.bifrost.registry.onUpdate((r, e) => {
      updated = true
      setRows(r)
      setError(e)
    })
    return () => {
      active = false
      unsubscribe()
    }
  }, [])

  // A selection also stops the flash of the box of the session (spec 7, rule 2).
  const select = useCallback((id: string | null) => {
    setSelectedId(id)
    if (id === null) return
    window.bifrost.registry.acknowledge(id).catch(err => setError(message(err)))
  }, [])

  const value = useMemo(
    () => ({ error, rows, select, selectedId }),
    [error, rows, select, selectedId],
  )
  return <RegistryContext value={value}>{children}</RegistryContext>
}

export function useRegistry(): RegistryValue {
  const value = useContext(RegistryContext)
  if (!value) throw new Error('useRegistry needs a RegistryProvider.')
  return value
}
