// The class lookups of the watch colours. Tailwind finds only full class names in the source.
// So these lookups hold full names. The tokens are in styles/app.css.
import type { WatchColour } from '../../../shared/types'

// The row background: the watch colour at 12%.
export const WATCH_ROW_BG: Record<WatchColour, string> = {
  amber: 'bg-watch-amber/12',
  'dark-blue': 'bg-watch-dark-blue/12',
  'dark-red': 'bg-watch-dark-red/12',
  green: 'bg-watch-green/12',
  'light-blue': 'bg-watch-light-blue/12',
  red: 'bg-watch-red/12',
  white: 'bg-watch-white/12',
  yellow: 'bg-watch-yellow/12',
}

// The small square of a colour in the colour menu.
export const WATCH_SWATCH: Record<WatchColour, string> = {
  amber: 'bg-watch-amber',
  'dark-blue': 'bg-watch-dark-blue',
  'dark-red': 'bg-watch-dark-red',
  green: 'bg-watch-green',
  'light-blue': 'bg-watch-light-blue',
  red: 'bg-watch-red',
  white: 'bg-watch-white',
  yellow: 'bg-watch-yellow',
}

// The stripe at the left edge of a watched row, in the full watch colour. The row background is
// only a faint tint, so the stripe shows the exact colour. An inset shadow stays on top of the
// background of the same cell, so the selection and the hover do not cover it. It is 3 px wide.
// The cell has 4 px of padding, so the stripe does not touch the icon or its box.
export const WATCH_STRIPE: Record<WatchColour, string> = {
  amber: '*:first:shadow-[inset_3px_0_0_var(--color-watch-amber)]',
  'dark-blue': '*:first:shadow-[inset_3px_0_0_var(--color-watch-dark-blue)]',
  'dark-red': '*:first:shadow-[inset_3px_0_0_var(--color-watch-dark-red)]',
  green: '*:first:shadow-[inset_3px_0_0_var(--color-watch-green)]',
  'light-blue': '*:first:shadow-[inset_3px_0_0_var(--color-watch-light-blue)]',
  red: '*:first:shadow-[inset_3px_0_0_var(--color-watch-red)]',
  white: '*:first:shadow-[inset_3px_0_0_var(--color-watch-white)]',
  yellow: '*:first:shadow-[inset_3px_0_0_var(--color-watch-yellow)]',
}
