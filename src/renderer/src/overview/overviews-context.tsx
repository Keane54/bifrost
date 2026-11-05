// The configs of all Overview panels. The window manager owns the state and saves it (D1).
import { createContext, type Dispatch, useCallback, useContext, useMemo } from 'react'
import { configOf, type OverviewAction, type OverviewConfig, type OverviewsAction } from './config'

export interface OverviewsValue {
  state: Record<string, OverviewConfig>
  dispatch(action: OverviewsAction): void
}

const OverviewsContext = createContext<OverviewsValue | null>(null)

export function OverviewsProvider({
  state,
  dispatch,
  children,
}: {
  state: Record<string, OverviewConfig>
  dispatch: Dispatch<OverviewsAction>
  children: React.ReactNode
}): React.JSX.Element {
  const value = useMemo(() => ({ dispatch, state }), [dispatch, state])
  return <OverviewsContext value={value}>{children}</OverviewsContext>
}

export function useOverviews(): OverviewsValue {
  const value = useContext(OverviewsContext)
  if (!value) throw new Error('useOverviews needs an OverviewsProvider.')
  return value
}

// The config of one Overview. A panel without a saved config gets the default config.
// update applies one action. edit applies a function to the current config.
export function useOverview(panelId: string): {
  config: OverviewConfig
  update(action: OverviewAction): void
  edit(change: (config: OverviewConfig) => OverviewConfig): void
} {
  const { state, dispatch } = useOverviews()
  const config = configOf(state, panelId)
  const update = useCallback(
    (action: OverviewAction) => dispatch({ action, panelId, type: 'update' }),
    [dispatch, panelId],
  )
  const edit = useCallback(
    (change: (config: OverviewConfig) => OverviewConfig) =>
      dispatch({ edit: change, panelId, type: 'edit' }),
    [dispatch, panelId],
  )
  return useMemo(() => ({ config, edit, update }), [config, edit, update])
}
