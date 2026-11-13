// The PR number on line 1 of a review row. It is a link to the PR on GitHub, so it shows a
// pointer, an underline and a brighter colour on hover.
import type React from 'react'

export const PR_NUMBER_LINK =
  'shrink-0 cursor-pointer text-text-dim transition-colors duration-150 hover:text-text hover:underline'

export function PrNumber({
  number,
  onOpen,
}: {
  number: number
  onOpen: () => void
}): React.JSX.Element {
  return (
    <button
      aria-label={`Open PR #${number} on GitHub`}
      className={PR_NUMBER_LINK}
      onClick={e => {
        // The row under the number has its own click action (it opens the chat or the Answer
        // panel), so the click must stop here.
        e.stopPropagation()
        onOpen()
      }}
      type='button'
    >
      #{number}
    </button>
  )
}
