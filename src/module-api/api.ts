// The client library of Bifrost modules (docs/modules.md). Its source is src/module-api/api.ts in
// the Bifrost repository. The main build compiles the source to a classic script
// (scripts/module-api/build.ts), and the module protocol serves the result at /_bifrost/api.js.
// A panel loads it with <script src="/_bifrost/api.js"></script>, before its own scripts. It has
// no import or export, so a module script can also use it.
//
// It adds one frozen object, bifrost:
//   bifrost.call(name, args) sends a call to Heimdall. The promise resolves with the value, or
//   rejects with an Error whose message is the "refused: ..." code.
//   bifrost.on(event, fn) calls fn(data) for each event of that name. It returns a function that
//   removes the listener.
;(() => {
  // biome-ignore lint/suspicious/noRedundantUseStrict: a frame loads this file as a classic script
  'use strict'

  type Listener = (data: unknown) => void

  interface PendingCall {
    reject(error: Error): void
    resolve(value: unknown): void
  }

  // A second load of this file keeps the first object.
  if (Object.hasOwn(globalThis, 'bifrost')) return
  const TAG = 1
  const FAILED = 'refused: module call failed'
  const host = parent
  const pending = new Map<number, PendingCall>()
  const listeners = new Map<string, Set<Listener>>()
  // Each page starts at a random id. So a late answer to a page that loaded before cannot match a
  // call of this page.
  let nextId = Math.floor(Math.random() * 2 ** 40)

  addEventListener('message', (event: MessageEvent) => {
    // Only the Bifrost window that holds the frame sends answers and events.
    if (event.source !== host) return
    const message = event.data
    if (message === null || typeof message !== 'object' || message.bifrost !== TAG) return
    if (typeof message.event === 'string') {
      for (const fn of [...(listeners.get(message.event) ?? [])]) {
        try {
          fn(message.data)
        } catch (error) {
          console.error(error)
        }
      }
      return
    }
    const call = pending.get(message.id)
    if (call === undefined) return
    pending.delete(message.id)
    if (message.ok === true) call.resolve(message.value)
    else call.reject(new Error(typeof message.error === 'string' ? message.error : FAILED))
  })

  function call(name: string, args?: unknown): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const id = nextId
      nextId += 1
      pending.set(id, { reject, resolve })
      try {
        host.postMessage({ args, bifrost: TAG, call: name, id }, '*')
      } catch (error) {
        pending.delete(id)
        reject(error)
      }
    })
  }

  function on(event: string, fn: Listener): () => void {
    if (typeof event !== 'string' || typeof fn !== 'function') {
      throw new TypeError('bifrost.on needs an event name and a function.')
    }
    let set = listeners.get(event)
    if (set === undefined) {
      set = new Set()
      listeners.set(event, set)
    }
    const own = set
    own.add(fn)
    return () => {
      own.delete(fn)
    }
  }

  Object.defineProperty(globalThis, 'bifrost', {
    enumerable: true,
    value: Object.freeze({ call, on }),
  })
})()
