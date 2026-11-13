// Settings > Daily update: the ticket source, the times, the format and the work areas.
// A row saves on change. The page checks the whole value with checkDailyUpdate before it saves,
// and shows the reason under the field when the value is not good.
import { useEffect, useState } from 'react'
import {
  checkDailyUpdate,
  type DailyUpdateSettings,
  type McpInventory,
  type WorkArea,
} from '../../../shared/daily-update'
import type { ModelChoice } from '../../../shared/new-session'
import { CheckBox } from '../lib/CheckBox'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import {
  canAddArea,
  chooseServer,
  DAILY_ROWS,
  dayChoices,
  newArea,
  serverChoices,
  setTakesRest,
  shownTools,
  toggleDay,
  toggleTool,
  toolNote,
} from './daily-update-rows'
import { draftToSave } from './draft'
import { ModelRow } from './ReviewsSection'
import { RowFilterContext, useRowShown } from './row-filter'
import { CheckRow, DraftField } from './rows'
import { ROW_FIELD, SettingRow, useRowSave } from './SettingRow'
import { useSettings } from './settings-context'

const BUTTON = cx(
  'h-5 shrink-0 border border-panel-edge px-2 text-xs text-text',
  'hover:bg-hover active:bg-accent/12 disabled:opacity-40',
)
const CAPTION = 'text-xs text-text-dim'

// Check the whole value, then save it. A value that fails the check rejects with its reason.
function useCommit(): (next: DailyUpdateSettings) => Promise<void> {
  const { update } = useSettings()
  return async next => {
    const result = checkDailyUpdate(next)
    if (!result.ok) throw new Error(result.reason)
    await update({ dailyUpdate: result.value })
  }
}

// A field of many lines with a draft. The blur and Cmd+Enter save the trimmed text.
// A refused save keeps the text. Escape goes back to the saved text.
function DraftArea(props: {
  label: string
  value: string
  rows: number
  onCommit(text: string): Promise<boolean>
}): React.JSX.Element {
  const [draft, setDraft] = useState(props.value)
  useEffect(() => setDraft(props.value), [props.value])
  const { onCommit } = props
  return (
    <textarea
      aria-label={props.label}
      className={cx(ROW_FIELD, 'h-auto w-full py-1 leading-snug')}
      onBlur={() => {
        const text = draftToSave(draft, props.value)
        if (text === null) {
          setDraft(props.value)
          return
        }
        void onCommit(text)
      }}
      onChange={e => setDraft(e.target.value)}
      onKeyDown={e => {
        if (e.key === 'Enter' && e.metaKey) e.currentTarget.blur()
        if (e.key === 'Escape') {
          setDraft(props.value)
          e.stopPropagation()
        }
      }}
      rows={props.rows}
      spellCheck={false}
      value={draft}
    />
  )
}

// A time of the day. The blur and Enter save a full time. A refused save keeps the time.
// Escape goes back to the saved time.
function TimeField(props: {
  label: string
  value: string
  onCommit(text: string): Promise<boolean>
}): React.JSX.Element {
  const [draft, setDraft] = useState(props.value)
  useEffect(() => setDraft(props.value), [props.value])
  const { onCommit } = props
  return (
    <input
      aria-label={props.label}
      className={cx(ROW_FIELD, 'w-24')}
      onBlur={() => {
        if (draft === '' || draft === props.value) {
          setDraft(props.value)
          return
        }
        void onCommit(draft)
      }}
      onChange={e => setDraft(e.target.value)}
      onKeyDown={e => {
        if (e.key === 'Enter') e.currentTarget.blur()
        if (e.key === 'Escape') {
          setDraft(props.value)
          e.stopPropagation()
        }
      }}
      type='time'
      value={draft}
    />
  )
}

// A row with a block of controls under its label.
function BlockRow(props: {
  label: string
  hint?: string
  error: string | null
  onCloseError(): void
  action?: React.ReactNode
  children: React.ReactNode
}): React.JSX.Element | null {
  if (!useRowShown(props.label)) return null
  return (
    <div className='border-b border-panel-edge' data-setting-row={props.label}>
      <div className='flex min-h-7 items-center justify-between gap-3 px-3'>
        <span className='shrink-0 text-xs text-text'>{props.label}</span>
        {props.action}
      </div>
      {props.hint !== undefined && <p className='px-3 pb-1 text-xs text-text-dim'>{props.hint}</p>}
      <div className='flex flex-col gap-1 px-3 pb-2 text-xs text-text'>{props.children}</div>
      <ErrorLine message={props.error} onClose={props.onCloseError} />
    </div>
  )
}

