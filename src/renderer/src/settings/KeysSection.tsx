// Settings > Keys (spec 9.4): the list of all keys, with Change, Clear and Reset for each key.
import {
  formatForDisplay,
  type RecorderRejection,
  useHotkeyRecorder,
} from '@tanstack/react-hotkeys'
import { useEffect, useMemo, useRef, useState } from 'react'
import { flushSync } from 'react-dom'
import { resetSlotKey, setSlotKey } from '../../../shared/keys'
import { useConfirm } from '../actions/ConfirmDialog'
import { KEY_RECORDER_ATTR } from '../keys/focus-zone'
import { toRawChord } from '../keys/raw-chord'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { checkRecorded, type KeyRow, keyGroups } from './key-editor'
import { useRowSave } from './SettingRow'
import { useSettings } from './settings-context'

// The text for a key that the recorder refuses. The library gives a reason code, and a message
// only when the validate callback gave one.
const REJECTION_TEXT: Record<string, string> = {
  'alt-graph': 'This key press types a character. Try another key.',
  'missing-code': 'Bifrost cannot read this key. Try another key.',
  whitespace: 'A space key cannot be a shortcut. Try another key.',
}

function rejectionText(reason: RecorderRejection): string | null {
  return reason.message ?? REJECTION_TEXT[reason.reason] ?? null
}

const RESET_ALL_CONFIRM = {
  body: 'This puts every key back to its Bifrost default.',
  confirm: 'Reset all keys',
  title: 'Reset all keys',
}

const BUTTON =
  'h-5 shrink-0 border border-panel-edge px-2 text-text text-xs hover:bg-hover active:bg-accent/12 disabled:opacity-40 disabled:hover:bg-transparent'

