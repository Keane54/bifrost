// A small React renderer for a module in the host. React keeps its tree of plain nodes here, and
// each commit goes to the host as one batch of ops through __bifrostSend. The host calls
// __bifrostOnEvent with a handler number and a value when something happens on its side.
import type { ReactNode } from 'react'
import React from 'react'
import Reconciler from 'react-reconciler'
import {
  ConcurrentRoot,
  DefaultEventPriority,
  NoEventPriority,
} from 'react-reconciler/constants.js'

type Props = Record<string, unknown>
type Callback = (value: unknown) => unknown

// The root is node 0. A function prop goes out as {"$fn": n}, where n stays the same for as long
// as that prop of that node is a function, so a new closure for it sends nothing.
export type Op =
  | ['create', number, string, Props]
  | ['text', number, string]
  | ['append', number, number]
  | ['insert', number, number, number]
  | ['remove', number, number]
  | ['update', number, Props]
  | ['setText', number, string]

interface HostNode {
  readonly id: number
  // null for a text node.
  readonly type: string | null
  props: Props
  text: string
  readonly children: HostNode[]
  // The handler number of each function prop, once the node has gone to the host.
  readonly handlers: Map<string, number>
  // React makes nodes while it renders and can throw a render away, so a node only goes to the
  // host when a commit attaches it. Until then nothing about it is sent.
  sent: boolean
}

const host = globalThis as typeof globalThis & {
  __bifrostSend(ops: Op[]): void
  __bifrostOnEvent?: (handler: number, value: unknown) => void
}

let nextNode = 1
let nextHandler = 1
const callbacks = new Map<number, Callback>()
let ops: Op[] = []
let updatePriority: number = NoEventPriority
const hostContext = {}

function makeNode(id: number, type: string | null, props: Props, text: string): HostNode {
  return { id, type, props, text, children: [], handlers: new Map(), sent: false }
}

// React passes children, and in React 19 ref, as props, but neither means anything to the host.
const ownProp = (key: string) => key !== 'children' && key !== 'ref'

function handlerFor(node: HostNode, key: string, callback: Callback) {
  let handler = node.handlers.get(key)
  if (handler === undefined) {
    handler = nextHandler++
    node.handlers.set(key, handler)
  }
  callbacks.set(handler, callback)
  return { $fn: handler }
}

function dropHandler(node: HostNode, key: string) {
  const handler = node.handlers.get(key)
  if (handler === undefined) return
  callbacks.delete(handler)
  node.handlers.delete(key)
}

function encodeProps(node: HostNode): Props {
  const encoded: Props = {}
  for (const [key, value] of Object.entries(node.props)) {
    if (!ownProp(key) || value === undefined) continue
    encoded[key] = typeof value === 'function' ? handlerFor(node, key, value as Callback) : value
  }
  return encoded
}

// Only what changed goes out, with null for a prop that's gone. Values compare by identity, so a
// module should pass plain JSON values and keep any object prop it doesn't mean to change.
function changedProps(node: HostNode, oldProps: Props, newProps: Props): Props | null {
  const changed: Props = {}
  for (const [key, value] of Object.entries(newProps)) {
    if (!ownProp(key) || value === undefined) continue
    if (typeof value === 'function') {
      const known = node.handlers.has(key)
      const encoded = handlerFor(node, key, value as Callback)
      if (!known) changed[key] = encoded
    } else if (node.handlers.has(key) || !Object.is(oldProps[key], value)) {
      dropHandler(node, key)
      changed[key] = value
    }
  }
  for (const [key, value] of Object.entries(oldProps)) {
    if (!ownProp(key) || value === undefined || newProps[key] !== undefined) continue
    dropHandler(node, key)
    changed[key] = null
  }
  return Object.keys(changed).length > 0 ? changed : null
}

// Sends a node the host hasn't seen, with everything React attached to it while rendering.
function sendTree(node: HostNode) {
  if (node.sent) return
  node.sent = true
  if (node.type === null) ops.push(['text', node.id, node.text])
  else ops.push(['create', node.id, node.type, encodeProps(node)])
  for (const child of node.children) {
    sendTree(child)
    ops.push(['append', node.id, child.id])
  }
}

function forget(node: HostNode) {
  for (const handler of node.handlers.values()) callbacks.delete(handler)
  node.handlers.clear()
  for (const child of node.children) forget(child)
}

function detach(parent: HostNode, child: HostNode) {
  const index = parent.children.indexOf(child)
  if (index >= 0) parent.children.splice(index, 1)
}

function appendChild(parent: HostNode, child: HostNode) {
  detach(parent, child)
  parent.children.push(child)
  if (!parent.sent) return
  sendTree(child)
  ops.push(['append', parent.id, child.id])
}

function insertBefore(parent: HostNode, child: HostNode, before: HostNode) {
  detach(parent, child)
  parent.children.splice(parent.children.indexOf(before), 0, child)
  if (!parent.sent) return
  sendTree(child)
  ops.push(['insert', parent.id, child.id, before.id])
}

function removeChild(parent: HostNode, child: HostNode) {
  detach(parent, child)
  forget(child)
  if (parent.sent && child.sent) ops.push(['remove', parent.id, child.id])
}