// The ticket source: a select, the Find servers button, and the tools of the server.
function SourceRows({
  d,
  commit,
}: {
  d: DailyUpdateSettings
  commit: (next: DailyUpdateSettings) => Promise<void>
}): React.JSX.Element {
  const row = useRowSave(DAILY_ROWS.source)
  const toolsRow = useRowSave(DAILY_ROWS.tools)
  const [inventory, setInventory] = useState<McpInventory | null>(null)
  const [busy, setBusy] = useState(false)
  const server = d.source.server
  const choices = inventory ? serverChoices(inventory) : []
  const saved = server !== null && !choices.some(choice => choice.name === server)

  // Only this button starts the search. It can take up to 30 seconds.
  const findServers = (): Promise<boolean> =>
    row.save(async () => {
      setBusy(true)
      try {
        setInventory(await window.bifrost.dailyUpdate.inventory())
      } finally {
        setBusy(false)
      }
    })

  const tools = shownTools(inventory, d.source)
  return (
    <>
      <SettingRow
        error={row.error}
        hint='An MCP server from your Claude Code setup.'
        label={DAILY_ROWS.source}
        onCloseError={row.closeError}
      >
        <select
          aria-label={DAILY_ROWS.source}
          className={cx(ROW_FIELD, 'w-44')}
          disabled={busy}
          onChange={e => {
            const name = e.target.value === '' ? null : e.target.value
            const next = chooseServer(d, inventory ?? { servers: [] }, name)
            void row.save(() => commit(next))
          }}
          value={server ?? ''}
        >
          <option value=''>No ticket source</option>
          {saved && <option value={server}>{server}</option>}
          {choices.map(choice => (
            <option disabled={choice.disabled} key={choice.name} value={choice.name}>
              {choice.label}
            </option>
          ))}
        </select>
        <button className={BUTTON} disabled={busy} onClick={() => void findServers()} type='button'>
          Find servers
        </button>
      </SettingRow>
      {busy && <p className='px-3 py-1 text-xs text-text-dim'>Looking for your MCP servers…</p>}
      {server !== null && (
        <BlockRow
          error={toolsRow.error}
          hint="Bifrost ticks the tools that only read. The run can't use any other tool."
          label={DAILY_ROWS.tools}
          onCloseError={toolsRow.closeError}
        >
          {tools.map(tool => {
            const note = toolNote(tool)
            return (
              <div className='flex items-center gap-2' key={tool.name}>
                <CheckBox
                  ariaLabel={tool.name}
                  checked={tool.on}
                  disabled={tool.write}
                  label={tool.name}
                  onChange={on => {
                    if (tool.write) return
                    const next = {
                      ...d,
                      source: { ...d.source, tools: toggleTool(d.source.tools, tool.name, on) },
                    }
                    void toolsRow.save(() => commit(next))
                  }}
                />
                {note !== null && <span className={cx(CAPTION, 'shrink-0')}>{note}</span>}
              </div>
            )
          })}
        </BlockRow>
      )}
    </>
  )
}

// The examples of past updates, up to 3.
function ExamplesRow({
  d,
  commit,
}: {
  d: DailyUpdateSettings
  commit: (next: DailyUpdateSettings) => Promise<void>
}): React.JSX.Element {
  const row = useRowSave(DAILY_ROWS.examples)
  const list = d.format.examples
  const change = (examples: string[]): Promise<boolean> =>
    row.save(() => commit({ ...d, format: { ...d.format, examples } }))
  return (
    <BlockRow
      action={
        <button
          className={BUTTON}
          disabled={list.length >= 3}
          onClick={() => void change([...list, ''])}
          type='button'
        >
          Add example
        </button>
      }
      error={row.error}
      hint='Up to 3. Claude copies their voice.'
      label={DAILY_ROWS.examples}
      onCloseError={row.closeError}
    >
      {list.map((text, index) => (
        // The list has no stable ID, and it only changes at the end or by Remove.
        // biome-ignore lint/suspicious/noArrayIndexKey: examples are plain text with no ID
        <div className='flex items-start gap-2' key={index}>
          <DraftArea
            label={`Example ${index + 1}`}
            onCommit={value => change(list.map((old, i) => (i === index ? value : old)))}
            rows={4}
            value={text}
          />
          <button
            aria-label={`Remove example ${index + 1}`}
            className={BUTTON}
            onClick={() => void change(list.filter((_, i) => i !== index))}
            type='button'
          >
            Remove
          </button>
        </div>
      ))}
    </BlockRow>
  )
}

