import { useCallback, useEffect, useRef, useState } from 'react'
import type { AgentEntry } from '../../../main/claude/agents'
import { TerminalView } from '../terminal/TerminalView'

// Temporary M0 harness. The user uses it by hand to answer the claude attach questions.
// The main process also checks every signal. The checks here protect the UI.

const TEST_PREFIX = 'bifrost-test-'
const SANDBOX = '.m0-sandbox'
const SIGNALS = ['SIGTERM', 'SIGHUP', 'SIGINT']
const LEFT_ARROW = '\x1b[D'

// A view is a TerminalView or a hidden attach (a PTY with no terminal).
type View = {
  viewId: string
  target: string // the session name that the view belongs to
  hidden: boolean
  isTest: boolean
  args: string[]
  cwd: string
}

const isTestName = (name: string): boolean => name.startsWith(TEST_PREFIX)

const th: React.CSSProperties = {
  textAlign: 'left',
  padding: '2px 8px',
  borderBottom: '1px solid #345'
}
const td: React.CSSProperties = { padding: '2px 8px', whiteSpace: 'nowrap' }
const box: React.CSSProperties = { border: '1px solid #345', padding: 8, margin: '8px 0' }

export function Harness(): React.JSX.Element {
  const [entries, setEntries] = useState<AgentEntry[]>([])
  const [listError, setListError] = useState<string | undefined>()
  const [views, setViews] = useState<View[]>([])
  const [bytes, setBytes] = useState<Record<string, number>>({})
  const [signalChoice, setSignalChoice] = useState<Record<number, string>>({})
  const [sendTarget, setSendTarget] = useState('')
  const [sendText, setSendText] = useState('')
  const [paste, setPaste] = useState(false)
  const [suffix, setSuffix] = useState('')
  const [extraArgs, setExtraArgs] = useState('')
  const [prompt, setPrompt] = useState('')
  const [runOutput, setRunOutput] = useState('')
  const [log, setLog] = useState('')
  const counter = useRef(0)
  const viewsRef = useRef<View[]>([])
  useEffect(() => {
    viewsRef.current = views
  }, [views])

  // Poll the session list every 2 seconds. Skip a tick if the last call is not done.
  useEffect(() => {
    let alive = true
    let busy = false
    const tick = async (): Promise<void> => {
      if (busy) return
      busy = true
      try {
        const r = await window.bifrost.agents.list()
        if (!alive) return
        setEntries(r.entries)
        setListError(r.error)
      } catch (err) {
        if (alive) setListError(String(err))
      } finally {
        busy = false
      }
    }
    void tick()
    const timer = setInterval(() => void tick(), 2000)
    return () => {
      alive = false
      clearInterval(timer)
    }
  }, [])

  // Count the bytes that each hidden attach gets.
  useEffect(() => {
    return window.bifrost.pty.onData((viewId, chunk) => {
      if (!viewsRef.current.some((v) => v.hidden && v.viewId === viewId)) return
      setBytes((b) => ({ ...b, [viewId]: (b[viewId] ?? 0) + chunk.length }))
    })
  }, [])

  const nextId = (prefix: string): string => `${prefix}-${++counter.current}`

  const addView = (v: View): void => setViews((vs) => [...vs, v])

  // Remove a view. A TerminalView closes its own PTY when it unmounts.
  // A hidden attach has no TerminalView, so close its PTY here.
  const removeView = (v: View, signal?: string): void => {
    if (v.hidden || signal) void window.bifrost.pty.close(v.viewId, signal)
    setViews((vs) => vs.filter((x) => x.viewId !== v.viewId))
  }

  const openView = (e: AgentEntry, hidden: boolean): void => {
    const args = ['attach', e.id ?? e.name]
    const viewId = nextId(hidden ? 'hidden' : 'view')
    const v: View = {
      viewId,
      target: e.name,
      hidden,
      isTest: isTestName(e.name),
      args,
      cwd: SANDBOX
    }
    addView(v)
    if (hidden) {
      window.bifrost.pty
        .open(viewId, args, { cwd: SANDBOX, cols: 80, rows: 24 })
        .then((pid) => setLog(`Hidden attach ${viewId} opened. PID ${pid}.`))
        .catch((err: unknown) => setLog(`Hidden attach failed: ${String(err)}`))
    }
  }

  // Close the views of one test session with a signal.
  const closeRow = (e: AgentEntry, signal: string): void => {
    if (!isTestName(e.name)) return
    const mine = views.filter((v) => v.target === e.name && v.isTest)
    mine.forEach((v) => removeView(v, signal))
    setLog(`Closed ${mine.length} view(s) of ${e.name} with ${signal}.`)
  }

  const writeTo = async (viewId: string, data: string): Promise<void> => {
    const v = viewsRef.current.find((x) => x.viewId === viewId)
    if (!v || !v.isTest) {
      setLog(`Refused: ${viewId} is not a view of a test session.`)
      return
    }
    const ok = await window.bifrost.pty.write(viewId, data)
    setLog(`Write to ${viewId}: ${ok ? 'sent' : 'failed'}.`)
  }

  const sendLeft = (e: AgentEntry): void => {
    if (!isTestName(e.name)) return
    const mine = views.filter((v) => v.target === e.name && v.isTest)
    const last = mine[mine.length - 1]
    if (!last) setLog(`No open view for ${e.name}.`)
    else void writeTo(last.viewId, LEFT_ARROW)
  }

  const sendSignal = async (e: AgentEntry): Promise<void> => {
    if (!isTestName(e.name)) return
    const sig = signalChoice[e.pid] ?? SIGNALS[0]
    const ok = await window.bifrost.proc.signal(e.pid, sig)
    setLog(`Signal ${sig} to PID ${e.pid}: ${ok ? 'sent' : 'refused or failed'}.`)
  }

  const sendBox = (): void => {
    const body = paste ? `\x1b[200~${sendText}\x1b[201~` : sendText
    void writeTo(sendTarget.trim(), body + '\r')
  }

  const startTest = async (): Promise<void> => {
    const name = TEST_PREFIX + suffix.trim()
    const extra = extraArgs.split(' ').filter((a) => a !== '')
    const args = ['--bg', '--model', 'haiku', '--name', name, ...extra]
    if (prompt !== '') args.push(prompt)
    setRunOutput('Running...')
    try {
      const r = await window.bifrost.claude.run(args, SANDBOX)
      setRunOutput(`exit ${r.code}\nstdout:\n${r.stdout}\nstderr:\n${r.stderr}`)
    } catch (err) {
      setRunOutput(`error: ${String(err)}`)
    }
  }

  const startExternal = useCallback((): void => {
    addView({
      viewId: nextId('ext'),
      target: TEST_PREFIX + 'ext',
      hidden: false,
      isTest: true,
      args: ['--model', 'haiku', '--name', TEST_PREFIX + 'ext'],
      cwd: SANDBOX
    })
  }, [])

  const testViews = views.filter((v) => v.isTest)

  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        overflow: 'auto',
        padding: 12,
        background: '#0b0f14',
        color: '#d6dde6',
        font: '13px ui-monospace, Menlo, monospace',
        userSelect: 'text',
        textAlign: 'left'
      }}
    >
      <h2 style={{ margin: '0 0 8px' }}>Bifrost M0 harness</h2>
      {listError && <div style={{ color: '#f88' }}>List error: {listError}</div>}
      <table style={{ borderCollapse: 'collapse' }}>
        <thead>
          <tr>
            {['name', 'kind', 'status', 'id', 'sessionId', 'pid', 'cwd', 'actions'].map((h) => (
              <th key={h} style={th}>
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {entries.map((e) => {
            const ok = isTestName(e.name)
            return (
              <tr key={`${e.pid}-${e.sessionId}`}>
                <td style={td}>{e.name}</td>
                <td style={td}>{e.kind}</td>
                <td style={td}>{e.status}</td>
                <td style={td}>{e.id ?? ''}</td>
                <td style={td}>{e.sessionId}</td>
                <td style={td}>{e.pid}</td>
                <td style={td}>{e.cwd}</td>
                <td style={td}>
                  <button onClick={() => openView(e, false)}>View</button>{' '}
                  <button onClick={() => openView(e, false)}>Second view</button>{' '}
                  <button onClick={() => openView(e, true)}>Hidden attach</button>{' '}
                  <button disabled={!ok} onClick={() => closeRow(e, 'SIGHUP')}>
                    Close SIGHUP
                  </button>{' '}
                  <button disabled={!ok} onClick={() => closeRow(e, 'SIGTERM')}>
                    Close SIGTERM
                  </button>{' '}
                  <button disabled={!ok} onClick={() => sendLeft(e)}>
                    Send ←
                  </button>{' '}
                  <select
                    value={signalChoice[e.pid] ?? SIGNALS[0]}
                    disabled={!ok}
                    onChange={(ev) => setSignalChoice((s) => ({ ...s, [e.pid]: ev.target.value }))}
                  >
                    {SIGNALS.map((s) => (
                      <option key={s}>{s}</option>
                    ))}
                  </select>{' '}
                  <button disabled={!ok} onClick={() => void sendSignal(e)}>
                    Signal
                  </button>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
      {log && <div style={{ margin: '8px 0', color: '#9cf' }}>{log}</div>}

      <div style={box}>
        <b>Send box</b> (test views only){' '}
        <input
          list="test-views"
          placeholder="target view ID"
          value={sendTarget}
          onChange={(ev) => setSendTarget(ev.target.value)}
        />
        <datalist id="test-views">
          {testViews.map((v) => (
            <option key={v.viewId} value={v.viewId} />
          ))}
        </datalist>{' '}
        <input
          placeholder="text"
          size={40}
          value={sendText}
          onChange={(ev) => setSendText(ev.target.value)}
        />{' '}
        <label>
          <input type="checkbox" checked={paste} onChange={(ev) => setPaste(ev.target.checked)} />{' '}
          Bracketed paste
        </label>{' '}
        <button onClick={sendBox}>Send</button>
      </div>

      <div style={box}>
        <b>Start test session</b> {TEST_PREFIX}
        <input
          placeholder="suffix"
          size={12}
          value={suffix}
          onChange={(ev) => setSuffix(ev.target.value)}
        />{' '}
        <input
          placeholder="extra args (split on spaces)"
          size={28}
          value={extraArgs}
          onChange={(ev) => setExtraArgs(ev.target.value)}
        />{' '}
        <input
          placeholder="prompt"
          size={40}
          value={prompt}
          onChange={(ev) => setPrompt(ev.target.value)}
        />{' '}
        <button disabled={suffix.trim() === ''} onClick={() => void startTest()}>
          Start test session
        </button>
        {runOutput && <pre style={{ margin: '8px 0 0', whiteSpace: 'pre-wrap' }}>{runOutput}</pre>}
      </div>

      <div style={box}>
        <button onClick={startExternal}>Start external session</button>
      </div>

      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
        {views.map((v) => (
          <div key={v.viewId} style={{ border: '1px solid #345', width: 640 }}>
            <div style={{ padding: '2px 6px', background: '#16202b' }}>
              {v.viewId} | {v.target} | {v.args.join(' ')}
              {v.hidden && <span> | hidden, {bytes[v.viewId] ?? 0} bytes</span>}{' '}
              <button onClick={() => removeView(v)}>Remove</button>
            </div>
            {!v.hidden && (
              <div style={{ height: 360 }}>
                <TerminalView viewId={v.viewId} args={v.args} cwd={v.cwd} />
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}
