// The Daily update panel (Daily update design, section 6.2, layout A): a status line, one tab for
// each work area that is on, and in each tab the items that moved, the draft and its buttons.
import { Button } from '@base-ui/react/button'
import { useCallback, useEffect, useState } from 'react'
import type { DailyItem, DailySnapshot } from '../../../shared/daily-state'
import type { WorkArea } from '../../../shared/daily-update'
import { friendlyError } from '../actions/errors'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { Tip } from '../lib/menu'
import { useSettings } from '../settings/settings-context'
import { useSettingsNav } from '../settings/settings-nav'
import DraftView from './DraftView'
import {
  areaSince,
  areaView,
  COPIED_MS,
  dueText,
  failureLine,
  itemChange,
  movedHeader,
  NEW_DRAFT,
  NO_DRAFT,
  NOT_SENT,
  NOTHING_MOVED,
  panelBody,
  REDO_CONFIRM,
  redoNeedsConfirm,
  refreshText,
  SEND_TIP,
  SET_UP,
  sendText,
  sentText,
  shownTab,
  skipButton,
  statusText,
  tabMarker,
  unplacedText,
} from './panel-model'
import { setDailyTab, useDailyTab, useDailyUpdate } from './use-daily-update'

// Run a call of the main process. A failure shows in the error line. Give true for a good call.
type Act = (job: () => Promise<unknown>) => Promise<boolean>

// A press gives a short cyan tint. A hover stays neutral (spec 8.10).
const SMALL_BUTTON = cx(
  'border border-panel-edge bg-black/35 px-1.5 leading-4 text-text hover:text-text-strong',
  'not-data-disabled:active:bg-accent/12 data-disabled:opacity-40',
)
const ITEM_ROW = 'flex min-w-0 items-baseline gap-2 px-1 py-0.5 text-xs whitespace-nowrap'

// A disabled button keeps the focus and its tip.
function SmallButton(props: {
  disabled?: boolean
  label: string
  onClick?: () => void
  tip?: string
}): React.JSX.Element {
  return (
    <Tip label={props.tip ?? null}>
      <Button
        className={SMALL_BUTTON}
        disabled={props.disabled}
        focusableWhenDisabled={true}
        onClick={() => {
          if (!props.disabled) props.onClick?.()
        }}
      >
        {props.label}
      </Button>
    </Tip>
  )
}

// The tickets and PRs. A click on an item with a link opens the link in the browser. The area
// ID '' is the list of the items that fit no area.
function ItemList(props: { act: Act; areaId: string; items: DailyItem[] }): React.JSX.Element {
  const { act, areaId } = props
  return (
    <ul className='flex flex-col'>
      {props.items.map((item, i) => {
        const change = itemChange(item)
        const parts = (
          <>
            <span className='shrink-0 text-text-dim'>{item.id}</span>
            <span className='min-w-0 truncate text-text'>{item.title}</span>
            {change !== null && <span className='ml-auto shrink-0 text-text-dim'>{change}</span>}
          </>
        )
        return (
          // biome-ignore lint/suspicious/noArrayIndexKey: two items can have the same ID
          <li key={i}>
            {item.url === undefined ? (
              <div className={ITEM_ROW}>{parts}</div>
            ) : (
              <button
                className={cx(ITEM_ROW, 'w-full text-left hover:bg-hover active:bg-accent/12')}
                onClick={() => void act(() => window.bifrost.dailyUpdate.openItem(areaId, item.id))}
                type='button'
              >
                {parts}
              </button>
            )}
          </li>
        )
      })}
    </ul>
  )
}

function StatusLine(props: {
  act: Act
  snap: DailySnapshot
  showUnplaced: boolean
  onUnplaced(): void
}): React.JSX.Element {
  const { act, snap } = props
  const skip = skipButton(snap)
  const unplaced = unplacedText(snap.state.unplaced.length)
  const parts = [dueText(snap), refreshText(snap, Date.now())].filter(
    (p): p is string => p !== null,
  )
  return (
    <div
      className={cx(
        'flex shrink-0 flex-wrap items-center gap-x-3 gap-y-1',
        'border-b border-panel-edge px-2 py-1 text-xs',
      )}
      data-daily-status={true}
    >
      <span className='text-text-strong'>{statusText(snap, Date.now())}</span>
      {parts.map(part => (
        <span className='text-text-dim' key={part}>
          {part}
        </span>
      ))}
      {unplaced !== null && (
        <button
          aria-expanded={props.showUnplaced}
          className='text-text underline-offset-2 hover:text-text-strong hover:underline'
          onClick={props.onUnplaced}
          type='button'
        >
          {unplaced}
        </button>
      )}
      <div className='ml-auto flex items-center gap-1'>
        <SmallButton
          disabled={snap.running}
          label='Refresh'
          onClick={() => void act(() => window.bifrost.dailyUpdate.refresh('button'))}
        />
        {skip === 'skip' && (
          <SmallButton
            label='Skip today'
            onClick={() => void act(() => window.bifrost.dailyUpdate.setSkipped(true))}
          />
        )}
        {skip === 'undo' && (
          <SmallButton
            label='Undo'
            onClick={() => void act(() => window.bifrost.dailyUpdate.setSkipped(false))}
          />
        )}
      </div>
    </div>
  )
}

