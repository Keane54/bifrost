// The release notes view. It opens by itself one time after an update as "What's new", with the
// releases since the last seen version. Settings > Updates opens it as "Release notes", with the
// last 10 releases. The main process reads GitHub only when the view opens. Each GitHub page
// opens in the default browser through the main process. The view shows each text as plain text,
// with only bold and code, and never renders HTML.
import { Dialog } from '@base-ui/react/dialog'
import { ExternalLink } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import {
  type Release,
  RELEASE_NOTES_TEXTS as TEXTS,
  type WhatsNewStart,
} from '../../../shared/release-notes'
import { DIALOG_BACKDROP, DIALOG_BUTTON, DIALOG_POPUP } from '../actions/ConfirmDialog'
import { cx } from '../lib/cx'
import { useSettings } from '../settings/settings-context'
import { useSettingsNav } from '../settings/settings-nav'
import { inlineParts } from './inline'
import {
  formatReleaseDate,
  internalOnly,
  type ReleaseNotesView,
  viewReleases,
  viewTitle,
  whatsNewMayOpen,
} from './view'

// The style of the app dialogs, with a maximum width of 560 px for the notes.
const POPUP = DIALOG_POPUP.replace('max-w-[420px]', 'max-w-[560px]')
// The small button of a GitHub page, as the Open status page button of Service status.
const LINK_BUTTON = cx(
  'flex shrink-0 items-center gap-1 px-1 text-[11px] text-text-dim',
  'hover:bg-hover hover:text-text enabled:active:bg-accent/12',
)

type Load = { kind: 'loading' } | { kind: 'failed' } | { kind: 'ok'; releases: Release[] }

function openOnGitHub(version: string | null): void {
  window.bifrost.releaseNotes
    .open(version)
    .catch(err => console.error('Bifrost cannot open the GitHub page.', err))
}

// A text with bold and code. Each part goes to React as text.
function Inline({ text }: { text: string }): React.JSX.Element {
  let key = 0
  return (
    <>
      {inlineParts(text).map(part => {
        key += 1
        if (part.kind === 'bold') {
          return (
            <strong className='font-semibold text-text-strong' key={key}>
              {part.text}
            </strong>
          )
        }
        if (part.kind === 'code') {
          return (
            <code className='bg-panel px-1 font-mono text-[12px] text-text-strong' key={key}>
              {part.text}
            </code>
          )
        }
        return <span key={key}>{part.text}</span>
      })}
    </>
  )
}

function ReleaseBlock({ release }: { release: Release }): React.JSX.Element {
  let key = 0
  return (
    <section
      className='flex flex-col gap-2 border-t border-panel-edge pt-3 first:border-t-0 first:pt-0'
      data-release={release.version}
    >
      <div className='flex items-baseline gap-2'>
        <h3 className='font-semibold text-text-strong select-text'>Version {release.version}</h3>
        <span className='text-xs text-text-dim select-text'>{formatReleaseDate(release.date)}</span>
        <span className='flex-1' />
        <button
          className={LINK_BUTTON}
          data-release-github={release.version}
          onClick={() => openOnGitHub(release.version)}
          type='button'
        >
          <ExternalLink aria-hidden={true} size={11} />
          {TEXTS.viewOnGitHub}
        </button>
      </div>
      {release.summary !== '' && (
        <p className='whitespace-pre-line select-text' data-release-summary={true}>
          <Inline text={release.summary} />
        </p>
      )}
      {release.sections.map(section => (
        <div data-release-section={section.title} key={section.title}>
          <h4 className='text-xs font-semibold text-text-strong'>{section.title}</h4>
          <ul className='mt-1 flex flex-col gap-0.5'>
            {section.items.map(item => {
              key += 1
              return (
                <li className='flex gap-1.5 select-text' key={key}>
                  <span aria-hidden={true} className='text-text-dim'>
                    •
                  </span>
                  <span className='min-w-0 wrap-break-word'>
                    {item.scope !== null && (
                      <span className='mr-1.5 text-[11px] text-text-dim' data-release-scope={true}>
                        {item.scope}
                      </span>
                    )}
                    <Inline text={item.text} />
                  </span>
                </li>
              )
            })}
          </ul>
        </div>
      ))}
      {internalOnly(release) && <p className='text-text-dim'>{TEXTS.internal}</p>}
    </section>
  )
}