// only: during a search, the slot IDs of the rows that show (spec 12). The text, Reset all keys
// and a group with no row then do not show.
export default function KeysSection({
  only = null,
}: {
  only?: ReadonlySet<string> | null
}): React.JSX.Element {
  const { settings, update } = useSettings()
  const confirm = useConfirm()
  const save = useRowSave()
  const custom = settings.keys
  const groups = useMemo(() => {
    const all = keyGroups(custom, settings.labels)
    if (only === null) return all
    return all
      .map(group => ({ ...group, rows: group.rows.filter(row => only.has(row.slot.id)) }))
      .filter(group => group.rows.length > 0)
  }, [custom, only, settings.labels])

  // The slot that records, the reason of the last rejected key and the row of the last failed save.
  const [activeId, setActiveId] = useState<string | null>(null)
  const [rejection, setRejection] = useState<string | null>(null)
  const [errorId, setErrorId] = useState<string | null>(null)
  // The error shows at the top for a change of all keys, and when a search hides the row of the
  // error. So a failed save never keeps Settings open with no error on the screen.
  const errorShownAtTop = errorId === null || (only !== null && !only.has(errorId))
  // The recorder callbacks read the newest values from this ref.
  const latest = useRef({ activeId, custom, labels: settings.labels })
  latest.current = { activeId, custom, labels: settings.labels }

  // Save a change. A failure shows its reason in the row of the slot (null: at the top).
  const change = (slotId: string | null, next: typeof custom): void => {
    setErrorId(slotId)
    void save.save(() => update({ keys: next }))
  }

  const recorder = useHotkeyRecorder({
    // The page, not the text field check of the library, decides what a zone takes.
    ignoreInputs: false,
    onCancel: () => setActiveId(null),
    onClear: () => {},
    onRecord: hotkey => {
      const { activeId: slotId, custom: current, labels } = latest.current
      setActiveId(null)
      if (slotId === null) return
      const result = checkRecorded(slotId, hotkey, current, labels)
      if (result.ok) change(slotId, setSlotKey(current, slotId, result.binding))
    },
    onReject: reason => setRejection(rejectionText(reason)),
    platform: 'mac',
    recordBy: 'code',
    // Tab and Shift+Tab are bindings of Bifrost. By default the library cancels at Tab.
    recordTab: true,
    validate: hotkey => {
      const { activeId: slotId, custom: current, labels } = latest.current
      if (slotId === null) return false
      const result = checkRecorded(slotId, hotkey, current, labels)
      return result.ok ? true : result.message
    },
  })

  // While the recorder records, the menu gives its keys to the page (Cmd+W must not close the
  // panel). The cleanup also ends it when the section closes.
  const { isRecording } = recorder
  useEffect(() => {
    if (!isRecording) return
    const tell = (on: boolean): void => {
      window.bifrost.settings
        .recording(on)
        .catch(err => console.error('Bifrost cannot tell the menu about the key recorder.', err))
    }
    tell(true)
    return () => tell(false)
  }, [isRecording])

  // The prompt takes the focus. So the recorder element is the focus target (ruling C4).
  const promptRef = useRef<HTMLButtonElement>(null)

  // Start a recording. flushSync shows the prompt at once, so the click handler gives it the
  // focus, not a later frame. The focus on the prompt also clears the hold gate (focusChange).
  const startChange = (slotId: string): void => {
    flushSync(() => {
      setRejection(null)
      setActiveId(slotId)
      recorder.startRecording()
    })
    promptRef.current?.focus()
  }

  const resetAll = (): void => {
    void confirm(RESET_ALL_CONFIRM).then(ok => {
      if (ok) change(null, {})
    })
  }

  const renderRow = ({ binding, changed, label, slot }: KeyRow): React.JSX.Element => {
    const recording = isRecording && activeId === slot.id
    return (
      <li
        className='flex flex-col border-b border-panel-edge'
        data-key-slot={slot.id}
        key={slot.id}
      >
        <div className='flex min-h-7 items-center gap-2 px-3 text-xs text-text'>
          {/* A narrow frame cuts the name. The title shows the full name. */}
          <span className='min-w-0 flex-1 truncate' data-key-name={true} title={label}>
            {label}
          </span>
          {changed && <span aria-hidden={true} className='size-1.5 shrink-0 bg-text-strong' />}
          {binding === null ? (
            <span className='shrink-0 text-text-dim'>No key</span>
          ) : (
            <kbd className='shrink-0 font-mono'>
              {formatForDisplay(toRawChord(binding) ?? { key: binding }, { platform: 'mac' })}
            </kbd>
          )}
          {/* A click on Change during the recording blurs the prompt first, and the blur
              cancels. So Change always starts a new recording. Esc cancels. */}
          <button className={BUTTON} onClick={() => startChange(slot.id)} type='button'>
            Change
          </button>
          <button
            className={BUTTON}
            disabled={binding === null}
            onClick={() => change(slot.id, setSlotKey(custom, slot.id, null))}
            type='button'
          >
            Clear
          </button>
          <button
            className={BUTTON}
            disabled={!changed}
            onClick={() => change(slot.id, resetSlotKey(custom, slot.id))}
            type='button'
          >
            Reset
          </button>
        </div>
        {/* The prompt has its own line under the name. So in a narrow frame the name stays
            visible, and Clear and Reset stay in the frame (M5a carry-over 2). */}
        {recording && (
          <div className='px-3 pb-1'>
            <button
              className='max-w-full border border-text-strong/30 px-1.5 py-0.5 text-left text-xs text-text-strong outline-none'
              {...{ [KEY_RECORDER_ATTR]: true }}
              onBlur={() => recorder.cancelRecording()}
              ref={promptRef}
              type='button'
            >
              Press the new shortcut. Esc cancels.
            </button>
          </div>
        )}
        {recording && rejection !== null && (
          <p className='px-3 pb-1 text-xs text-text-dim'>{rejection}</p>
        )}
        {errorId === slot.id && !errorShownAtTop && (
          <ErrorLine message={save.error} onClose={save.closeError} />
        )}
      </li>
    )
  }

  return (
    <div className='flex flex-col'>
      {only === null && (
        <div className='flex items-start gap-3 px-3 py-2'>
          <p className='min-w-0 flex-1 text-xs text-text-dim'>
            You can't record Esc or a plain Backspace, because the recorder uses them. Reset brings
            back the default key.
          </p>
          <button className={BUTTON} onClick={resetAll} type='button'>
            Reset all keys
          </button>
        </div>
      )}
      {errorShownAtTop && <ErrorLine message={save.error} onClose={save.closeError} />}
      {groups.map(group => (
        <section data-key-group={group.group} key={group.group}>
          <h3 className={cx('border-y border-panel-edge bg-title px-3 py-1 text-xs text-text-dim')}>
            {group.title}
          </h3>
          <ul className='flex flex-col'>{group.rows.map(renderRow)}</ul>
        </section>
      ))}
    </div>
  )
}
