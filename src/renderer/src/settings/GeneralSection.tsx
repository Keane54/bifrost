// Settings > General (spec 12). A checkbox, a radio button or a select saves on change.
// A number or a text field saves on Enter and on blur. A rejected save shows its reason in the
// row and puts back the old value.
import { Radio } from '@base-ui/react/radio'
import { RadioGroup } from '@base-ui/react/radio-group'
import { useEffect, useState } from 'react'
import {
  FONT_SIZE_MAX,
  FONT_SIZE_MIN,
  INTERFACE_SCALE_CHOICES,
  type LabelSet,
  MAX_ESCALATION_MINUTES,
  MAX_SNAP,
  PANEL_TRANSPARENCY_CHOICES,
  POLL_CHOICES,
  projectAppChoices,
  shownProjectApp,
  TERMINAL_APP_IDS,
  type TerminalAppId,
} from '../../../shared/settings'
import type { DisplayMode, ProjectApp, ProjectAppId } from '../../../shared/types'
import { useActions } from '../actions/actions-context'
import { CheckBox } from '../lib/CheckBox'
import { cx } from '../lib/cx'
import { draftToSave } from './draft'
import IntroRow from './IntroRow'
import { useLive } from './live-context'
import { claudeVersionNotice } from './live-notice'
import { ROW_FIELD, SettingRow, useRowSave } from './SettingRow'
import { useSettings } from './settings-context'

const FONT_FAMILIES = ['SF Mono', 'Menlo', 'Monaco', 'Courier New']
const AUTO_TERMINAL = 'Automatic (first installed: Warp, Ghostty, iTerm2, Terminal)'
const AUTO_PROJECT = 'Automatic (VS Code, else Zed, else your terminal app)'

// A square radio button with its name. The name is part of the click target.
function Choice({ label, value }: { label: string; value: string }): React.JSX.Element {
  return (
    <Radio.Root className='group flex items-center gap-1.5' value={value}>
      <span className='flex size-3.5 shrink-0 items-center justify-center border border-text-dim bg-bg group-data-checked:border-text'>
        <Radio.Indicator className='size-1.5 bg-text-strong' />
      </span>
      {label}
    </Radio.Root>
  )
}

function Choices(props: {
  label: string
  value: string
  onChange(value: string): void
  choices: { label: string; value: string }[]
}): React.JSX.Element {
  return (
    <RadioGroup
      aria-label={props.label}
      className='flex items-center gap-3'
      onValueChange={value => props.onChange(String(value))}
      value={props.value}
    >
      {props.choices.map(choice => (
        <Choice key={choice.value} label={choice.label} value={choice.value} />
      ))}
    </RadioGroup>
  )
}

