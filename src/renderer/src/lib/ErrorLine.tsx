// One line at the bottom of a panel that shows an error. A null message shows nothing.
// The text is not red, because red is only for the red box (spec 8.10).
export function ErrorLine({ message }: { message: string | null }): React.JSX.Element | null {
  if (message === null) return null
  return (
    <p
      className='shrink-0 truncate border-panel-edge border-t px-2 text-text text-xs'
      data-error-line={true}
      title={message}
    >
      Error: {message}
    </p>
  )
}
