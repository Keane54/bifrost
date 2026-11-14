// The bridge between one module frame and Heimdall (Modules design 8.1). The frame sends calls
// with postMessage. The bridge takes a message only from its own frame, binds it to the module of
// the frame (never to a field of the message), and sends it to the main process. Heimdall checks
// each call there. The caps here only keep a flood away from the IPC channel.

import {
  MODULE_CALL_NAME_MAX,
  MODULE_IN_FLIGHT,
  MODULE_MESSAGE_BYTES,
  MODULE_RATE,
  REFUSED_BAD_MODULE_INPUT,
  REFUSED_CALL_FAILED,
  REFUSED_MESSAGE_TOO_LARGE,
  REFUSED_TOO_MANY_CALLS,
} from '../../../shared/modules'
import { isPlainObject } from '../../../shared/plain-object'

// The tag of each message of the bridge, in both directions.
export const BRIDGE_TAG = 1

// The part of a window that the bridge uses.
export interface BridgeTarget {
  postMessage(message: unknown, targetOrigin: string): void
}

export interface BridgeDeps {
  // The module of the frame. It comes from the props of the frame, never from a message.
  moduleId: string
  // The window of the frame, or null before the frame exists.
  frame(): BridgeTarget | null
  call(moduleId: string, name: string, args: unknown): Promise<unknown>
  now(): number
}

export interface Bridge {
  // Handle a message event of the Bifrost window.
  receive(event: { source: unknown; data: unknown }): void
  // Send an event of Heimdall to the frame.
  event(name: string, data: unknown): void
  // Stop. After this, no reply and no event goes to the frame.
  close(): void
}

const RATE_WINDOW_MS = 1000

const encoder = new TextEncoder()

function utf8Bytes(text: string): number {
  return encoder.encode(text).length
}

// A code that the module can get. Any other error text stays in Bifrost.
function errorCode(error: unknown): string {
  const message = error instanceof Error ? error.message : ''
  return message.startsWith('refused: ') ? message : REFUSED_CALL_FAILED
}

export function createBridge(deps: BridgeDeps): Bridge {
  const times: number[] = []
  let open = 0
  let closed = false

  // The frame has an opaque origin, so the target origin must be "*". The frame can only show a
  // module page, so no other page gets the message.
  function post(message: Record<string, unknown>): void {
    if (closed) return
    try {
      deps.frame()?.postMessage(message, '*')
    } catch {
      // A frame that is gone gets nothing.
    }
  }

  function reply(id: number, result: { value: unknown } | { error: string }): void {
    post(
      'value' in result
        ? { bifrost: BRIDGE_TAG, id, ok: true, value: result.value }
        : { bifrost: BRIDGE_TAG, error: result.error, id, ok: false },
    )
  }

  function takePlace(now: number): boolean {
    while (times.length > 0 && now - (times[0] as number) >= RATE_WINDOW_MS) times.shift()
    if (times.length >= MODULE_RATE) return false
    times.push(now)
    return true
  }

  function receive(event: { source: unknown; data: unknown }): void {
    if (closed) return
    const frame = deps.frame()
    if (frame === null || event.source !== frame) return
    const { data } = event
    if (!isPlainObject(data) || data.bifrost !== BRIDGE_TAG) return
    const { id } = data
    if (typeof id !== 'number' || !Number.isSafeInteger(id) || id < 0) return
    const name = data.call
    if (typeof name !== 'string' || name === '' || name.length > MODULE_CALL_NAME_MAX) {
      reply(id, { error: REFUSED_BAD_MODULE_INPUT })
      return
    }
    if (!takePlace(deps.now()) || open >= MODULE_IN_FLIGHT) {
      reply(id, { error: REFUSED_TOO_MANY_CALLS })
      return
    }
    // The main process gets a JSON copy of the arguments. No arguments give null.
    let text: string | undefined
    try {
      text = JSON.stringify(data.args)
    } catch {
      reply(id, { error: REFUSED_BAD_MODULE_INPUT })
      return
    }
    if (text !== undefined && utf8Bytes(text) > MODULE_MESSAGE_BYTES) {
      reply(id, { error: REFUSED_MESSAGE_TOO_LARGE })
      return
    }
    const args: unknown = text === undefined ? null : JSON.parse(text)
    open += 1
    Promise.resolve()
      .then(() => deps.call(deps.moduleId, name, args))
      .then(
        value => reply(id, { value }),
        error => reply(id, { error: errorCode(error) }),
      )
      .finally(() => {
        open -= 1
      })
  }

  return {
    close: () => {
      closed = true
    },
    event: (name, data) => post({ bifrost: BRIDGE_TAG, data, event: name }),
    receive,
  }
}

// The part of the Bifrost window that a frame connection uses.
export interface FrameHost {
  addEventListener(type: 'message', fn: (e: { source: unknown; data: unknown }) => void): void
  removeEventListener(type: 'message', fn: (e: { source: unknown; data: unknown }) => void): void
}

// The part of window.bifrost.modules that a frame connection uses.
export interface FrameModules {
  call(moduleId: string, name: string, args: unknown): Promise<unknown>
  onEvent(cb: (moduleId: string, event: string, data: unknown) => void): () => void
}

// Connect one frame element to Heimdall. The bridge reads the window of this element only, so
// after the element leaves the page, nothing more goes out with its module id. A new frame
// element gets a new connection. The returned function disconnects.
export function connectFrame(
  element: { contentWindow: BridgeTarget | null },
  moduleId: string,
  deps: { host: FrameHost; modules: FrameModules; now(): number },
): () => void {
  const bridge = createBridge({
    call: (id, name, args) => deps.modules.call(id, name, args),
    frame: () => element.contentWindow,
    moduleId,
    now: deps.now,
  })
  const onMessage = (e: { source: unknown; data: unknown }): void => bridge.receive(e)
  deps.host.addEventListener('message', onMessage)
  const offEvent = deps.modules.onEvent((id, event, data) => {
    if (id === moduleId) bridge.event(event, data)
  })
  return () => {
    deps.host.removeEventListener('message', onMessage)
    offEvent()
    bridge.close()
  }
}
