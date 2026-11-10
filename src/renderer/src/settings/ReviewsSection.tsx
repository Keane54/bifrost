// Settings > Reviews: the watch of GitHub, its limits and the list of repositories to ignore.
// A row saves on change. The ignore list works like the list of slash commands.
import { X } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import type { ModelChoice } from '../../../shared/new-session'
import { MAX_REVIEWS_IGNORE } from '../../../shared/settings'
import { useConfirm } from '../actions/ConfirmDialog'
import type { ConfirmText } from '../actions/confirm'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { addIgnore, removeIgnore } from './reviews-ignore'
import { REVIEWS_ROWS } from './reviews-rows'
import { RowFilterContext, useRowShown } from './row-filter'
import { CheckRow, NumberRow, SelectRow } from './rows'
import { ROW_FIELD, SettingRow, useRowSave } from './SettingRow'
import { useSaveTracker } from './save-context'
import { useSettings } from './settings-context'

// Each turn-on of Watch GitHub asks first.
const WATCH_CONFIRM: ConfirmText = {
  body: 'Bifrost will use your gh login to check your review requests and your pull requests every few minutes. It only reads for now. Later versions can start Claude sessions that reply on your PRs and draft reviews, and only when you turn those on.',
  confirm: 'Turn on',
  title: 'Watch GitHub?',
}

// The minutes that Pause time and the poll interval offer. They match the settings checks.
const PAUSE_CHOICES = [15, 30, 60, 120, 240, 480] as const
const POLL_CHOICES = [1, 2, 5, 10] as const

// The hint of a row that saves but has no effect in R1.
const LATER = 'Comes in a later version.'

const MODEL_CHOICES: { label: string; value: string }[] = [
  { label: 'Claude Code default', value: '' },
  { label: 'Opus', value: 'opus' },
  { label: 'Sonnet', value: 'sonnet' },
  { label: 'Haiku', value: 'haiku' },
]

function minutesText(minutes: number): string {
  if (minutes < 60) return `${minutes} minutes`
  const hours = minutes / 60
  return hours === 1 ? '1 hour' : `${hours} hours`
}

// A select of a model. The empty value means the default model of Claude Code.
function ModelRow(props: {
  label: string
  value: string
  hint?: string
  save(value: string): Promise<void>
}): React.JSX.Element {
  const row = useRowSave(props.label)
  const { save } = props
  return (
    <SettingRow
      error={row.error}
      hint={props.hint}
      label={props.label}
      onCloseError={row.closeError}
    >
      <select
        aria-label={props.label}
        className={ROW_FIELD}
        onChange={e => {
          const value = e.target.value
          row.save(() => save(value))
        }}
        value={props.value}
      >
        {MODEL_CHOICES.map(choice => (
          <option key={choice.value} value={choice.value}>
            {choice.label}
          </option>
        ))}
      </select>
    </SettingRow>
  )
}

// The row of the ignore list: a field with an Add button, and the entries under it. A bad entry
// shows its reason under the field.
function IgnoreRow(): React.JSX.Element | null {
  const { settings, update } = useSettings()
  const list = settings.reviewsIgnore
  const [text, setText] = useState('')
  const [reason, setReason] = useState<string | null>(null)
  const row = useRowSave(REVIEWS_ROWS.ignore)
  const shown = useRowShown(REVIEWS_ROWS.ignore)

  // Save the new list. A rejected save shows its reason and keeps the old list.
  const change = (next: string[]): Promise<boolean> =>
    row.save(() => update({ reviewsIgnore: next }))

  // Add the typed entry. The result is true when the entry saved.
  const add = (): Promise<boolean> => {
    const result = addIgnore(list, text)
    if (!result.ok) {
      setReason(result.reason)
      return Promise.resolve(false)
    }
    setReason(null)
    return change(result.list).then(ok => {
      if (ok) setText('')
      return ok
    })
  }

  // The Save button of the Settings panel adds a typed entry, as Add does (spec 12).
  // The draft reads the newest text and add from this ref.
  const tracker = useSaveTracker()
  const latest = useRef({ add, text })
  latest.current = { add, text }
  useEffect(
    () =>
      tracker?.addDraft(() => (latest.current.text.trim() === '' ? null : latest.current.add())),
    [tracker],
  )

  if (!shown) return null
  return (
    <div className='border-b border-panel-edge' data-setting-row={REVIEWS_ROWS.ignore}>
      <div className='flex min-h-7 items-center justify-between gap-3 px-3'>
        <span className='shrink-0 text-xs text-text'>{REVIEWS_ROWS.ignore}</span>
        <div className='flex min-w-0 items-center justify-end gap-2 text-xs text-text'>
          <input
            aria-label='New repository to ignore'
            className={cx(ROW_FIELD, 'w-44')}
            onChange={e => {
              setText(e.target.value)
              setReason(null)
            }}
            onKeyDown={e => {
              if (e.key === 'Enter') void add()
            }}
            placeholder='owner/repo or owner/*'
            spellCheck={false}
            value={text}
          />
          <button
            className='h-5 shrink-0 border border-panel-edge px-2 text-xs text-text hover:bg-hover active:bg-accent/12 disabled:opacity-40'
            disabled={list.length >= MAX_REVIEWS_IGNORE}
            onClick={() => void add()}
            type='button'
          >
            Add
          </button>
        </div>
      </div>
      {reason !== null && <p className='px-3 pb-1 text-xs text-text-dim'>{reason}</p>}
      <ul className='flex flex-col' data-reviews-ignore-list={true}>
        {list.map((entry, index) => (
          <li
            className='flex min-h-7 items-center gap-1 border-t border-panel-edge px-3 text-xs text-text'
            data-reviews-ignore-item={entry}
            key={entry}
          >
            <span className='min-w-0 flex-1 truncate'>{entry}</span>
            <button
              aria-label={`Remove ${entry}`}
              className='flex size-5 shrink-0 items-center justify-center text-text-dim hover:bg-hover hover:text-text active:bg-accent/12'
              onClick={() => void change(removeIgnore(list, index))}
              title='Remove'
              type='button'
            >
              <X aria-hidden={true} size={14} />
            </button>
          </li>
        ))}
      </ul>
      <ErrorLine message={row.error} onClose={row.closeError} />
    </div>
  )
}

