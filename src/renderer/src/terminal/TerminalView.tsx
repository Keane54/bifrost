import { useEffect, useRef } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebglAddon } from '@xterm/addon-webgl'

// One terminal. It opens a PTY on mount and closes it on unmount.
export function TerminalView(props: {
  viewId: string
  args: string[]
  cwd: string
}): React.JSX.Element {
  const { viewId, args, cwd } = props
  const hostRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const host = hostRef.current
    if (!host) return
    const api = window.bifrost
    const term = new Terminal({ fontSize: 13, scrollback: 5000 })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(host)
    let webgl: WebglAddon | null = null
    try {
      webgl = new WebglAddon()
      webgl.onContextLoss(() => {
        webgl?.dispose()
        webgl = null
      })
      term.loadAddon(webgl)
    } catch {
      // WebGL failed. xterm keeps the DOM renderer.
      webgl = null
    }

    let opened = false
    let disposed = false
    const syncSize = (): void => {
      try {
        fit.fit()
      } catch {
        return
      }
      if (opened) void api.pty.resize(viewId, term.cols, term.rows)
    }
    syncSize()

    const offData = api.pty.onData((id, chunk) => {
      if (id === viewId) term.write(chunk)
    })
    const offExit = api.pty.onExit((id, code) => {
      if (id === viewId) term.write(`\r\n[process ended: code ${code}]\r\n`)
    })
    const input = term.onData((data) => {
      if (opened) void api.pty.write(viewId, data)
    })
    const observer = new ResizeObserver(syncSize)
    observer.observe(host)

    api.pty
      .open(viewId, args, { cwd, cols: term.cols, rows: term.rows })
      .then(() => {
        if (disposed) {
          // The view went away while the PTY opened. Close the new PTY.
          void api.pty.close(viewId)
          return
        }
        opened = true
        syncSize()
      })
      .catch((err: unknown) => {
        if (!disposed) term.write(`\r\n[open failed: ${String(err)}]\r\n`)
      })

    return () => {
      disposed = true
      observer.disconnect()
      offData()
      offExit()
      input.dispose()
      // close() sends no pty:exit, so do not wait for an exit event.
      void api.pty.close(viewId)
      webgl?.dispose()
      fit.dispose()
      term.dispose()
    }
    // The view ID, args and cwd are fixed for the life of one view.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return <div ref={hostRef} style={{ width: '100%', height: '100%' }} />
}