// One work area: the items that moved, the draft and the buttons. The tab keeps its own edit
// box, so a change of the tab does not lose typed text.
function AreaTab(props: {
  act: Act
  area: WorkArea
  hidden: boolean
  snap: DailySnapshot
}): React.JSX.Element {
  const { act, area, snap } = props
  const id = area.id
  const view = areaView(snap, id)
  const sentAt = sentText(snap, id)
  const [editing, setEditing] = useState(false)
  const [text, setText] = useState('')
  const [confirming, setConfirming] = useState(false)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (!copied) return
    const timer = window.setTimeout(() => setCopied(false), COPIED_MS)
    return () => window.clearTimeout(timer)
  }, [copied])

  function startEdit(): void {
    if (view === undefined) return
    setText(view.draft)
    setEditing(true)
  }

  // A refused save keeps the edit box and the typed text.
  function finishEdit(): void {
    if (view === undefined || text === view.draft) {
      setEditing(false)
      return
    }
    void act(() => window.bifrost.dailyUpdate.editDraft(id, text)).then(ok => {
      if (ok) setEditing(false)
    })
  }

  function runRedo(): void {
    void act(() => window.bifrost.dailyUpdate.redo(id))
  }

  // A changed draft asks first, because the new draft replaces it.
  function onRedo(): void {
    if (redoNeedsConfirm(view)) {
      setConfirming(true)
      return
    }
    runRedo()
  }

  // The new draft replaces the text of an open edit box too.
  function onUseNew(): void {
    // biome-ignore lint/correctness/useHookAtTopLevel: usePending is an IPC call, not a hook
    void act(() => window.bifrost.dailyUpdate.usePending(id)).then(ok => {
      if (ok) setEditing(false)
    })
  }

  function onCopy(): void {
    void act(() => window.bifrost.dailyUpdate.copy(id)).then(ok => {
      if (ok) setCopied(true)
    })
  }

  return (
    <section className='flex flex-col gap-2 p-2' data-daily-area={id} hidden={props.hidden}>
      {view === undefined ? (
        <p className='text-xs text-text-dim'>{NO_DRAFT}</p>
      ) : (
        <>
          <div className='flex flex-col gap-0.5'>
            <h3 className='px-1 text-xs text-text-dim'>
              {movedHeader(areaSince(snap, id), Date.now())}
            </h3>
            {view.items.length === 0 ? (
              <p className='px-1 text-xs text-text'>{NOTHING_MOVED}</p>
            ) : (
              <ItemList act={act} areaId={id} items={view.items} />
            )}
          </div>
          {view.pending !== undefined && (
            <div className='flex flex-wrap items-center gap-1 text-xs' data-daily-pending={true}>
              <span className='mr-1 text-text-strong'>{NEW_DRAFT}</span>
              <SmallButton label='Use new draft' onClick={onUseNew} />
              <SmallButton
                label='Keep mine'
                onClick={() => void act(() => window.bifrost.dailyUpdate.keepMine(id))}
              />
            </div>
          )}
          {editing ? (
            <textarea
              aria-label='Draft'
              className={cx(
                'w-full resize-y border border-panel-edge bg-bg px-2 py-1.5',
                'text-xs leading-5 text-text focus:border-text-strong/30',
              )}
              onChange={e => setText(e.target.value)}
              rows={Math.max(6, text.split('\n').length + 1)}
              value={text}
            />
          ) : (
            <DraftView draft={view.draft} />
          )}
        </>
      )}
      <div className='flex flex-wrap items-center gap-1 text-xs'>
        {confirming ? (
          <>
            <span className='mr-1 text-text-strong'>{REDO_CONFIRM}</span>
            <SmallButton
              label='Replace'
              onClick={() => {
                setConfirming(false)
                runRedo()
              }}
            />
            <SmallButton label='Cancel' onClick={() => setConfirming(false)} />
          </>
        ) : (
          <>
            {view !== undefined && (
              <SmallButton
                label={editing ? 'Done' : 'Edit'}
                onClick={editing ? finishEdit : startEdit}
              />
            )}
            <SmallButton disabled={snap.running || editing} label='Redo draft' onClick={onRedo} />
            <SmallButton
              disabled={view === undefined || editing}
              label={copied ? 'Copied' : 'Copy'}
              onClick={onCopy}
            />
            {sentAt === null ? (
              <SmallButton
                label='Mark as sent'
                onClick={() => void act(() => window.bifrost.dailyUpdate.markSent(id))}
              />
            ) : (
              <>
                <span className='mx-1 text-text'>{sentAt}</span>
                <SmallButton
                  label='Undo'
                  onClick={() => void act(() => window.bifrost.dailyUpdate.undoSent(id))}
                />
              </>
            )}
            <SmallButton disabled={true} label={sendText(area.channel)} tip={SEND_TIP} />
          </>
        )}
      </div>
    </section>
  )
}

