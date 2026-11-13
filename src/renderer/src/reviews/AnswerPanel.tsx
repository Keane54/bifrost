// The Answer panel: the user answers the questions of Claude on one My PRs row, or says that
// they handle a comment themselves.
import { useEffect, useState } from 'react'
import { MAX_ANSWER, MAX_ANSWERS, type QuestionRow } from '../../../shared/reviews'
import { friendlyError } from '../actions/errors'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { useWmControls } from '../wm/context'
import { setAnswerKey, useAnswerKey } from './answer-key'
import { useReviews } from './use-reviews'

const INTRO =
  "Claude couldn't decide these on its own. Tell it what you'd like, or handle a comment yourself."

const TOO_MANY = 'Bifrost can send only a limited number of answers at a time'

const LINK =
  'shrink-0 cursor-pointer text-text underline transition-colors duration-150 hover:text-text-strong'

const BUTTON =
  'border border-panel-edge bg-black/35 px-2 leading-5 text-text hover:text-text-strong not-disabled:active:bg-accent/12 disabled:opacity-40'

// The header line of a quote, from the saved kind. With no kind or no author, the place only.
function quoteHeader(q: QuestionRow): string {
  if (q.author === undefined || q.kind === undefined) return q.where
  return q.kind === 'comment' ? `${q.author} on the PR` : `${q.author} on ${q.where}`
}

export default function AnswerPanel(): React.JSX.Element {
  const { dispatch } = useWmControls()
  const key = useAnswerKey()
  const snapshot = useReviews()
  const [answers, setAnswers] = useState<Record<string, string>>({})
  const [checks, setChecks] = useState<Record<string, boolean>>({})
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // The store holds the key only while the panel is open.
  useEffect(() => () => setAnswerKey(null), [])

  // Another PR starts with empty answers.
  // biome-ignore lint/correctness/useExhaustiveDependencies: key only resets the answers
  useEffect(() => {
    setAnswers({})
    setChecks({})
    setError(null)
  }, [key])

  const row = key === null ? undefined : snapshot.mine.find(r => r.key === key)
  const close = (): void => dispatch({ panelId: 'answer', type: 'close' })

  if (key === null || row === undefined || row.questions.length === 0) {
    return <p className='px-3 py-2 text-xs text-text-dim'>Nothing to answer right now.</p>
  }

  const tooMany = row.questions.length > MAX_ANSWERS
  const ready =
    !tooMany &&
    row.questions.every(q => checks[q.id] === true || (answers[q.id] ?? '').trim() !== '')

  // The main process finds the link. A refusal shows in the error line.
  const openComment = (itemId: string): void => {
    window.bifrost.reviews.openComment(row.key, itemId).catch((err: unknown) => {
      setError(friendlyError(errorMessage(err)))
    })
  }

  const send = (): void => {
    setError(null)
    setBusy(true)
    const list = row.questions.map(q => {
      const checked = checks[q.id] === true
      return { id: q.id, text: checked ? null : (answers[q.id] ?? '').trim() }
    })
    const reviews = window.bifrost.reviews
    reviews.answer(row.key, list).then(close, (err: unknown) => {
      setError(friendlyError(errorMessage(err)))
      setBusy(false)
    })
  }

  return (
    <div className='flex h-full min-h-0 flex-col text-xs'>
      <div className='min-h-0 flex-1 overflow-auto px-3 py-2'>
        <p className='text-text'>{INTRO}</p>
        {tooMany && <p className='mt-1.5 text-text-dim'>{`${TOO_MANY} (${MAX_ANSWERS})`}</p>}
        {row.lastError !== null && <p className='mt-1.5 text-text-dim'>{row.lastError}</p>}
        {row.questions.map(q => {
          const checked = checks[q.id] === true
          return (
            <div className='mt-3 flex flex-col gap-1' data-answer-question={q.id} key={q.id}>
              {q.body !== undefined && q.body.trim() !== '' ? (
                <div className='border-l-2 border-panel-edge bg-black/30 px-2 py-0.5 text-text'>
                  <div className='flex justify-between gap-2 text-text-dim'>
                    <span className='min-w-0 break-words'>{quoteHeader(q)}</span>
                    {q.url !== undefined && (
                      <button className={LINK} onClick={() => openComment(q.id)} type='button'>
                        View on GitHub
                      </button>
                    )}
                  </div>
                  <p className='break-words whitespace-pre-wrap'>{q.body}</p>
                </div>
              ) : (
                <p className='text-text-dim'>{q.where}</p>
              )}
              <p className='text-text-strong'>{q.question}</p>
              <textarea
                aria-label={`Answer for ${q.where}`}
                className={cx(
                  'min-h-14 resize-y border border-panel-edge bg-black/35 px-1.5 py-1 text-text',
                  'placeholder:text-text-dim disabled:opacity-40',
                )}
                disabled={checked}
                maxLength={MAX_ANSWER}
                onChange={e => setAnswers(a => ({ ...a, [q.id]: e.target.value }))}
                placeholder='Type your answer'
                value={answers[q.id] ?? ''}
              />
              <label className='flex items-center gap-1.5 text-text'>
                <input
                  checked={checked}
                  onChange={e => setChecks(c => ({ ...c, [q.id]: e.target.checked }))}
                  type='checkbox'
                />
                I'll handle this one myself
              </label>
            </div>
          )
        })}
      </div>
      <div className='flex shrink-0 justify-end gap-2 border-t border-panel-edge px-3 py-1.5'>
        <button className={BUTTON} onClick={close} type='button'>
          Cancel
        </button>
        <button
          className={cx(BUTTON, 'border-text-strong text-text-strong')}
          disabled={!ready || busy}
          onClick={send}
          type='button'
        >
          Send to Claude
        </button>
      </div>
      <ErrorLine message={error} onClose={() => setError(null)} />
    </div>
  )
}