// only: during a search, the labels of the rows that show (spec 12).
// The filter provider is in this component, above ReviewsRows, so each useRowSave call is below it.
export default function ReviewsSection({
  only = null,
}: {
  only?: ReadonlySet<string> | null
}): React.JSX.Element {
  return (
    <RowFilterContext value={only}>
      <ReviewsRows />
    </RowFilterContext>
  )
}

// The rows of Settings > Reviews, below the filter provider of ReviewsSection.
function ReviewsRows(): React.JSX.Element {
  const { settings, update } = useSettings()
  const confirm = useConfirm()
  return (
    <div className='flex min-h-full flex-col'>
      <CheckRow
        checked={settings.reviewsWatch}
        label={REVIEWS_ROWS.watch}
        save={async value => {
          // Each turn-on asks first. A Cancel saves nothing.
          if (value && !settings.reviewsWatch) {
            if (!(await confirm(WATCH_CONFIRM))) return
            await update({ reviewsWatch: true })
            return
          }
          await update({ reviewsWatch: value })
        }}
      />
      {/* These settings save, but they have no effect in R1: automatic comments, the maximum
          PR sessions and the two models. */}
      <CheckRow
        checked={settings.reviewsAutoFix}
        hint={LATER}
        label={REVIEWS_ROWS.autoFix}
        save={value => update({ reviewsAutoFix: value })}
      />
      <CheckRow
        checked={settings.reviewsTeamRequests}
        label={REVIEWS_ROWS.teamRequests}
        save={value => update({ reviewsTeamRequests: value })}
      />
      <NumberRow
        hint={LATER}
        label={REVIEWS_ROWS.maxSessions}
        max={10}
        min={1}
        save={value => update({ reviewsMaxSessions: value })}
        unit='sessions'
        value={settings.reviewsMaxSessions}
      />
      <SelectRow
        choices={PAUSE_CHOICES}
        label={REVIEWS_ROWS.pauseTime}
        save={value => update({ reviewsPauseMinutes: value })}
        text={minutesText}
        value={settings.reviewsPauseMinutes}
      />
      <SelectRow
        choices={POLL_CHOICES}
        label={REVIEWS_ROWS.pollInterval}
        save={value => update({ reviewsPollMinutes: value })}
        text={minutes => (minutes === 1 ? '1 minute' : `${minutes} minutes`)}
        value={settings.reviewsPollMinutes}
      />
      <ModelRow
        hint={LATER}
        label={REVIEWS_ROWS.requestModel}
        save={value => update({ reviewsRequestModel: value as ModelChoice })}
        value={settings.reviewsRequestModel}
      />
      <ModelRow
        hint={LATER}
        label={REVIEWS_ROWS.reviewModel}
        save={value => update({ reviewsReviewModel: value as ModelChoice })}
        value={settings.reviewsReviewModel}
      />
      <IgnoreRow />
    </div>
  )
}
