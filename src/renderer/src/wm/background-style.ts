// The animated background (spec 8.10). This module is pure.
import { cx } from '../lib/cx'

// The number of colour fields. app.css has one rule and one animation for each field.
export const BACKGROUND_FIELDS = 6

// The class of the background layer. With the Animated background setting off, the fields stay
// still, as with reduced motion.
export function backgroundClass(animated: boolean): string {
  return cx('background', !animated && 'background-still')
}
