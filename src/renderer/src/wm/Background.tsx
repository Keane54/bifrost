// The animated background (spec 8.10). It is one layer behind all frames and the side bar. It
// holds soft colour fields of the app icon colours. app.css draws the fields and moves them
// slowly. The motion pauses while the window does not have the focus or the page is hidden, and
// when the Animated background setting goes off. With reduced motion, or with the setting off at
// the start, the fields stay at their still position.
import { useEffect, useState } from 'react'
import { useSettings } from '../settings/settings-context'
import {
  BACKGROUND_FIELDS,
  backgroundClass,
  backgroundMotion,
  windowActive,
} from './background-style'

const FIELDS = Array.from({ length: BACKGROUND_FIELDS }, (_, i) => i)

// True while the window has the focus and the page is visible. The window focus and blur events
// follow the key window of macOS in Electron. No main process message is necessary.
function useWindowActive(): boolean {
  const [active, setActive] = useState(() => windowActive(document))
  useEffect(() => {
    const update = (): void => setActive(windowActive(document))
    window.addEventListener('focus', update)
    window.addEventListener('blur', update)
    document.addEventListener('visibilitychange', update)
    update()
    return () => {
      window.removeEventListener('focus', update)
      window.removeEventListener('blur', update)
      document.removeEventListener('visibilitychange', update)
    }
  }, [])
  return active
}

export default function Background(): React.JSX.Element {
  const { settings, ready } = useSettings()
  // The settings are the defaults until the first get resolves. So a setting that is off at the
  // start does not count as a change from on to off.
  const animated = ready && settings.animatedBackground
  const [ran, setRan] = useState(false)
  useEffect(() => {
    if (animated) setRan(true)
  }, [animated])
  const active = useWindowActive()
  return (
    <div
      aria-hidden={true}
      className={backgroundClass(backgroundMotion({ active, animated, ran: ran || animated }))}
    >
      {FIELDS.map(i => (
        <div className='background-field' key={i} />
      ))}
    </div>
  )
}
