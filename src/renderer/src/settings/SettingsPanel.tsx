// The Settings panel (spec 12): a row of section tabs, the section in a scroll area, and a footer
// with the Save button.
import { useRef, useState } from 'react'
import { DIALOG_BUTTON } from '../actions/ConfirmDialog'
import { cx } from '../lib/cx'
import { useWmControls } from '../wm/context'
import GeneralSection from './GeneralSection'
import KeysSection from './KeysSection'
import LiveSection from './LiveSection'
import { useLive } from './live-context'
import SlashSection from './SlashSection'
import { SaveTrackerContext } from './save-context'
import { SaveTracker } from './save-tracker'
import { type SettingsSection, useSettingsNav } from './settings-nav'

const TABS: { id: SettingsSection; label: string }[] = [
  { id: 'general', label: 'General' },
  { id: 'slash', label: 'Slash commands' },
  { id: 'keys', label: 'Keys' },
  { id: 'live', label: 'Live details' },
]

export default function SettingsPanel(): React.JSX.Element {
  const { section, setSection } = useSettingsNav()
  const { dispatch } = useWmControls()
  // The Live details tab shows the same dot as the side bar Settings button (D11).
  const { warning } = useLive()
  const [tracker] = useState(() => new SaveTracker())
  const [saving, setSaving] = useState(false)
  const content = useRef<HTMLDivElement>(null)

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

  return (
    <SaveTrackerContext value={tracker}>
      <div className='flex h-full min-h-0 flex-col'>
        {/* The stack tab style of the frame (spec 8.10): white text and a white underline. */}
        <div
          className='flex h-[22px] shrink-0 items-stretch border-panel-edge border-b'
          role='tablist'
        >
          {TABS.map(tab => {
            const active = tab.id === section
            return (
              <button
                aria-selected={active}
                className={cx(
                  'truncate border-b-2 px-2 text-xs active:bg-accent/12',
                  active
                    ? 'border-text-strong text-text-strong'
                    : 'border-transparent text-text-dim hover:text-text',
                )}
                data-settings-tab={tab.id}
                key={tab.id}
                onClick={() => setSection(tab.id)}
                role='tab'
                type='button'
              >
                {tab.label}
                {tab.id === 'live' && warning && (
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
          data-settings-section={section}
          ref={content}
        >
          {section === 'general' && <GeneralSection />}
          {section === 'slash' && <SlashSection />}
          {section === 'keys' && <KeysSection />}
          {section === 'live' && <LiveSection />}
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
