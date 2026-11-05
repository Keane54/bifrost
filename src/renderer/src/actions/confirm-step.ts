// The click rule of the confirm button of a confirmation dialog.
import type { ConfirmText } from './confirm'

// first: the button shows the confirm label. again: the button shows the confirmAgain label.
export type ConfirmState = 'first' | 'again'

// The result of a click on the confirm button in the state. label is the label after the click.
// With confirmAgain, the first click only changes the label. Only the second click confirms.
export function confirmStep(
  state: ConfirmState,
  text: ConfirmText,
): { label: string; resolve: boolean } {
  if (text.confirmAgain === undefined) return { label: text.confirm, resolve: true }
  return { label: text.confirmAgain, resolve: state === 'again' }
}

// The label of the confirm button in the state.
export function confirmLabel(state: ConfirmState, text: ConfirmText): string {
  return state === 'again' && text.confirmAgain !== undefined ? text.confirmAgain : text.confirm
}
