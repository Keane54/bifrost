// The animated background (spec 8.10). It is one layer behind all frames and the side bar. It
// holds soft colour fields of the app icon colours. app.css draws the fields and moves them
// slowly. The motion stops with reduced motion and when the Animated background setting is off.
import { useSettings } from '../settings/settings-context'
import { BACKGROUND_FIELDS, backgroundClass } from './background-style'

const FIELDS = Array.from({ length: BACKGROUND_FIELDS }, (_, i) => i)

export default function Background(): React.JSX.Element {
  const { settings } = useSettings()
  return (
    <div aria-hidden={true} className={backgroundClass(settings.animatedBackground)}>
      {FIELDS.map(i => (
        <div className='background-field' key={i} />
      ))}
    </div>
  )
}