// The work areas. A new area stays here, on this page, until it has a name. Then it saves.
function AreasRow({
  d,
  commit,
}: {
  d: DailyUpdateSettings
  commit: (next: DailyUpdateSettings) => Promise<void>
}): React.JSX.Element {
  const row = useRowSave(DAILY_ROWS.areas)
  const [drafts, setDrafts] = useState<WorkArea[]>([])
  const saved = d.areas

  const saveAreas = (areas: WorkArea[]): Promise<boolean> => row.save(() => commit({ ...d, areas }))

  // Change one field of an area. The result is true when the change is kept.
  // Only one area, saved or new, takes all other work.
  const change = async (area: WorkArea, patch: Partial<WorkArea>): Promise<boolean> => {
    const next = { ...area, ...patch }
    const all = [...saved, ...drafts].map(item => (item.id === area.id ? next : item))
    const list = patch.takesRest === true ? setTakesRest(all, area.id) : all
    const savedIds = new Set(saved.map(item => item.id))
    const isSaved = savedIds.has(area.id)
    setDrafts(list.filter(item => !savedIds.has(item.id)))
    if (!isSaved && next.name.trim() === '') return true
    const ok = await saveAreas(list.filter(item => savedIds.has(item.id) || item.id === area.id))
    if (ok && !isSaved) setDrafts(items => items.filter(item => item.id !== area.id))
    return ok
  }

  const remove = (area: WorkArea): void => {
    if (saved.some(item => item.id === area.id)) {
      void saveAreas(saved.filter(item => item.id !== area.id))
    } else {
      setDrafts(list => list.filter(item => item.id !== area.id))
    }
  }

  return (
    <BlockRow
      action={
        <button
          className={BUTTON}
          disabled={!canAddArea(saved.length + drafts.length)}
          onClick={() => setDrafts(list => [...list, newArea()])}
          type='button'
        >
          Add work area
        </button>
      }
      error={row.error}
      label={DAILY_ROWS.areas}
      onCloseError={row.closeError}
    >
      {[...saved, ...drafts].map(area => (
        <div
          className='flex flex-col gap-1 border border-panel-edge p-2'
          data-daily-area={area.id}
          key={area.id}
        >
          <div className='flex items-end gap-2'>
            <div className='flex flex-col'>
              <span className={CAPTION}>On</span>
              <CheckBox
                ariaLabel={`On for ${area.name || 'new work area'}`}
                checked={area.on}
                label={area.on ? 'On' : 'Off'}
                onChange={on => void change(area, { on })}
              />
            </div>
            <div className='flex flex-col'>
              <span className={CAPTION}>Name</span>
              <DraftField
                keepOnRefusal={true}
                label='Name'
                onCommit={text => change(area, { name: text })}
                type='text'
                value={area.name}
                width='w-36'
              />
            </div>
            <div className='flex flex-col'>
              <span className={CAPTION}>Channel</span>
              <DraftField
                keepOnRefusal={true}
                label='Channel'
                onCommit={text => change(area, { channel: text })}
                type='text'
                value={area.channel}
                width='w-36'
              />
            </div>
            <button className={cx(BUTTON, 'ml-auto')} onClick={() => remove(area)} type='button'>
              Remove
            </button>
          </div>
          <span className={CAPTION}>Which work goes here</span>
          <DraftArea
            label='Which work goes here'
            onCommit={text => change(area, { description: text })}
            rows={2}
            value={area.description}
          />
          <CheckBox
            ariaLabel={`Takes all other work for ${area.name || 'new work area'}`}
            checked={area.takesRest}
            label='Takes all other work'
            onChange={on => void change(area, { takesRest: on })}
          />
        </div>
      ))}
    </BlockRow>
  )
}

