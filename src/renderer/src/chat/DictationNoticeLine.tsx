// The dictation notice at the top of a chat panel (dictation design 7). It covers no part of
// Claude's prompt at the bottom, and it does not change the size of the terminal. Only its
// button takes pointer input. The component has no hooks.
import type { PrivacyPane } from '../../../shared/dictation-protocol'
import { cx } from '../lib/cx'
import { type NoticeLine, OPEN_SETTINGS_TEXT } from './dictation-notice'

interface DictationNoticeLineProps {
  line: NoticeLine
  // Open the pane of System Settings of a denied permission.
  openSettings(pane: PrivacyPane): void
}

export default function DictationNoticeLine({
  line,
  openSettings,
}: DictationNoticeLineProps): React.JSX.Element {
  const { pane } = line
  return (
    <div
      className={cx('pointer-events-none absolute inset-x-0 top-0 z-20 flex justify-center p-2')}
      data-dictation-notice={true}
      role='status'
    >
      <div
        className={cx(
          'flex max-w-full items-center gap-2 border border-panel-edge bg-bg/90 px-2 py-1',
        )}
      >
        <p className={cx('min-w-0 text-xs wrap-break-word text-text-dim')}>{line.text}</p>
        {pane !== null && (
          <button
            className={cx(
              'pointer-events-auto h-5 shrink-0 border border-panel-edge px-2 text-xs text-text',
              'hover:bg-hover active:bg-accent/12',
            )}
            data-dictation-settings={pane}
            onClick={() => openSettings(pane)}
            type='button'
          >
            {OPEN_SETTINGS_TEXT}
          </button>
        )}
      </div>
    </div>
  )
}
