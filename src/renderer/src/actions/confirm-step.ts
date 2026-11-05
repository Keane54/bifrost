// The click rule of the confirm button of a confirmation dialog.
import type { ConfirmText } from './confirm'

// first: the button shows the confirm label. again: the button shows the confirmAgain label.
export type ConfirmState = 'first' | 'again'

// The second click counts only this long after the label change. A held key or a fast second
// click cannot pass both steps.
export const CONFIRM_AGAIN_WAIT_MS = 500

// The result of a click on the confirm button in the state. label is the label after the click.
// With confirmAgain, the first click only changes the label. Only the second click confirms,
// and only CONFIRM_AGAIN_WAIT_MS or more after the label change. sinceAgainMs is that time.
export function confirmStep(
  state: ConfirmState,
  text: ConfirmText,
  sinceAgainMs: number = Number.POSITIVE_INFINITY,
): { label: string; resolve: boolean } {
  if (text.confirmAgain === undefined) return { label: text.confirm, resolve: true }
  return {
    label: text.confirmAgain,
    resolve: state === 'again' && sinceAgainMs >= CONFIRM_AGAIN_WAIT_MS,
  }
}

// The label of the confirm button in the state.
export function confirmLabel(state: ConfirmState, text: ConfirmText): string {
  return state === 'again' && text.confirmAgain !== undefined ? text.confirmAgain : text.confirm
}
