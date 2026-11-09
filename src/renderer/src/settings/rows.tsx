// The rows that two or more sections of the Settings panel share: a field with a draft, a number
// row, a check row and a select row. A row saves on change, or on Enter and on blur for a field.
// A rejected save shows its reason in the row and puts back the old value.
import { useEffect, useState } from 'react'
import { CheckBox } from '../lib/CheckBox'
import { cx } from '../lib/cx'
import { draftToSave } from './draft'
import { ROW_FIELD, SettingRow, useRowSave } from './SettingRow'

// A field with a draft. Enter blurs the field, and the blur saves the trimmed text. The draft goes
// back to the saved value when the save is rejected, or when the trimmed text did not change.
export function DraftField(props: {
  label: string
  value: string
  type: 'number' | 'text'
  width: string
  list?: string
  min?: number
  max?: number
  // Resolves true when the value saved.
  onCommit(text: string): Promise<boolean>
}): React.JSX.Element {
  const [draft, setDraft] = useState(props.value)
  useEffect(() => setDraft(props.value), [props.value])
  const { onCommit } = props
  return (
    <input
      aria-label={props.label}
      className={cx(ROW_FIELD, props.width)}
      list={props.list}
      max={props.max}
      min={props.min}
      onBlur={() => {
        const text = draftToSave(draft, props.value)
        if (text === null) {
          setDraft(props.value)
          return
        }
        onCommit(text).then(ok => {
          if (!ok) setDraft(props.value)
        })
      }}
      onChange={e => setDraft(e.target.value)}
      onKeyDown={e => {
        if (e.key === 'Enter') e.currentTarget.blur()
        if (e.key === 'Escape') {
          setDraft(props.value)
          e.stopPropagation()
        }
      }}
      spellCheck={false}
      type={props.type}
      value={draft}
    />
  )
}

// A number field that saves a whole number. Text that is not a number gives a reason.
export function NumberRow(props: {
  label: string
  value: number
  min: number
  max: number
  unit: string
  hint?: string
  save(value: number): Promise<void>
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
      <DraftField
        label={props.label}
        max={props.max}
        min={props.min}
        onCommit={async text => {
          const n = Number(text)
          if (text.trim() === '' || !Number.isInteger(n)) {
            return row.save(() =>
              Promise.reject(new Error(`Enter a whole number from ${props.min} to ${props.max}.`)),
            )
          }
          return row.save(() => save(n))
        }}
        type='number'
        value={String(props.value)}
        width='w-16'
      />
      <span className='text-text-dim'>{props.unit}</span>
    </SettingRow>
  )
}

export function CheckRow(props: {
  label: string
  checked: boolean
  disabled?: boolean
  hint?: string
  save(value: boolean): Promise<void>
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
      <CheckBox
        ariaLabel={props.label}
        checked={props.checked}
        disabled={props.disabled}
        label={props.checked ? 'On' : 'Off'}
        onChange={value => {
          row.save(() => save(value))
        }}
      />
    </SettingRow>
  )
}

// A select of numbers that saves on change.
export function SelectRow(props: {
  label: string
  value: number
  choices: readonly number[]
  text(value: number): string
  save(value: number): Promise<void>
}): React.JSX.Element {
  const row = useRowSave(props.label)
  const { save } = props
  return (
    <SettingRow error={row.error} label={props.label} onCloseError={row.closeError}>
      <select
        aria-label={props.label}
        className={ROW_FIELD}
        onChange={e => {
          const value = Number(e.target.value)
          row.save(() => save(value))
        }}
        value={String(props.value)}
      >
        {props.choices.map(value => (
          <option key={value} value={String(value)}>
            {props.text(value)}
          </option>
        ))}
      </select>
    </SettingRow>
  )
}