function DaysRow({
  d,
  commit,
}: {
  d: DailyUpdateSettings
  commit: (next: DailyUpdateSettings) => Promise<void>
}): React.JSX.Element {
  const row = useRowSave(DAILY_ROWS.days)
  return (
    <SettingRow error={row.error} label={DAILY_ROWS.days} onCloseError={row.closeError}>
      {dayChoices().map(({ day, label }) => {
        const on = d.days.includes(day)
        return (
          <button
            aria-pressed={on}
            className={cx(BUTTON, on && 'bg-hover text-text-strong')}
            key={day}
            onClick={() =>
              void row.save(async () => {
                const days = toggleDay(d.days, day)
                if (days.length === 0) throw new Error('Pick at least one day.')
                await commit({ ...d, days })
              })
            }
            type='button'
          >
            {label}
          </button>
        )
      })}
    </SettingRow>
  )
}

function TimeRow(props: {
  label: string
  hint?: string
  value: string
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
      <TimeField
        label={props.label}
        onCommit={value => row.save(() => save(value))}
        value={props.value}
      />
    </SettingRow>
  )
}

// A text field row that saves the trimmed text.
function TextRow(props: {
  label: string
  hint: string
  value: string
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
      <DraftField
        keepOnRefusal={true}
        label={props.label}
        onCommit={text => row.save(() => save(text))}
        type='text'
        value={props.value}
        width='w-56'
      />
    </SettingRow>
  )
}

function FormatRow({
  d,
  commit,
}: {
  d: DailyUpdateSettings
  commit: (next: DailyUpdateSettings) => Promise<void>
}): React.JSX.Element {
  const row = useRowSave(DAILY_ROWS.format)
  return (
    <BlockRow
      error={row.error}
      hint='Your headings. Bold is **text**.'
      label={DAILY_ROWS.format}
      onCloseError={row.closeError}
    >
      <DraftArea
        label={DAILY_ROWS.format}
        onCommit={text =>
          row.save(async () => {
            if (text === '') throw new Error('The format needs some text.')
            await commit({ ...d, format: { ...d.format, template: text } })
          })
        }
        rows={5}
        value={d.format.template}
      />
    </BlockRow>
  )
}

// only: during a search, the labels of the rows that show (spec 12).
// The filter provider is in this component, above DailyUpdateRows, so each useRowSave call is
// below it.
export default function DailyUpdateSection({
  only = null,
}: {
  only?: ReadonlySet<string> | null
}): React.JSX.Element {
  return (
    <RowFilterContext value={only}>
      <DailyUpdateRows />
    </RowFilterContext>
  )
}

function DailyUpdateRows(): React.JSX.Element {
  const { settings } = useSettings()
  const d = settings.dailyUpdate
  const commit = useCommit()
  return (
    <div className='flex min-h-full flex-col'>
      <SourceRows commit={commit} d={d} />
      <TextRow
        hint={
          'Your name, email or ID. ' +
          'Leave it empty to use the account that the server signs in with.'
        }
        label={DAILY_ROWS.you}
        save={value => commit({ ...d, you: value })}
        value={d.you}
      />
      <CheckRow
        checked={d.mergedPrs}
        label={DAILY_ROWS.mergedPrs}
        save={value => commit({ ...d, mergedPrs: value })}
      />
      <TimeRow
        label={DAILY_ROWS.draftTime}
        save={value => commit({ ...d, draftTime: value })}
        value={d.draftTime}
      />
      <TimeRow
        hint='The second reminder comes 10 minutes before.'
        label={DAILY_ROWS.deadline}
        save={value => commit({ ...d, deadline: value })}
        value={d.deadline}
      />
      <DaysRow commit={commit} d={d} />
      <ModelRow
        label={DAILY_ROWS.model}
        save={value => commit({ ...d, model: value as ModelChoice })}
        value={d.model}
      />
      <FormatRow commit={commit} d={d} />
      <ExamplesRow commit={commit} d={d} />
      <AreasRow commit={commit} d={d} />
    </div>
  )
}
