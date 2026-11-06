// The Settings panel (spec 12): a search field, a row of section tabs, the section in a scroll
// area, and a footer with the Save button. During a search, the scroll area shows the matches of
// all sections in one list, each section under a small heading.
import { Search } from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { DIALOG_BUTTON } from '../actions/ConfirmDialog'
import { cx } from '../lib/cx'
import { useWmControls } from '../wm/context'
import GeneralSection from './GeneralSection'
import KeysSection from './KeysSection'
import { keyGroups } from './key-editor'
import LiveSection from './LiveSection'
import { useLive } from './live-context'
import { claudeVersionLine, LIVE_ACTION_LABELS, liveActions, liveStateLine } from './live-notice'
import { ROW_FIELD } from './SettingRow'
import SlashSection from './SlashSection'
import { SaveTrackerContext } from './save-context'
import { SaveTracker } from './save-tracker'
import {
  noMatchText,
  SECTION_TITLES,
  type SearchHit,
  searchEscape,
  searchSettings,
  searchShortcut,
  settingsIndex,
} from './search'
import { useSettings } from './settings-context'
import { type SettingsSection, useSettingsNav } from './settings-nav'

const TABS: SettingsSection[] = ['general', 'slash', 'keys', 'live']

// The focus for Cmd+F: in Settings, nowhere (the page body), or in another place.
function focusPlace(root: HTMLElement | null): 'settings' | 'none' | 'other' {
  const active = document.activeElement
  if (active === null || active === document.body) return 'none'
  return root?.contains(active) ? 'settings' : 'other'
}

// True when the frame of the element is the front frame that shows. The frames keep their
// z-order in the style.
function onTop(root: HTMLElement | null): boolean {
  const frame = root?.closest<HTMLElement>('[data-frame-id]')
  if (!frame) return false
  const shown = [...document.querySelectorAll<HTMLElement>('[data-frame-id]')].filter(
    el => el.offsetParent !== null,
  )
  const z = (el: HTMLElement): number => Number(el.style.zIndex) || 0
  return shown.every(el => z(el) <= z(frame))
}

// The rows of one section that match, or null for the whole section.
function onlyOf(hit: SearchHit): ReadonlySet<string> | null {
  return hit.whole ? null : new Set(hit.rows)
}

function Hit({ hit }: { hit: SearchHit }): React.JSX.Element {
  const only = useMemo(() => onlyOf(hit), [hit])
  return (
    <section data-search-section={hit.id}>
      {/* The section heading is white, so it differs from a group heading of Keys. */}
      <h3 className='border-panel-edge border-b bg-title px-3 py-1 font-medium text-text-strong text-xs'>
        {hit.title}
      </h3>
      {hit.id === 'general' && <GeneralSection only={only} />}
      {hit.id === 'slash' && <SlashSection only={only} />}
      {hit.id === 'keys' && <KeysSection only={only} />}
      {hit.id === 'live' && <LiveSection />}
    </section>
  )
}

