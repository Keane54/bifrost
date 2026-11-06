// Move the focus to the rows of an Overview.
import { OVERVIEW_ROWS_ATTR } from './focus-zone'

// Focus the rows of the Overview in the next animation frame, after the panel shows.
export function focusOverviewRows(panelId: string): void {
  requestAnimationFrame(() => {
    const selector = `[${OVERVIEW_ROWS_ATTR}="${CSS.escape(panelId)}"]`
    document.querySelector<HTMLElement>(selector)?.focus()
  })
}
