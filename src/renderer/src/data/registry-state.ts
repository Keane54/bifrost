// The state of the session registry in the renderer, as pure steps.
import type { SessionRow } from '../../../shared/types'

export interface RegistryState {
  rows: SessionRow[]
  error: string | null
  // True after the first rows come: the answer of registry.rows() or an update.
  loaded: boolean
  // True after the first update from the main process.
  updated: boolean
}

export const INITIAL_REGISTRY: RegistryState = {
  error: null,
  loaded: false,
  rows: [],
  updated: false,
}

// The answer of the one registry.rows() call at mount. An empty list also counts.
// The main process sends an update only when the rows change. So a page that loads after the
// last change gets its rows only from this answer. An update that came first is newer, so the
// state keeps its rows. An update also sets loaded.
export function withFirstRows(state: RegistryState, rows: SessionRow[]): RegistryState {
  if (state.updated) return state
  return { ...state, loaded: true, rows }
}

// An update from the main process.
export function withUpdate(
  _state: RegistryState,
  rows: SessionRow[],
  error: string | null,
): RegistryState {
  return { error, loaded: true, rows, updated: true }
}
