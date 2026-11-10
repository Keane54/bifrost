import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { SessionRow } from '../../../shared/types'
import { INITIAL_REGISTRY, type RegistryState, withFirstRows, withUpdate } from './registry-state'

export interface RegistryValue {
  rows: SessionRow[]
  error: string | null
  // True after the first rows come: the answer of registry.rows() or an update.
  loaded: boolean
  selectedId: string | null
  select(id: string | null): void
}

const RegistryContext = createContext<RegistryValue | null>(null)

// One subscription to the session registry for the whole app. It also keeps the selection.
export function RegistryProvider({ children }: { children: React.ReactNode }): React.JSX.Element {
  const [state, setState] = useState<RegistryState>(INITIAL_REGISTRY)
  const [selectedId, setSelectedId] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    // One call at mount. Its answer also sets loaded, because the main process sends no update
    // when the rows do not change.
    window.bifrost.registry
      .rows()
      .then(r => active && setState(s => withFirstRows(s, r)))
      .catch(() => {})
    const unsubscribe = window.bifrost.registry.onUpdate((r, e) => {
      setState(s => withUpdate(s, r, e))
    })
    return () => {
      active = false
      unsubscribe()
    }
  }, [])

  const select = useCallback((id: string | null) => setSelectedId(id), [])

  const { error, loaded, rows } = state
  const value = useMemo(
    () => ({ error, loaded, rows, select, selectedId }),
    [error, loaded, rows, select, selectedId],
  )
  return <RegistryContext value={value}>{children}</RegistryContext>
}

export function useRegistry(): RegistryValue {
  const value = useContext(RegistryContext)
  if (!value) throw new Error('useRegistry needs a RegistryProvider.')
  return value
}
