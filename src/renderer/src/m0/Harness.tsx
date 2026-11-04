import { useEffect, useRef, useState } from 'react'
import type { AgentEntry } from '../../../main/claude/agents'
import { TEST_PREFIX } from '../../../main/claude/guard'
import { TerminalView } from '../terminal/TerminalView'
import { isSendKey, sendBody } from './send-box'

// Temporary M0 harness. The user uses it by hand to answer the claude attach questions.
// The main process also checks every signal. The checks here protect the UI.

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
  borderBottom: '1px solid #345',
  padding: '2px 8px',
  textAlign: 'left',
}
const td: React.CSSProperties = { padding: '2px 8px', whiteSpace: 'nowrap' }
const box: React.CSSProperties = { border: '1px solid #345', margin: '8px 0', padding: 8 }

export function Harness(): React.JSX.Element {
  const [entries, setEntries] = useState<AgentEntry[]>([])
  const [listError, setListError] = useState<string | undefined>()
  const [views, setViews] = useState<View[]>([])
  const [bytes, setBytes] = useState<Record<string, number>>({})
  const [signalChoice, setSignalChoice] = useState<Record<string, string>>({})
  const [sendTarget, setSendTarget] = useState('')
  const [sendText, setSendText] = useState('')
  const [paste, setPaste] = useState(false)
  const [suffix, setSuffix] = useState('')
  const [extraArgs, setExtraArgs] = useState('')
  const [prompt, setPrompt] = useState('')
  const [runOutput, setRunOutput] = useState('')
  const [log, setLog] = useState('')
  const counter = useRef(0)
  // viewsRef always holds the current views. A callback reads it after an await.
  const viewsRef = useRef<View[]>([])
  const updateViews = (change: (vs: View[]) => View[]): void => {
    viewsRef.current = change(viewsRef.current)
    setViews(viewsRef.current)
  }
  const isOpenView = (viewId: string): boolean => viewsRef.current.some(x => x.viewId === viewId)

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
      if (!viewsRef.current.some(v => v.hidden && v.viewId === viewId)) return
      setBytes(b => ({ ...b, [viewId]: (b[viewId] ?? 0) + chunk.length }))
    })
  }, [])

  const nextId = (prefix: string): string => `${prefix}-${++counter.current}`

  const addView = (v: View): void => updateViews(vs => [...vs, v])

  // Remove a view. A TerminalView closes its own PTY when it unmounts.
  // A hidden attach has no TerminalView, so close its PTY here.
  const removeView = (v: View, signal?: string): void => {
    if (v.hidden || signal) void window.bifrost.pty.close(v.viewId, signal)
    updateViews(vs => vs.filter(x => x.viewId !== v.viewId))
  }

  const openView = (e: AgentEntry, hidden: boolean): void => {
    const args = ['attach', e.id ?? e.name]
    const viewId = nextId(hidden ? 'hidden' : 'view')
    const v: View = {
      args,
      cwd: SANDBOX,
      hidden,
      isTest: isTestName(e.name),
      target: e.name,
      viewId,
    }
    addView(v)
    if (hidden) {
      window.bifrost.pty
        .open(viewId, args, { cols: 80, cwd: SANDBOX, rows: 24 })
        .then(pid => {
          // the user can remove the view while the PTY opens. Then close the new PTY.
          // Otherwise an extra attach client stays alive with no view.
          if (!isOpenView(viewId)) {
            void window.bifrost.pty.close(viewId)
            setLog(`Hidden attach ${viewId} was removed before it opened. Closed PID ${pid}.`)
            return
          }
          setLog(`Hidden attach ${viewId} opened. PID ${pid}.`)
        })
        .catch((err: unknown) => {
          // A failed open has no PTY. Remove its row.
          updateViews(vs => vs.filter(x => x.viewId !== viewId))
          setLog(`Hidden attach ${viewId} failed: ${String(err)}`)
        })
    }
  }

  // Close the views of one test session with a signal.
  const closeRow = (e: AgentEntry, signal: string): void => {
    if (!isTestName(e.name)) return
    const mine = views.filter(v => v.target === e.name && v.isTest)
    for (const v of mine) removeView(v, signal)
    setLog(`Closed ${mine.length} view(s) of ${e.name} with ${signal}.`)
  }

  const writeTo = async (viewId: string, data: string): Promise<void> => {
    const v = viewsRef.current.find(x => x.viewId === viewId)
    if (!v?.isTest) {
      setLog(`Refused: ${viewId} is not a view of a test session.`)
      return
    }
    const ok = await window.bifrost.pty.write(viewId, data)
    setLog(`Write to ${viewId}: ${ok ? 'sent' : 'failed'}.`)
  }

  const sendLeft = (e: AgentEntry): void => {
    if (!isTestName(e.name)) return
    const mine = views.filter(v => v.target === e.name && v.isTest)
    const last = mine[mine.length - 1]
    if (!last) setLog(`No open view for ${e.name}.`)
    else void writeTo(last.viewId, LEFT_ARROW)
  }

  const sendSignal = async (e: AgentEntry): Promise<void> => {
    if (!isTestName(e.name) || e.pid === undefined) return
    const sig = signalChoice[e.sessionId] ?? SIGNALS[0]
    const ok = await window.bifrost.proc.signal(e.pid, sig)
    setLog(`Signal ${sig} to PID ${e.pid}: ${ok ? 'sent' : 'refused or failed'}.`)
  }

  const sendBox = (): void => {
    void writeTo(sendTarget.trim(), sendBody(sendText, paste))
  }

  const startTest = async (): Promise<void> => {
    if (prompt.startsWith('-')) {
      setRunOutput('Refused: the prompt must not start with "-".')
      return
    }
    // claude can read a one-word prompt as a subcommand. The main process refuses it.
    if (prompt !== '' && !/\s/.test(prompt.trim())) {
      setRunOutput('Refused: the prompt must have two or more words.')
      return
    }
    const name = TEST_PREFIX + suffix.trim()
    const extra = extraArgs.split(' ').filter(a => a !== '')
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

  const startExternal = (): void => {
    addView({
      args: ['--model', 'haiku', '--name', `${TEST_PREFIX}ext`],
      cwd: SANDBOX,
      hidden: false,
      isTest: true,
      target: `${TEST_PREFIX}ext`,
      viewId: nextId('ext'),
    })
  }

  const testViews = views.filter(v => v.isTest)

  return (
    <div
      style={{
        background: '#0b0f14',
        color: '#d6dde6',
        font: '13px ui-monospace, Menlo, monospace',
        inset: 0,
        overflow: 'auto',
        padding: 12,
        position: 'fixed',
        textAlign: 'left',
        userSelect: 'text',
      }}
    >
      <h2 style={{ margin: '0 0 8px' }}>Bifrost M0 harness</h2>
      {listError && <div style={{ color: '#f88' }}>List error: {listError}</div>}
      <table style={{ borderCollapse: 'collapse' }}>
        <thead>
          <tr>
            {['name', 'kind', 'status', 'id', 'sessionId', 'pid', 'cwd', 'actions'].map(h => (
              <th key={h} style={th}>
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {entries.map(e => {
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
                  <button disabled={!ok} onClick={() => openView(e, false)} type='button'>
                    View
                  </button>{' '}
                  <button disabled={!ok} onClick={() => openView(e, false)} type='button'>
                    Second view
                  </button>{' '}
                  <button disabled={!ok} onClick={() => openView(e, true)} type='button'>
                    Hidden attach
                  </button>{' '}
                  <button disabled={!ok} onClick={() => closeRow(e, 'SIGHUP')} type='button'>
                    Close SIGHUP
                  </button>{' '}
                  <button disabled={!ok} onClick={() => closeRow(e, 'SIGTERM')} type='button'>
                    Close SIGTERM
                  </button>{' '}
                  <button disabled={!ok} onClick={() => sendLeft(e)} type='button'>
                    Send ←
                  </button>{' '}
                  <select
                    disabled={!ok}
                    onChange={ev =>
                      setSignalChoice(s => ({ ...s, [e.sessionId]: ev.target.value }))
                    }
                    value={signalChoice[e.sessionId] ?? SIGNALS[0]}
                  >
                    {SIGNALS.map(s => (
                      <option key={s}>{s}</option>
                    ))}
                  </select>{' '}
                  <button disabled={!ok} onClick={() => void sendSignal(e)} type='button'>
                    Signal
                  </button>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
      {log && <div style={{ color: '#9cf', margin: '8px 0' }}>{log}</div>}

      <div style={box}>
        <b>Send box</b> (test views only){' '}
        <input
          list='test-views'
          onChange={ev => setSendTarget(ev.target.value)}
          placeholder='target view ID'
          value={sendTarget}
        />
        <datalist id='test-views'>
          {testViews.map(v => (
            <option key={v.viewId} value={v.viewId} />
          ))}
        </datalist>{' '}
        <textarea
          cols={48}
          onChange={ev => setSendText(ev.target.value)}
          onKeyDown={ev => {
            const key = {
              isComposing: ev.nativeEvent.isComposing,
              key: ev.key,
              shiftKey: ev.shiftKey,
            }
            if (!isSendKey(key)) return
            ev.preventDefault()
            sendBox()
          }}
          placeholder='text: Enter sends, Shift+Enter adds a line'
          rows={3}
          style={{ verticalAlign: 'top' }}
          value={sendText}
        />{' '}
        <label>
          <input checked={paste} onChange={ev => setPaste(ev.target.checked)} type='checkbox' />{' '}
          Bracketed paste
        </label>{' '}
        <button onClick={sendBox} type='button'>
          Send
        </button>
      </div>

      <div style={box}>
        <b>Start test session</b> {TEST_PREFIX}
        <input
          onChange={ev => setSuffix(ev.target.value)}
          placeholder='suffix'
          size={12}
          value={suffix}
        />{' '}
        <input
          onChange={ev => setExtraArgs(ev.target.value)}
          placeholder='extra args, for example --permission-mode plan'
          size={28}
          value={extraArgs}
        />{' '}
        <input
          onChange={ev => setPrompt(ev.target.value)}
          placeholder='prompt'
          size={40}
          value={prompt}
        />{' '}
        <button disabled={suffix.trim() === ''} onClick={() => void startTest()} type='button'>
          Start test session
        </button>
        {runOutput && <pre style={{ margin: '8px 0 0', whiteSpace: 'pre-wrap' }}>{runOutput}</pre>}
      </div>

      <div style={box}>
        <button onClick={startExternal} type='button'>
          Start external session
        </button>
      </div>

      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
        {views.map(v => (
          <div key={v.viewId} style={{ border: '1px solid #345', width: 640 }}>
            <div style={{ background: '#16202b', padding: '2px 6px' }}>
              {v.viewId} | {v.target} | {v.args.join(' ')}
              {v.hidden && <span> | hidden, {bytes[v.viewId] ?? 0} bytes</span>}{' '}
              <button onClick={() => removeView(v)} type='button'>
                Remove
              </button>
            </div>
            {!v.hidden && (
              <div style={{ height: 360 }}>
                <TerminalView args={v.args} cwd={v.cwd} viewId={v.viewId} />
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}
