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
import { useTrustRepo } from './trust-repo'

const MIN_SIDE = 2
const MAX_SIDE = 500

function clampSide(n: number): number {
  return Math.min(MAX_SIDE, Math.max(MIN_SIDE, Math.floor(n)))
}

export default function TrustPanel(): React.JSX.Element {
  const { dispatch } = useWmControls()
  const { settings } = useSettings()
  const repo = useTrustRepo()
  const host = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const [closedEarly, setClosedEarly] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const font = settings.terminalFont ?? DEFAULT_SETTINGS.terminalFont
  // The first terminal reads the font here. A font change applies below, so the prompt stays.
  const fontRef = useRef(font)

  useEffect(() => {
    const el = host.current
    if (el === null) return
    const style = getComputedStyle(document.documentElement)
    const theme = terminalTheme(name => style.getPropertyValue(name))
    // The trust prompt has no link that Bifrost opens.
    const term = new Terminal(terminalOptions(fontRef.current, theme, () => {}))
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(el)
    termRef.current = term
    const api = window.bifrost.reviews
    const report = (job: Promise<void>): void => {
      job.catch((err: unknown) => console.warn(`Bifrost trust: ${errorMessage(err)}`))
    }
    const sendSize = (): void => {
      fit.fit()
      report(api.trustResize(clampSide(term.cols), clampSide(term.rows)))
    }
    const offData = api.onTrustData(chunk => term.write(chunk))
    const offEnd = api.onTrustEnd(end => {
      if (end.repo !== repo) return
      if (end.trusted) dispatch({ panelId: 'trust', type: 'close' })
      else setClosedEarly(true)
    })
    const input = term.onData(data => report(api.trustWrite(data)))
    const observer = new ResizeObserver(() => sendSize())
    observer.observe(el)
    sendSize()
    return () => {
      observer.disconnect()
      input.dispose()
      offData()
      offEnd()
      termRef.current = null
      term.dispose()
      report(api.trustClose())
    }
  }, [dispatch, repo])

  useEffect(() => {
    fontRef.current = font
    const term = termRef.current
    if (term === null) return
    term.options.fontFamily = terminalOptions(font, {}, () => {}).fontFamily
    term.options.fontSize = font.size
  }, [font])

  const retry = (): void => {
    if (repo === null) return
    setClosedEarly(false)
    setError(null)
    window.bifrost.reviews.trust(repo).catch((err: unknown) => {
      setClosedEarly(true)
      setError(friendlyError(errorMessage(err)))
    })
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