const reconciler = Reconciler({
  rendererPackageName: 'bifrost-module',
  rendererVersion: '0.0.0',
  supportsMutation: true,
  supportsPersistence: false,
  supportsHydration: false,
  isPrimaryRenderer: true,
  // The host gives a module setTimeout, clearTimeout and queueMicrotask, and nothing else that
  // schedules work.
  supportsMicrotasks: true,
  scheduleMicrotask: (callback: () => void) => queueMicrotask(callback),
  scheduleTimeout: (callback: () => void, delay: number) => setTimeout(callback, delay),
  cancelTimeout: (id: ReturnType<typeof setTimeout>) => clearTimeout(id),
  noTimeout: -1,

  // React wants a host context object, even though every node here gets the same one.
  getRootHostContext: () => hostContext,
  getChildHostContext: (context: object) => context,
  getPublicInstance: (node: HostNode) => node,
  shouldSetTextContent: () => false,
  createInstance: (type: string, props: Props) => makeNode(nextNode++, type, props, ''),
  createTextInstance: (text: string) => makeNode(nextNode++, null, {}, text),
  appendInitialChild: (parent: HostNode, child: HostNode) => {
    parent.children.push(child)
  },
  finalizeInitialChildren: () => false,

  prepareForCommit: () => null,
  // One batch per commit, and none for a commit that changed nothing the host can see.
  resetAfterCommit: () => {
    if (ops.length === 0) return
    const batch = ops
    ops = []
    host.__bifrostSend(batch)
  },
  preparePortalMount: () => {},
  clearContainer: (container: HostNode) => {
    for (const child of [...container.children]) removeChild(container, child)
  },
  appendChild,
  appendChildToContainer: appendChild,
  insertBefore,
  insertInContainerBefore: insertBefore,
  removeChild,
  removeChildFromContainer: removeChild,
  commitUpdate: (node: HostNode, _type: string, oldProps: Props, newProps: Props) => {
    node.props = newProps
    const changed = changedProps(node, oldProps, newProps)
    if (changed) ops.push(['update', node.id, changed])
  },
  commitTextUpdate: (node: HostNode, _oldText: string, text: string) => {
    node.text = text
    ops.push(['setText', node.id, text])
  },
  commitMount: () => {},
  resetTextContent: () => {},
  // Suspense hides what it has already shown while it waits, rather than removing it.
  hideInstance: (node: HostNode) => {
    ops.push(['update', node.id, { hidden: true }])
  },
  unhideInstance: (node: HostNode) => {
    ops.push(['update', node.id, { hidden: false }])
  },
  hideTextInstance: (node: HostNode) => {
    ops.push(['setText', node.id, ''])
  },
  unhideTextInstance: (node: HostNode, text: string) => {
    node.text = text
    ops.push(['setText', node.id, text])
  },
  detachDeletedInstance: () => {},

  // React 19 asks the renderer for the priority of an update. The rest are hooks for transitions,
  // forms, suspended commits and focus, which this host has no use for.
  getCurrentUpdatePriority: () => updatePriority,
  setCurrentUpdatePriority: (priority: number) => {
    updatePriority = priority
  },
  resolveUpdatePriority: () =>
    updatePriority !== NoEventPriority ? updatePriority : DefaultEventPriority,
  NotPendingTransition: null,
  HostTransitionContext: React.createContext(null),
  resetFormInstance: () => {},
  shouldAttemptEagerTransition: () => false,
  trackSchedulerEvent: () => {},
  resolveEventType: () => null,
  resolveEventTimeStamp: () => -1.1,
  requestPostPaintCallback: () => {},
  maySuspendCommit: () => false,
  maySuspendCommitOnUpdate: () => false,
  maySuspendCommitInSyncRender: () => false,
  preloadInstance: () => true,
  startSuspendingCommit: () => null,
  suspendInstance: () => {},
  suspendOnActiveViewTransition: () => {},
  waitForCommitToBeReady: () => null,
  getSuspendedCommitReason: () => null,
  getInstanceFromNode: () => null,
  beforeActiveInstanceBlur: () => {},
  afterActiveInstanceBlur: () => {},
  prepareScopeUpdate: () => {},
  getInstanceFromScope: () => null,
})

const report = (kind: string) => (error: unknown) => console.error(kind, error)

// Renders the module's app into node 0. The first commit happens before this returns, so the
// whole first tree goes to the host as one batch.
export function render(element: ReactNode): void {
  const container = makeNode(0, 'root', {}, '')
  container.sent = true
  const root = reconciler.createContainer(
    container,
    ConcurrentRoot,
    null,
    false,
    null,
    '',
    report('Uncaught render error'),
    report('Caught render error'),
    report('Recoverable render error'),
    () => {},
  )
  reconciler.updateContainerSync(element, root, null, null)
  reconciler.flushSyncWork()
}

// An event runs at the priority of a click, and its commit is flushed before this returns, so
// the host has the event's batch as soon as the call ends, even when the handler throws after
// changing state. A handler that's gone is ignored.
host.__bifrostOnEvent = (handler, value) => {
  const callback = callbacks.get(handler)
  if (callback === undefined) return
  try {
    reconciler.discreteUpdates(() => {
      callback(value)
    })
  } finally {
    reconciler.flushSyncWork()
  }
}