// A line of text and a button that opens the Releases page on GitHub.
function ReleasesPage({ text }: { text: string }): React.JSX.Element {
  return (
    <div className='flex flex-col items-start gap-2'>
      <p className='select-text'>{text}</p>
      <button className={LINK_BUTTON} onClick={() => openOnGitHub(null)} type='button'>
        <ExternalLink aria-hidden={true} size={11} />
        {TEXTS.releasesPage}
      </button>
    </div>
  )
}

export default function ReleaseNotesDialog(): React.JSX.Element {
  const { ready, settings } = useSettings()
  const { releaseNotesRequest } = useSettingsNav()
  const [visible, setVisible] = useState(false)
  const [view, setView] = useState<ReleaseNotesView>({ kind: 'all' })
  const [load, setLoad] = useState<Load>({ kind: 'loading' })
  // The What's new start that waits for the end of the setup dialog.
  const [pending, setPending] = useState<WhatsNewStart | null>(null)
  // A new open makes the answer of an old open stale.
  const generation = useRef(0)
  const closeRef = useRef<HTMLButtonElement>(null)

  // The list loads only when the view opens. The main process keeps a good answer 10 minutes.
  const open = useCallback((next: ReleaseNotesView) => {
    const gen = ++generation.current
    setView(next)
    setLoad({ kind: 'loading' })
    setVisible(true)
    window.bifrost.releaseNotes.list().then(
      result => {
        if (gen !== generation.current) return
        setLoad(result.ok ? { kind: 'ok', releases: result.releases } : { kind: 'failed' })
      },
      () => {
        if (gen === generation.current) setLoad({ kind: 'failed' })
      },
    )
  }, [])

  // Ask one time after the page loads. Only a release build after an update gives a start.
  useEffect(() => {
    window.bifrost.releaseNotes.whatsNew().then(
      start => {
        if (start !== null) setPending(start)
      },
      err => console.error("Bifrost cannot read the state of What's new.", err),
    )
  }, [])

  useEffect(() => {
    if (pending === null || !whatsNewMayOpen(ready, settings.setupDone)) return
    setPending(null)
    open({ kind: 'whats-new', start: pending })
  }, [open, pending, ready, settings.setupDone])

  // The Release notes button of Settings > Updates.
  useEffect(() => {
    if (releaseNotesRequest !== 0) open({ kind: 'all' })
  }, [open, releaseNotesRequest])

  const close = (): void => {
    generation.current += 1
    setVisible(false)
  }

  const shown = load.kind === 'ok' ? viewReleases(view, load.releases) : []
  return (
    <Dialog.Root
      onOpenChange={next => {
        if (!next) close()
      }}
      open={visible}
    >
      <Dialog.Portal>
        <Dialog.Backdrop className={DIALOG_BACKDROP} />
        <Dialog.Popup
          className={POPUP}
          data-release-notes={view.kind}
          data-release-notes-state={load.kind}
          initialFocus={closeRef}
        >
          <Dialog.Title className='font-semibold text-text-strong'>{viewTitle(view)}</Dialog.Title>
          <div className='-mx-4 flex max-h-[60vh] flex-col gap-3 overflow-y-auto px-4'>
            {load.kind === 'loading' && <p className='text-text-dim'>{TEXTS.loading}</p>}
            {load.kind === 'failed' && <ReleasesPage text={TEXTS.failed} />}
            {load.kind === 'ok' && shown.length === 0 && <ReleasesPage text={TEXTS.empty} />}
            {shown.map(release => (
              <ReleaseBlock key={release.version} release={release} />
            ))}
          </div>
          <div className='flex items-center justify-end gap-2'>
            <Dialog.Close className={DIALOG_BUTTON} ref={closeRef}>
              {TEXTS.close}
            </Dialog.Close>
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