export default function SettingsPanel(): React.JSX.Element {
  const { section, setSection } = useSettingsNav()
  const { dispatch } = useWmControls()
  const { settings } = useSettings()
  // The Live details tab shows the same dot as the side bar Settings button (D11).
  const { notice, status, version, versionFailed, warning } = useLive()
  const [tracker] = useState(() => new SaveTracker())
  const [saving, setSaving] = useState(false)
  const [query, setQuery] = useState('')
  const root = useRef<HTMLDivElement>(null)
  const content = useRef<HTMLDivElement>(null)
  const searchField = useRef<HTMLInputElement>(null)

  // The rows of all sections that the search reads.
  const index = useMemo(
    () =>
      settingsIndex({
        keys: keyGroups(settings.keys, settings.labels),
        live: [
          SECTION_TITLES.live,
          'plugin',
          liveStateLine(notice),
          ...liveActions(status).map(id => LIVE_ACTION_LABELS[id]),
          claudeVersionLine(version, versionFailed) ?? 'Claude Code',
        ],
        slash: settings.slashCommands,
      }),
    [
      notice,
      settings.keys,
      settings.labels,
      settings.slashCommands,
      status,
      version,
      versionFailed,
    ],
  )
  const hits = useMemo(() => searchSettings(query, index), [index, query])

  // Cmd+F moves the focus to the search field while Settings has the focus (spec 12). A key of
  // the key map that uses Cmd+F runs first and stops the event.
  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if (event.defaultPrevented) return
      if (!searchShortcut(event, focusPlace(root.current), onTop(root.current))) return
      event.preventDefault()
      searchField.current?.focus()
      searchField.current?.select()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [])

  // Each change saves at once. Save blurs the focused field, so that its draft saves, and waits
  // for all saves. A row with a failed save keeps Settings open, and the row shows the error.
  // A row of another section unmounted, so it does not count. Else Save closes Settings (spec 12).
  const save = async (): Promise<void> => {
    const active = document.activeElement
    if (active instanceof HTMLElement && content.current?.contains(active)) active.blur()
    setSaving(true)
    const ok = await tracker.settle()
    setSaving(false)
    if (ok) dispatch({ panelId: 'settings', type: 'close' })
  }

  const close = (): void => dispatch({ panelId: 'settings', type: 'close' })

  return (
    <SaveTrackerContext value={tracker}>
      {/* A click on a part with no control gives the focus to the panel. So Cmd+F works there. */}
      <div className='flex h-full min-h-0 flex-col outline-none' ref={root} tabIndex={-1}>
        <div className='flex shrink-0 items-center gap-1.5 border-panel-edge border-b px-3 py-1.5'>
          <Search aria-hidden={true} className='shrink-0 text-text-dim' size={12} />
          <input
            aria-label='Search settings'
            className={cx(ROW_FIELD, 'h-6 flex-1 [&::-webkit-search-cancel-button]:hidden')}
            data-settings-search={true}
            onChange={e => setQuery(e.target.value)}
            // Esc clears the query first. In an empty field, Esc closes Settings (spec 9.4). The
            // event stops here, so no other Esc acts on it.
            onKeyDown={e => {
              if (e.key !== 'Escape') return
              const action = searchEscape(query, e.nativeEvent.isComposing)
              if (action === 'ignore') return
              e.preventDefault()
              e.stopPropagation()
              if (action === 'clear') setQuery('')
              else close()
            }}
            placeholder='Search settings'
            ref={searchField}
            spellCheck={false}
            type='search'
            value={query}
          />
        </div>
        {/* The stack tab style of the frame (spec 8.10): white text and a white underline.
            During a search no tab is active. A click on a tab ends the search. */}
        <div
          className='flex h-[22px] shrink-0 items-stretch border-panel-edge border-b'
          role='tablist'
        >
          {TABS.map(id => {
            const active = hits === null && id === section
            return (
              <button
                aria-selected={active}
                className={cx(
                  'truncate border-b-2 px-2 text-xs active:bg-accent/12',
                  active
                    ? 'border-text-strong text-text-strong'
                    : 'border-transparent text-text-dim hover:text-text',
                )}
                data-settings-tab={id}
                key={id}
                onClick={() => {
                  setQuery('')
                  setSection(id)
                }}
                role='tab'
                type='button'
              >
                {SECTION_TITLES[id]}
                {id === 'live' && warning && (
                  <span
                    aria-hidden={true}
                    className='ml-1 inline-block size-1.5 bg-text-strong align-middle'
                    data-settings-warning={true}
                  />
                )}
              </button>
            )
          })}
        </div>
        <div
          className='flex min-h-0 flex-1 flex-col overflow-y-auto'
          data-settings-section={hits === null ? section : 'search'}
          ref={content}
        >
          {hits === null && section === 'general' && <GeneralSection />}
          {hits === null && section === 'slash' && <SlashSection />}
          {hits === null && section === 'keys' && <KeysSection />}
          {hits === null && section === 'live' && <LiveSection />}
          {hits?.map(hit => (
            <Hit hit={hit} key={hit.id} />
          ))}
          {hits !== null && hits.length === 0 && (
            <p className='px-3 py-2 text-text-dim text-xs' data-settings-no-match={true}>
              {noMatchText(query)}
            </p>
          )}
        </div>
        <div
          className='flex shrink-0 items-center justify-end border-panel-edge border-t px-3 py-1.5 text-xs'
          data-settings-footer={true}
        >
          <button
            className={DIALOG_BUTTON}
            data-settings-save={true}
            disabled={saving}
            onClick={() => void save()}
            // The field keeps the focus until the click. Then Save blurs it and waits for its save.
            onMouseDown={e => e.preventDefault()}
            type='button'
          >
            Save
          </button>
        </div>
      </div>
    </SaveTrackerContext>
  )
}
