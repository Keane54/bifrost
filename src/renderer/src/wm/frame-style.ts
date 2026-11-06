// The blur behind a frame (spec 8.10). This module is pure.
import { panelKind } from './state'

// A chat window has a very light blur of 8 px, as in EVE. So it is clear when it is over another
// panel. The other panels keep the blur of 12 px.
export function frameBlur(activePanelId: string): string {
  return panelKind(activePanelId) === 'chat' ? 'backdrop-blur-sm' : 'backdrop-blur-md'
}
