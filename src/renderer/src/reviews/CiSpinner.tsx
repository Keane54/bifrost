// The spinner beside "CI running" on a To review row. It turns slowly. With the Reduce motion
// setting of the system it stays still, and the arc shows the same icon. The text beside it says
// the state, so the icon is hidden from screen readers.
import { cx } from '../lib/cx'

export function CiSpinner(): React.JSX.Element {
  return (
    <svg
      aria-hidden={true}
      className={cx('size-2.5 shrink-0 animate-spin motion-reduce:animate-none')}
      data-ci-spinner={true}
      fill='none'
      viewBox='0 0 16 16'
    >
      <circle cx='8' cy='8' opacity='0.25' r='6' stroke='currentColor' strokeWidth='2' />
      <path d='M8 2a6 6 0 0 1 6 6' stroke='currentColor' strokeLinecap='square' strokeWidth='2' />
    </svg>
  )
}
