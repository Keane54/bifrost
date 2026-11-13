import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { REVIEWS_ROWS } from '../../../src/renderer/src/settings/reviews-rows'

// The repository has no DOM test. So this test reads the source text of the section.
const SETTINGS = join(__dirname, '../../../src/renderer/src/settings')
const SECTION = readFileSync(join(SETTINGS, 'ReviewsSection.tsx'), 'utf8')

describe('Settings > Reviews', () => {
  it('has the labels from the spec', () => {
    expect(REVIEWS_ROWS).toEqual({
      autoFix: 'Handle comments on my PRs automatically',
      ignore: 'Repositories to ignore',
      maxSessions: 'Maximum PR sessions',
      pauseTime: 'Pause time',
      pollInterval: 'GitHub poll interval',
      removeClones: 'Remove all clones',
      requestModel: 'Model for request sessions',
      reviewModel: 'Model for review sessions',
      signedCommits: 'Sign commits through GitHub',
      teamRequests: 'Show team requests',
      watch: 'Watch GitHub',
    })
  })

  it('takes each row label from REVIEWS_ROWS, and uses each label', () => {
    const labels = [...SECTION.matchAll(/(?<![\w-])label=(\{[^}]*\}|'[^']*'|"[^"]*")/g)].map(
      m => m[1],
    )
    const used = new Set([...SECTION.matchAll(/REVIEWS_ROWS\.(\w+)/g)].map(m => m[1]))
    for (const label of labels) {
      expect(label, 'a label from REVIEWS_ROWS or props').toMatch(
        /^\{(?:REVIEWS_ROWS\.\w+|props\.label)\}$/,
      )
    }
    expect(used).toEqual(new Set(Object.keys(REVIEWS_ROWS)))
  })

  it('asks with useConfirm before it saves each turn-on of Watch GitHub', () => {
    expect(SECTION).toContain('useConfirm()')
    const ask = SECTION.indexOf('await confirm(')
    const save = SECTION.indexOf('update({ reviewsWatch: true })')
    expect(ask).toBeGreaterThan(-1)
    expect(save).toBeGreaterThan(ask)
    expect(SECTION).toContain('!settings.reviewsWatch')
  })

  // The hint of a row is a prop of the same element: it comes before the end of the element.
  function rowElement(row: string): string {
    const at = SECTION.indexOf(`label={REVIEWS_ROWS.${row}}`)
    expect(at, row).toBeGreaterThan(-1)
    return SECTION.slice(SECTION.lastIndexOf('<', at), SECTION.indexOf('/>', at))
  }

  it('has no later-version hint and the new hint on the auto-fix row', () => {
    expect(SECTION).not.toContain('Comes in a later version.')
    expect(SECTION).not.toContain('LATER')
    expect(SECTION).not.toContain('they have no effect yet')
    expect(rowElement('autoFix')).toContain(
      "hint='Claude fixes or answers new review comments on your pull requests. Bifrost then pushes the fixes and posts the replies.'",
    )
    for (const row of ['maxSessions', 'reviewModel', 'requestModel']) {
      expect(rowElement(row), row).not.toContain('hint=')
    }
    expect(SECTION).toMatch(/<SettingRow[\s\S]*?hint=\{props\.hint\}[\s\S]*?label=\{props\.label\}/)
  })

  it('asks with useConfirm before it saves each turn-on of the auto-fix row', () => {
    const start = SECTION.indexOf('label={REVIEWS_ROWS.autoFix}')
    const body = SECTION.slice(start, SECTION.indexOf('/>', start))
    const ask = body.indexOf('await confirm(AUTO_FIX_CONFIRM)')
    const save = body.indexOf('update({ reviewsAutoFix: true })')
    expect(ask).toBeGreaterThan(-1)
    expect(save).toBeGreaterThan(ask)
    expect(body).toContain('!settings.reviewsAutoFix')
    expect(SECTION).toContain("title: 'Handle comments automatically?'")
    expect(SECTION).toContain(
      "body: 'When someone reviews one of your pull requests, Claude fixes or answers each new comment. Bifrost then pushes the fixes to your branch, replies to each comment and resolves its thread. It never force-pushes, merges or approves. Comments from before now wait until you choose Handle now.'",
    )
  })

  it('has the Sign commits through GitHub row after the auto-fix row, with its hint', () => {
    const row = rowElement('signedCommits')
    expect(row).toContain('<CheckRow')
    expect(row).toContain('checked={settings.reviewsSignedCommits}')
    expect(row).toContain('save={value => update({ reviewsSignedCommits: value })}')
    expect(row).toContain('hint={SIGNED_COMMITS_HINT}')
    expect(SECTION).toContain(
      'const SIGNED_COMMITS_HINT =\n' +
        "  'Bifrost sends each fix to GitHub with your gh login, and GitHub signs the commit, " +
        "so it ' +\n" +
        `  "shows as Verified. You don't need a signing key."`,
    )
    for (const line of SECTION.split('\n')) {
      if (line.includes('SIGNED_COMMITS_HINT')) expect(line.length).toBeLessThanOrEqual(100)
    }
    const autoFix = SECTION.indexOf('label={REVIEWS_ROWS.autoFix}')
    expect(SECTION.indexOf('label={REVIEWS_ROWS.signedCommits}')).toBeGreaterThan(autoFix)
  })

  it('has the Remove all clones row with its hint and a Remove button', () => {
    expect(SECTION).toContain(
      `hint="Deletes Bifrost's own copies of your repositories. Your own checkouts aren't touched."`,
    )
    expect(SECTION).toContain('useRowSave(REVIEWS_ROWS.removeClones)')
    expect(SECTION).toContain('<RemoveClonesRow')
  })

  it(
    'asks with useConfirm before it calls removeClones, ' + 'and shows a refusal as the row error',
    () => {
      const ask = SECTION.indexOf('await confirm(REMOVE_CLONES_CONFIRM)')
      const call = SECTION.indexOf('window.bifrost.reviews.removeClones()')
      expect(ask).toBeGreaterThan(-1)
      expect(call).toBeGreaterThan(ask)
      expect(SECTION).toContain('row.save(() => window.bifrost.reviews.removeClones())')
      expect(SECTION).toContain("title: 'Remove all clones?'")
      expect(SECTION).toContain("confirm: 'Remove',")
      expect(SECTION).toContain(
        'Bifrost will delete its copies of your repositories, the review sessions that use them and any queued reviews. Your own checkouts and your draft reviews on GitHub stay as they are. While Watch GitHub is on, Bifrost copies the repositories of your open pull requests again.',
      )
    },
  )

  it('disables the Remove button while the confirm or the delete runs', () => {
    const start = SECTION.indexOf('function RemoveClonesRow(')
    const body = SECTION.slice(start, SECTION.indexOf('\nfunction ', start + 1))
    expect(body).toContain('const [busy, setBusy] = useState(false)')
    expect(body).toContain('disabled={busy}')
    const on = body.indexOf('setBusy(true)')
    expect(on).toBeGreaterThan(-1)
    expect(body.indexOf('await confirm(REMOVE_CLONES_CONFIRM)')).toBeGreaterThan(on)
    expect(body).toMatch(/finally \{\s*setBusy\(false\)/)
  })

  it('has the new body in the Watch GitHub confirm', () => {
    expect(SECTION).toContain(
      'Bifrost will use your gh login to check your review requests and your pull requests every few minutes. It makes its own copy of each of their repositories, and asks you to trust each copy once. When you click Review, Claude reviews the pull request and Bifrost saves a draft review that only you can see. On your own pull requests, Claude fixes or answers new review comments, and Bifrost pushes the fixes and posts the replies. Bifrost changes, sends or approves a review only when you click a button in the Review panel or Approve, and it never merges.',
    )
    expect(SECTION).not.toContain('It only reads for now')
  })

  it('has the ignore field, the Add button and the Remove button', () => {
    expect(SECTION).toContain("placeholder='owner/repo or owner/*'")
    expect(SECTION).toContain('Add')
    expect(SECTION).toContain("title='Remove'")
  })

  it('makes the model list with modelOptions', () => {
    expect(SECTION).toContain('modelOptions()')
    expect(SECTION).not.toContain('const MODEL_CHOICES')
  })

  it('has a RowFilterContext provider', () => {
    expect(SECTION).toContain('<RowFilterContext value={only}>')
  })
})
