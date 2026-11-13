import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

// The repository has no DOM test. So this test reads the source text of the panel.
const dir = join(__dirname, '../../../src/renderer/src/reviews')
const ROW = readFileSync(join(dir, 'ReviewRow.tsx'), 'utf8')
const PANEL = readFileSync(join(dir, 'ReviewsPanel.tsx'), 'utf8')

describe('Reviews panel source', () => {
  it('puts the flash class on an aria-hidden overlay', () => {
    expect(ROW).toMatch(/<span[^>]*aria-hidden=\{true\}[^>]*animate-box-flash[^>]*bg-box-red\/35/s)
  })

  it('shows the flash only with the rowFlash setting', () => {
    expect(ROW).toContain('settings.rowFlash')
    expect(ROW).toMatch(/flash\s*&&\s*settings\.rowFlash/)
  })

  it('opens the PR on a Cmd+click', () => {
    expect(ROW).toMatch(/metaKey[\s\S]{0,200}openPr/)
  })

  it('shows the truncated tip on the status of a My PRs row', () => {
    expect(ROW).toMatch(
      /<Tip label=\{truncatedText\(row\)\}>\s*<span[^>]*STATUS_TEXT\[row\.status\]/,
    )
  })

  it('shows the team tag for each team request, not only in the team state', () => {
    expect(ROW).toMatch(/extra=\{\s*row\.team && \(/)
    expect(ROW).not.toContain("row.state === 'team' &&")
  })

  it('keeps the right side of line 2 in view when the row is narrow', () => {
    const lines = [
      ...ROW.matchAll(/<div className='relative flex [^']*whitespace-nowrap text-text-dim'/g),
    ].map(m => m[0])
    expect(lines).toHaveLength(2)
    for (const line of lines) expect(line).toMatch(/\bmin-w-0\b.*\boverflow-hidden\b/)
    expect(ROW).toMatch(/<span className='min-w-0 truncate'>\{row\.author\}<\/span>/)
    expect(ROW).toMatch(/<ReviewerNames reviewers=\{row\.reviewers\} \/>/)
    expect(ROW).toMatch(/<span className='min-w-0 truncate'>/)
    // The state on the right does not shrink.
    expect(ROW.match(/ml-auto[^']*shrink-0|shrink-0[^']*ml-auto/g)).toHaveLength(2)
  })

  it('takes the body from panelBody', () => {
    expect(PANEL).toContain('panelBody(snapshot, rows.length)')
    expect(PANEL).toContain("kind === 'error'")
    expect(PANEL.indexOf("kind === 'error'")).toBeLessThan(PANEL.indexOf('Nothing needs you here.'))
  })

  it('opens Settings from the off state', () => {
    expect(PANEL).toContain('useSettingsNav')
  })

  it('shows the hint of the automatic fixes on the My PRs tab only', () => {
    expect(PANEL).toMatch(/tab === 'mine' && snapshot\.autoFixConfirm/)
    expect(PANEL).toContain('{AUTO_FIX_HINT}')
    expect(PANEL).toMatch(/AUTO_FIX_HINT[\s\S]{0,600}settingsNav\.open\('reviews'\)/)
  })

  it('starts a review with the Review button and has no Coming soon tip', () => {
    expect(ROW).toMatch(/(reviews|api)\.review\(row\.key\)/)
    expect(ROW).not.toContain('Coming soon')
    expect(ROW).toContain('Try again')
  })

  it('approves only from the Approve button and the Approve menu item, on a click', () => {
    expect(ROW).toContain("case 'Approve':")
    expect(ROW.match(/\.approve\(row\.key\)/g)).toHaveLength(2)
    expect(ROW).toMatch(/id === 'Approve'\) return row\.approve === 'running'/)
    expect(ROW).toMatch(/tip=\{id === 'Approve' \? approveTip\(row\)/)
  })

  it('renders the items of menuItems', () => {
    expect(ROW).toContain('menuItems(row)')
    for (const label of [
      'Open on GitHub',
      'Open session',
      'Review',
      'Cancel review',
      'Stop session',
      'Pause',
      'End pause now',
    ]) {
      expect(ROW).toContain(`'${label}'`)
    }
    expect(ROW).toMatch(/api\.cancel\(row\.key\)/)
    expect(ROW).toMatch(/api\.stopSession\(row\.key\)/)
    expect(ROW).toMatch(/run\('open', row\.sessionId\)/)
  })

  it('colours each result with the review tokens and tips the right text (ruling B1)', () => {
    expect(ROW).toContain('text-box-red')
    expect(ROW).toMatch(/state === 'failed'\) return 'text-box-red'/)
    for (const token of ['review-approve', 'review-comment', 'review-changes']) {
      expect(ROW).toContain(`text-${token}`)
      expect(ROW).toContain(`border-${token}`)
    }
    expect(ROW).toMatch(/<Tip label=\{rowTip\(row\)\}>/)
    // Red is allowed for a request-changes row (user decision, 2026-11-13).
    expect(ROW).not.toContain('Red is only for the flash')
  })

  it('centres the state text and the button of a row on one line (ruling B2)', () => {
    expect(ROW).toMatch(/<span className='ml-auto flex shrink-0 items-center gap-1\.5[^']*'>/)
    expect(ROW).toMatch(/<span className=\{cx\('leading-4', textColour\(row\)\)\}>/)
    expect(ROW).toMatch(/SMALL_BUTTON = cx\(\s*'[^']*leading-4/)
  })

  it('opens the Review panel from the Comment and the Request changes buttons and items', () => {
    expect(ROW).toContain('setDraftKey(key)')
    expect(ROW).toMatch(/panelId: 'review-draft', type: 'open'/)
    expect(ROW.match(/openDraft\(row\.key\)/g)).toHaveLength(2)
    expect(ROW).toContain('rowButtons(row)')
    expect(ROW).toContain("case 'Comment':")
    expect(ROW).toContain("case 'Request changes':")
    expect(ROW).toContain('resultLine(row)')
  })

  it('shows a coloured dot for each result, as in the approved mock (fix round 1)', () => {
    expect(ROW).toMatch(/const RESULT_DOT: Record<RowResult, string> = \{/)
    for (const dot of ['bg-review-approve', 'bg-review-comment', 'bg-review-changes']) {
      expect(ROW).toContain(`'${dot}'`)
    }
    expect(ROW).toMatch(/others: 'bg-text-dim'/)
    expect(ROW).toContain('data-review-dot')
  })

  it('removes a row only with the Remove button or the Remove item, with the PR key', () => {
    expect(ROW).toContain("case 'Remove':")
    expect(ROW.match(/\.remove\(row\.key\)/g)).toHaveLength(2)
  })

  it('renders the items of mineMenuItems with the eight labels', () => {
    expect(ROW).toContain('mineMenuItems(row)')
    for (const label of [
      'Open on GitHub',
      'Open session',
      'Answer Claude',
      'Handle now',
      'Handle Copilot comments',
      'Try again',
      'Cancel',
      'Stop session',
    ]) {
      expect(ROW).toContain(`'${label}'`)
    }
  })

  it('calls the Reviews API for the actions of a My PRs row', () => {
    expect(ROW).toMatch(/api\.handle\(row\.key, 'all'\)/)
    expect(ROW).toMatch(/api\.handle\(row\.key, 'copilot'\)/)
    expect(ROW).toMatch(/api\.retry\(row\.key\)/)
    expect(ROW).toMatch(/api\.cancel\(row\.key\)/)
    expect(ROW).toMatch(/api\.stopSession\(row\.key\)/)
  })

  it('opens the answer panel from the menu and from a click on a row with questions', () => {
    expect(ROW).toContain('setAnswerKey(')
    expect(ROW).toMatch(/panelId: 'answer'/)
    expect(ROW).toMatch(/row\.questions\.length > 0/)
    expect(ROW).toContain('onOpenAnswer')
  })

  it('shows olderText after the Copilot count and tips the Claude state', () => {
    expect(ROW).toContain('olderText(row.olderOpen)')
    expect(ROW.indexOf('olderText(row.olderOpen)')).toBeGreaterThan(
      ROW.indexOf('laterCopilotText('),
    )
    expect(ROW).toMatch(/<Tip label=\{claudeTip\(row\)\}>/)
    expect(ROW).toContain("claude === 'error'")
  })
})

describe('Review panel source (user decision, 2026-11-13)', () => {
  const REVIEW = readFileSync(join(dir, 'ReviewPanel.tsx'), 'utf8')
  const KEY = readFileSync(join(dir, 'draft-key.ts'), 'utf8')

  it('reads the draft from GitHub when it opens, and drops a late answer for another PR', () => {
    expect(REVIEW).toContain('reviews.draft(key)')
    expect(REVIEW).toMatch(/let live = true[\s\S]*live = false/)
  })

  it('sends the edits of the panel with the PR key only', () => {
    expect(REVIEW).toContain('sendDraft(key, editsOf(')
    expect(REVIEW).toContain('discardDraft(key)')
    expect(REVIEW).toContain('approveInstead(key)')
  })

  it('asks first only when the user added a comment to the draft on GitHub', () => {
    expect(REVIEW).toMatch(/yoursCount\(draft\) > 0/)
  })

  it('closes after a result that worked, and keeps the edits after a failure', () => {
    expect(REVIEW).toMatch(/panelId: 'review-draft', type: 'close'/)
    expect(REVIEW).toMatch(/if \(result\.ok\) close\(\)\s+else setError\(result\.message\)/)
  })

  it('locks the actions when the row of the snapshot no longer offers the draft', () => {
    expect(REVIEW).toContain('useReviews()')
    expect(REVIEW).toMatch(/\.draft !== 'ready'/)
    expect(REVIEW).toMatch(/locked=\{locked\}/)
  })

  it('keeps the key in a store and clears it when the panel closes', () => {
    expect(KEY).toContain('export function setDraftKey')
    expect(KEY).toContain('export function useDraftKey')
    expect(REVIEW).toMatch(/useEffect\(\(\) => \(\) => setDraftKey\(null\), \[\]\)/)
  })
})
