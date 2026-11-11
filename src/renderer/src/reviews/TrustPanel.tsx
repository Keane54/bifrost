// The trust terminal: it shows the real Claude Code trust prompt. The user answers it.
// Bifrost never types into the terminal for the user.
import { FitAddon } from '@xterm/addon-fit'
import { Terminal } from '@xterm/xterm'
import { useEffect, useRef, useState } from 'react'
import { DEFAULT_SETTINGS } from '../../../shared/settings'
import { friendlyError } from '../actions/errors'
import { terminalOptions, terminalTheme } from '../chat/terminal-options'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { useSettings } from '../settings/settings-context'
import { useWmControls } from '../wm/context'
import { setTrustRepo, useTrustRepo } from './trust-repo'
import { clampSide, startTrustSession } from './trust-session'

export default function TrustPanel(): React.JSX.Element {
  const { dispatch } = useWmControls()
  const { settings } = useSettings()
  const repo = useTrustRepo()
  const host = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const [closedEarly, setClosedEarly] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // Each retry runs the session effect again.
  const [attempt, setAttempt] = useState(0)
  const font = settings.terminalFont ?? DEFAULT_SETTINGS.terminalFont
  // The first terminal reads the font here. A font change applies below, so the prompt stays.
  const fontRef = useRef(font)

  // The store holds the repository only while the panel is open.
  useEffect(() => () => setTrustRepo(null), [])

  // biome-ignore lint/correctness/useExhaustiveDependencies: attempt only restarts the session
  useEffect(() => {
    const el = host.current
    if (el === null || repo === null) return
    const style = getComputedStyle(document.documentElement)
    const theme = terminalTheme(name => style.getPropertyValue(name))
    // The trust prompt has no link that Bifrost opens. A new terminal starts with a clean screen.
    const term = new Terminal(terminalOptions(fontRef.current, theme, () => {}))
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(el)
    termRef.current = term
    const api = window.bifrost.reviews
    const fail = (err: unknown): void => {
      setError(friendlyError(errorMessage(err)))
      setClosedEarly(true)
    }
    const size = (): { cols: number; rows: number } => {
      fit.fit()
      return { cols: clampSide(term.cols), rows: clampSide(term.rows) }
    }
    const close = startTrustSession({
      api,
      getSize: size,
      onData: chunk => term.write(chunk),
      onEnd: trusted => {
        if (trusted) dispatch({ panelId: 'trust', type: 'close' })
        else setClosedEarly(true)
      },
      onError: fail,
      repo,
    })
    const input = term.onData(data => {
      api.trustWrite(data).catch(fail)
    })
    const observer = new ResizeObserver(() => {
      const { cols, rows } = size()
      api.trustResize(cols, rows).catch(() => {})
    })
    observer.observe(el)
    return () => {
      observer.disconnect()
      input.dispose()
      close()
      termRef.current = null
      term.dispose()
    }
  }, [dispatch, repo, attempt])

  useEffect(() => {
    fontRef.current = font
    const term = termRef.current
    if (term === null) return
    term.options.fontFamily = terminalOptions(font, {}, () => {}).fontFamily
    term.options.fontSize = font.size
  }, [font])

  const retry = (): void => {
    setClosedEarly(false)
    setError(null)
    setAttempt(n => n + 1)
  }

  if (repo === null) {
    return (
      <p className='px-3 py-2 text-xs text-text-dim'>
        Pick a repository with the Trust button in the Reviews panel.
      </p>
    )
  }

  return (
    <div className='flex h-full min-h-0 flex-col'>
      <p className='shrink-0 px-3 py-1.5 text-xs text-text-dim'>
        Claude Code asks if you trust this folder. Accept it below. Bifrost then closes this window
        and starts any review that's waiting.
      </p>
      {closedEarly && (
        <div className='flex shrink-0 items-center gap-2 px-3 pb-1.5 text-xs'>
          <span className='text-text'>Claude Code closed before the folder was trusted.</span>
          <button
            className={cx(
              'border border-panel-edge bg-black/35 px-1.5 leading-4 text-text',
              'hover:text-text-strong active:bg-accent/12',
            )}
            onClick={retry}
            type='button'
          >
            Try again
          </button>
        </div>
      )}
      <div className='min-h-0 flex-1 px-2 pb-2' data-trust-terminal={true} ref={host} />
      <ErrorLine message={error} onClose={() => setError(null)} />
    </div>
  )
}