export default function DailyUpdatePanel(): React.JSX.Element {
  const snap = useDailyUpdate()
  const chosen = useDailyTab()
  const settingsNav = useSettingsNav()
  const { settings } = useSettings()
  const [error, setError] = useState<string | null>(null)
  const [showUnplaced, setShowUnplaced] = useState(false)

  const act = useCallback<Act>(async job => {
    setError(null)
    try {
      await job()
      return true
    } catch (err) {
      setError(friendlyError(errorMessage(err)))
      return false
    }
  }, [])

  // The open of the panel runs the drafts. The main process starts no run while a run runs, or
  // within 5 minutes after the end of the last run.
  useEffect(() => {
    void act(() => window.bifrost.dailyUpdate.refresh('open'))
  }, [act])

  const body = panelBody(snap)
  const tab = snap === null ? null : shownTab(snap, chosen)
  // The shown tab becomes the choice. So a Mark as sent does not move the panel to another tab.
  useEffect(() => {
    if (tab !== null && tab !== chosen) setDailyTab(tab)
  }, [tab, chosen])

  if (snap === null || body === 'loading') return <div className='h-full' />

  if (body === 'empty') {
    return (
      <div className='flex flex-col items-start gap-2 px-3 py-2'>
        <p className='text-xs text-text-dim'>{SET_UP}</p>
        <button
          className={cx(SMALL_BUTTON, 'text-xs')}
          onClick={() => settingsNav.open('daily-update')}
          type='button'
        >
          Open settings
        </button>
      </div>
    )
  }

  const failure = failureLine(snap, settings.dailyUpdate.source.server)
  return (
    <div className='flex h-full min-h-0 flex-col'>
      <StatusLine
        act={act}
        onUnplaced={() => setShowUnplaced(shown => !shown)}
        showUnplaced={showUnplaced}
        snap={snap}
      />
      {showUnplaced && snap.state.unplaced.length > 0 && (
        <div className='max-h-32 shrink-0 overflow-auto border-b border-panel-edge px-1 py-1'>
          <ItemList act={act} areaId='' items={snap.state.unplaced} />
        </div>
      )}
      {failure !== null && (
        <p
          className={cx(
            'shrink-0 border-b border-panel-edge px-2 py-1',
            'text-xs wrap-break-word text-text',
          )}
          data-daily-failure={true}
        >
          {failure}
        </p>
      )}
      <div
        className='flex h-[22px] shrink-0 items-stretch overflow-x-auto border-b border-panel-edge'
        role='tablist'
      >
        {snap.areas.map(area => (
          <button
            aria-selected={area.id === tab}
            className={cx(
              'flex shrink-0 items-center gap-1.5 border-b-2 px-2 text-xs active:bg-accent/12',
              area.id === tab
                ? 'border-text-strong text-text-strong'
                : 'border-transparent text-text-dim hover:text-text',
            )}
            data-daily-tab={area.id}
            key={area.id}
            onClick={() => setDailyTab(area.id)}
            role='tab'
            type='button'
          >
            {area.name}
            {tabMarker(snap, area.id) && (
              <>
                <span
                  aria-hidden={true}
                  className='size-1.5 shrink-0 bg-text-strong'
                  data-daily-tab-marker={true}
                />
                <span className='sr-only'>{NOT_SENT}</span>
              </>
            )}
          </button>
        ))}
      </div>
      <div className='min-h-0 flex-1 overflow-auto'>
        {snap.areas.map(area => (
          <AreaTab act={act} area={area} hidden={area.id !== tab} key={area.id} snap={snap} />
        ))}
      </div>
      <ErrorLine message={error} onClose={() => setError(null)} />
    </div>
  )
}
