// Plain popovers until M3 brings Base UI.
import { type RefObject, useEffect } from 'react'

// Close a popover on Esc, and on a pointer down outside the popover and its button.
// A pointer down on the button does not close the popover, so a click on the button can close it.
// Esc puts the focus back on the button.
export function useDismiss(
  popover: RefObject<HTMLElement | null>,
  button: RefObject<HTMLElement | null>,
  onClose: () => void,
): void {
  useEffect(() => {
    const onPointerDown = (e: PointerEvent): void => {
      const node = e.target instanceof Node ? e.target : null
      if (node && (popover.current?.contains(node) || button.current?.contains(node))) return
      onClose()
    }
    const onKeyDown = (e: KeyboardEvent): void => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      onClose()
      button.current?.focus()
    }
    document.addEventListener('pointerdown', onPointerDown, true)
    document.addEventListener('keydown', onKeyDown, true)
    return () => {
      document.removeEventListener('pointerdown', onPointerDown, true)
      document.removeEventListener('keydown', onKeyDown, true)
    }
  }, [popover, button, onClose])
}
