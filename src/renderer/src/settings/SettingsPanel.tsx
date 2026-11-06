// The Settings panel (spec 12): a row of section tabs, then the section in a scroll area.
import { cx } from '../lib/cx'
import GeneralSection from './GeneralSection'
import SlashSection from './SlashSection'
import { type SettingsSection, useSettingsNav } from './settings-nav'

const TABS: { id: SettingsSection; label: string }[] = [
  { id: 'general', label: 'General' },
  { id: 'slash', label: 'Slash commands' },
]

export default function SettingsPanel(): React.JSX.Element {
  const { section, setSection } = useSettingsNav()
  return (
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
            </button>
          )
        })}
      </div>
      <div className='flex min-h-0 flex-1 flex-col overflow-y-auto' data-settings-section={section}>
        {section === 'general' && <GeneralSection />}
        {section === 'slash' && <SlashSection />}
      </div>
    </div>
  )
}
