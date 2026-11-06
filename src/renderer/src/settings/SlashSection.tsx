// Settings > Slash commands (spec 9.6): the list of the slash favourites.
import { ChevronDown, ChevronUp, X } from 'lucide-react'
import { useState } from 'react'
import { MAX_SLASH_COMMANDS } from '../../../shared/settings'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { Tip } from '../lib/menu'
import { ROW_FIELD, useRowSave } from './SettingRow'
import { useSettings } from './settings-context'
import { addSlash, moveSlash, removeSlash } from './slash-list'

const ICON_BUTTON =
  'flex size-5 shrink-0 items-center justify-center text-text-dim hover:bg-hover hover:text-text active:bg-accent/12 disabled:opacity-40 disabled:hover:bg-transparent'

function IconButton(props: {
  label: string
  disabled?: boolean
  onClick(): void
  children: React.ReactNode
}): React.JSX.Element {
  return (
    <Tip label={props.label}>
      <button
        aria-label={props.label}
        className={ICON_BUTTON}
        disabled={props.disabled}
        onClick={props.onClick}
        type='button'
      >
        {props.children}
      </button>
    </Tip>
  )
}

export default function SlashSection(): React.JSX.Element {
  const { settings, update } = useSettings()
  const list = settings.slashCommands
  const [text, setText] = useState('')
  const [reason, setReason] = useState<string | null>(null)
  const row = useRowSave()

  // Save the new list. A rejected save shows its reason and keeps the old list.
  const change = (next: string[]): Promise<boolean> =>
    row.save(() => update({ slashCommands: next }))

  const add = (): void => {
    const result = addSlash(list, text)
    if (!result.ok) {
      setReason(result.reason)
      return
    }
    setReason(null)
    change(result.list).then(ok => {
      if (ok) setText('')
    })
  }

  return (
    <div className='flex flex-col'>
      <p className='px-3 py-2 text-text-dim text-xs'>
        These commands show in the Slash commands menu of a session. Put the ones you use most at
        the top.
      </p>
      <ul className='flex flex-col' data-slash-list={true}>
        {list.map((command, index) => (
          <li
            className='flex min-h-7 items-center gap-1 border-panel-edge border-b px-3 text-text text-xs'
            data-slash-item={command}
            key={command}
          >
            <span className='min-w-0 flex-1 truncate'>{command}</span>
            <IconButton
              disabled={index === 0}
              label='Move up'
              onClick={() => change(moveSlash(list, index, -1))}
            >
              <ChevronUp aria-hidden={true} size={14} />
            </IconButton>
            <IconButton
              disabled={index === list.length - 1}
              label='Move down'
              onClick={() => change(moveSlash(list, index, 1))}
            >
              <ChevronDown aria-hidden={true} size={14} />
            </IconButton>
            <IconButton label='Remove' onClick={() => change(removeSlash(list, index))}>
              <X aria-hidden={true} size={14} />
            </IconButton>
          </li>
        ))}
        {list.length === 0 && <li className='px-3 py-1 text-text-dim text-xs'>No commands yet.</li>}
      </ul>
      <div className='flex items-center gap-2 px-3 py-2'>
        <input
          aria-label='New slash command'
          className={cx(ROW_FIELD, 'flex-1')}
          onChange={e => {
            setText(e.target.value)
            setReason(null)
          }}
          onKeyDown={e => {
            if (e.key === 'Enter') add()
          }}
          placeholder='/command'
          spellCheck={false}
          value={text}
        />
        <button
          className='h-5 shrink-0 border border-panel-edge px-2 text-text text-xs hover:bg-hover active:bg-accent/12 disabled:opacity-40'
          disabled={list.length >= MAX_SLASH_COMMANDS}
          onClick={add}
          type='button'
        >
          Add
        </button>
      </div>
      {reason !== null && <p className='px-3 pb-2 text-text-dim text-xs'>{reason}</p>}
      <ErrorLine message={row.error} onClose={row.closeError} />
    </div>
  )
}
