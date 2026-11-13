// The draft of a work area as React elements. The draft text comes from a Claude run, so it never
// goes into the page as HTML. A **bold** part shows in bold. Each line of the draft is one line.
import { draftParts } from '../../../shared/daily-markup'
import { cx } from '../lib/cx'

export default function DraftView({ draft }: { draft: string }): React.JSX.Element {
  return (
    <div
      className={cx(
        'border border-panel-edge bg-black/35 px-2 py-1.5',
        'text-xs leading-5 text-text select-text',
      )}
      data-daily-draft={true}
    >
      {draftParts(draft).map((line, i) => (
        // biome-ignore lint/suspicious/noArrayIndexKey: lines are plain text with no ID
        <p className='min-h-5 wrap-break-word whitespace-pre-wrap' key={i}>
          {line.map((part, j) =>
            part.bold ? (
              // biome-ignore lint/suspicious/noArrayIndexKey: parts are plain text with no ID
              <strong className='font-semibold text-text-strong' key={j}>
                {part.text}
              </strong>
            ) : (
              // biome-ignore lint/suspicious/noArrayIndexKey: parts are plain text with no ID
              <span key={j}>{part.text}</span>
            ),
          )}
        </p>
      ))}
    </div>
  )
}