// A field with a draft. Enter blurs the field, and the blur saves the trimmed text. The draft goes
// back to the saved value when the save is rejected, or when the trimmed text did not change.
function DraftField(props: {
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
function NumberRow(props: {
  label: string
  value: number
  min: number
  max: number
  unit: string
  hint?: string
  save(value: number): Promise<void>
}): React.JSX.Element {
  const row = useRowSave()
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

function CheckRow(props: {
  label: string
  checked: boolean
  disabled?: boolean
  hint?: string
  save(value: boolean): Promise<void>
}): React.JSX.Element {
  const row = useRowSave()
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
function SelectRow(props: {
  label: string
  value: number
  choices: readonly number[]
  text(value: number): string
  save(value: number): Promise<void>
}): React.JSX.Element {
  const row = useRowSave()
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

function AppSelect(props: {
  label: string
  auto: string
  value: string | null
  apps: ProjectApp[]
  onChange(id: string | null): void
}): React.JSX.Element {
  const known = props.value === null || props.apps.some(app => app.id === props.value)
  return (
    <select
      aria-label={props.label}
      className={cx(ROW_FIELD, 'max-w-72')}
      onChange={e => props.onChange(e.target.value === '' ? null : e.target.value)}
      value={props.value ?? ''}
    >
      <option value=''>{props.auto}</option>
      {props.apps.map(app => (
        <option key={app.id} value={app.id}>
          {app.label}
        </option>
      ))}
      {!known && props.value !== null && <option value={props.value}>{props.value}</option>}
    </select>
  )
}

const DISPLAY_CHOICES: { label: string; value: DisplayMode }[] = [
  { label: 'Window', value: 'window' },
  { label: 'Borderless', value: 'borderless' },
  { label: 'Fullscreen', value: 'fullscreen' },
]
const LABEL_CHOICES: { label: string; value: LabelSet }[] = [
  { label: 'Plain', value: 'plain' },
  { label: 'Space', value: 'space' },
]

export default function GeneralSection(): React.JSX.Element {
  const { settings, update } = useSettings()
  // The general warning for the version of Claude Code (spec 11.5, ruling C5). A failed check
  // warns too.
  const { version, versionFailed } = useLive()
  const versionText = claudeVersionNotice(version, versionFailed)
  const [terminalApps, setTerminalApps] = useState<ProjectApp[]>([])
  // The ActionsProvider has the list of "Open project". It follows the Terminal app setting.
  const { apps: projectApps } = useActions()
  const [info, setInfo] = useState<{ packaged: boolean; version: string } | null>(null)
  const [mode, setMode] = useState<DisplayMode>('window')
  const labelsRow = useRowSave()
  const terminalRow = useRowSave()
  const projectRow = useRowSave()
  const fontRow = useRowSave()
  const modeRow = useRowSave()

  useEffect(() => {
    let active = true
    const api = window.bifrost
    api.actions.terminalApps().then(
      list => active && setTerminalApps(list),
      err => console.error('Bifrost cannot get the list of terminal apps.', err),
    )
    api.system.info().then(
      value => active && setInfo(value),
      err => console.error('Bifrost cannot get the app version.', err),
    )
    api.display.get().then(
      value => active && setMode(value),
      err => console.error('Bifrost cannot get the display mode.', err),
    )
    const off = api.display.onChange(value => setMode(value))
    return () => {
      active = false
      off()
    }
  }, [])

  const font = settings.terminalFont
  return (
    <div className='flex min-h-full flex-col'>
      {versionText !== null && (
        <p
          className='select-text border-panel-edge border-b px-3 py-2 text-text text-xs'
          data-settings-version-notice={true}
        >
          {versionText}
        </p>
      )}
      <SettingRow error={labelsRow.error} label='Labels' onCloseError={labelsRow.closeError}>
        <Choices
          choices={LABEL_CHOICES}
          label='Labels'
          onChange={value => {
            labelsRow.save(() => update({ labels: value as LabelSet }))
          }}
          value={settings.labels}
        />
      </SettingRow>
      <SettingRow
        error={terminalRow.error}
        label='Terminal app'
        onCloseError={terminalRow.closeError}
      >
        <AppSelect
          apps={terminalApps}
          auto={AUTO_TERMINAL}
          label='Terminal app'
          onChange={id => {
            const terminalApp = TERMINAL_APP_IDS.find(t => t === id) ?? null
            terminalRow.save(() => update({ terminalApp: terminalApp as TerminalAppId | null }))
          }}
          value={settings.terminalApp}
        />
      </SettingRow>
      <SettingRow
        error={projectRow.error}
        label='Default app for "Open project"'
        onCloseError={projectRow.closeError}
      >
        <AppSelect
          apps={projectAppChoices(projectApps)}
          auto={AUTO_PROJECT}
          label='Default app for "Open project"'
          onChange={id => {
            projectRow.save(() => update({ projectApp: id as ProjectAppId | null }))
          }}
          value={shownProjectApp(settings.projectApp)}
        />
      </SettingRow>
      <NumberRow
        label='Escalation time'
        max={MAX_ESCALATION_MINUTES}
        min={0}
        save={value => update({ escalationMinutes: value })}
        unit='minutes (0 turns escalation off)'
        value={settings.escalationMinutes}
      />
      <CheckRow
        checked={settings.rowFlash}
        label='Row flash'
        save={value => update({ rowFlash: value })}
      />
      <CheckRow
        checked={settings.notifications}
        label='macOS notification'
        save={value => update({ notifications: value })}
      />
      <CheckRow
        checked={settings.redBoxSound}
        label='Sound for a red box'
        save={value => update({ redBoxSound: value })}
      />
      <CheckRow
        checked={settings.startAtLogin}
        disabled={info !== null && !info.packaged}
        hint={info !== null && !info.packaged ? 'Only works in the installed app.' : undefined}
        label='Start at login'
        save={value => update({ startAtLogin: value })}
      />
      <SelectRow
        choices={POLL_CHOICES}
        label='Poll interval'
        save={value => update({ pollSeconds: value })}
        text={seconds => (seconds === 1 ? '1 second' : `${seconds} seconds`)}
        value={settings.pollSeconds}
      />
      <NumberRow
        label='Snap distance'
        max={MAX_SNAP}
        min={0}
        save={value => update({ snapDistance: value })}
        unit='pixels'
        value={settings.snapDistance}
      />
      <SelectRow
        choices={PANEL_TRANSPARENCY_CHOICES}
        label='Panel transparency'
        save={value => update({ panelTransparency: value })}
        text={percent => (percent === 0 ? '0% (solid)' : `${percent}%`)}
        value={settings.panelTransparency}
      />
      {/* The motion of the background behind the panels (spec 8.10). Off keeps the colours still. */}
      <CheckRow
        checked={settings.animatedBackground}
        hint='Slowly shifting colours behind the panels. Turn it off to save battery.'
        label='Animated background'
        save={value => update({ animatedBackground: value })}
      />
      <SelectRow
        choices={INTERFACE_SCALE_CHOICES}
        label='Interface scale'
        save={value => update({ interfaceScale: value })}
        text={percent => `${percent}%`}
        value={settings.interfaceScale}
      />
      <SettingRow error={fontRow.error} label='Terminal font' onCloseError={fontRow.closeError}>
        <datalist id='settings-font-families'>
          {FONT_FAMILIES.map(family => (
            <option key={family} value={family} />
          ))}
        </datalist>
        <DraftField
          label='Terminal font family'
          list='settings-font-families'
          onCommit={text => fontRow.save(() => update({ terminalFont: { ...font, family: text } }))}
          type='text'
          value={font.family}
          width='w-36'
        />
        <DraftField
          label='Terminal font size'
          max={FONT_SIZE_MAX}
          min={FONT_SIZE_MIN}
          onCommit={text => {
            const size = Number(text)
            if (text.trim() === '' || !Number.isInteger(size)) {
              return fontRow.save(() =>
                Promise.reject(
                  new Error(`Enter a whole number from ${FONT_SIZE_MIN} to ${FONT_SIZE_MAX}.`),
                ),
              )
            }
            return fontRow.save(() => update({ terminalFont: { ...font, size } }))
          }}
          type='number'
          value={String(font.size)}
          width='w-14'
        />
        <span className='text-text-dim'>pt</span>
      </SettingRow>
      <SettingRow error={modeRow.error} label='Display mode' onCloseError={modeRow.closeError}>
        <Choices
          choices={DISPLAY_CHOICES}
          label='Display mode'
          onChange={value => {
            modeRow.save(() => window.bifrost.display.set(value as DisplayMode))
          }}
          value={mode}
        />
      </SettingRow>
      {/* Show the setup dialog again (spec 11.1). */}
      <IntroRow />
      <p className='mt-auto px-3 py-2 text-text-dim text-xs' data-settings-version={true}>
        {info === null ? 'Bifrost' : `Bifrost ${info.version}`}
      </p>
    </div>
  )
}
