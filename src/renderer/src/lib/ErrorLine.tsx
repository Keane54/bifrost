// The text at the bottom of a panel that shows an error. A null message shows nothing.
// The text is not red, because red is only for the red box (spec 8.10).
// It shows only the friendly text, with no prefix. A long text wraps to more lines (Task 15).
export function ErrorLine({ message }: { message: string | null }): React.JSX.Element | null {
  if (message === null) return null
  return (
    <p
      className='wrap-break-word shrink-0 border-panel-edge border-t px-2 text-text text-xs'
      data-error-line={true}
    >
      {message}
    </p>
  )
}

// The text at the bottom of a panel that shows a notice of an action. A null message shows
// nothing. A long text wraps to more lines.
export function NoticeLine({ message }: { message: string | null }): React.JSX.Element | null {
  if (message === null) return null
  return (
    <p
      className='wrap-break-word shrink-0 border-panel-edge border-t px-2 text-text-dim text-xs'
      data-notice-line={true}
    >
      {message}
    </p>
  )
}
