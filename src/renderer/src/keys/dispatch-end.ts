// Run a callback at the end of the dispatch of a key event (spec 9.4). The keys of Bifrost listen
// in the capture phase, before the other handlers. Esc must not open or close Settings when a
// popover or a drag took it. So the Esc key waits for the end of the dispatch.

// The part of the window that this module uses. A test passes a plain EventTarget.
export type DispatchTarget = Pick<EventTarget, 'addEventListener' | 'removeEventListener'>

// The callback runs when the event gets to the target in the bubble phase. Use the window as
// the target: it is the last target of a key event. handled is true when a handler took the key
// with preventDefault. When a handler stops the event before the target, the callback never runs.
// Then the timer removes the listener.
export function atDispatchEnd(
  event: Event,
  target: DispatchTarget,
  run: (handled: boolean) => void,
  later: (fn: () => void) => void = fn => {
    setTimeout(fn, 0)
  },
): void {
  const remove = (): void => target.removeEventListener(event.type, onEvent)
  // A later event of the same type, for example a key repeat, is not this event.
  function onEvent(ev: Event): void {
    if (ev !== event) return
    remove()
    run(ev.defaultPrevented)
  }
  target.addEventListener(event.type, onEvent)
  later(remove)
}
