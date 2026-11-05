// The release of the WebGL context of a chat terminal (spec 8.5, 13).
// The dispose of the xterm.js WebGL addon removes its canvas, but it does not release the
// context. The context stays live until garbage collection. Chromium keeps a maximum of 16 live
// contexts for a page. Above that, it stops the context that it used least recently. That
// context can be on a visible terminal, which then keeps the DOM renderer.

export interface LoseContext {
  loseContext(): void
}

export interface WebglContext {
  isContextLost(): boolean
  getExtension(name: 'WEBGL_lose_context'): LoseContext | null
}

export interface ContextCanvas {
  getContext(contextId: 'webgl2'): WebglContext | null
}

// The WebGL 2 contexts of the canvases in after that are not in before. The addon adds its
// canvases during the load. getContext gives the context that a canvas has, or null for a 2D
// context. A canvas in before can have no context, and getContext then starts a new context.
// So this function asks only the new canvases.
export function addedContexts<T extends ContextCanvas>(
  before: readonly T[],
  after: readonly T[],
): WebglContext[] {
  const contexts: WebglContext[] = []
  for (const canvas of after) {
    if (before.includes(canvas)) continue
    const gl = canvas.getContext('webgl2')
    if (gl) contexts.push(gl)
  }
  return contexts
}

// Lose each live context, then dispose the addon. The browser sends the context loss event in a
// later task. The dispose removes the listener of the addon before that task. So the release
// does not mark WebGL as broken. A failed lose does not stop the dispose.
export function releaseWebgl(contexts: readonly WebglContext[], dispose: () => void): void {
  for (const gl of contexts) {
    try {
      if (!gl.isContextLost()) gl.getExtension('WEBGL_lose_context')?.loseContext()
    } catch (err) {
      // The garbage collector then releases the context.
      console.warn('Bifrost cannot release a WebGL context.', err)
    }
  }
  dispose()
}
