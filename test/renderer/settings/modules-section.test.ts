// Settings > Modules (plan Task 9, Modules design 7): the rows of the modules, the Permissions
// view, the install buttons and the texts. The views render to static markup. The test reads the
// source text for the wiring, as the tests of the other Settings sections do.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  ModuleRowView,
  type ModuleRowViewProps,
  ModulesActionsView,
} from '../../../src/renderer/src/settings/ModulesSection'
import {
  checkUpdateLines,
  checkUpdateNotes,
  countWord,
  jobsTodayText,
  MODULES_EMPTY,
  MODULES_ROWS,
  PERMISSION_LABELS,
  pendingUpdateLine,
} from '../../../src/renderer/src/settings/modules-rows'
import { PERMISSION_IDS } from '../../../src/shared/module-manifest'
import type { ModuleRow } from '../../../src/shared/modules'

const SETTINGS = join(__dirname, '../../../src/renderer/src/settings')
const PANEL = readFileSync(join(SETTINGS, 'SettingsPanel.tsx'), 'utf8')
const NAV = readFileSync(join(SETTINGS, 'settings-nav.tsx'), 'utf8')
const SEARCH = readFileSync(join(SETTINGS, 'search.ts'), 'utf8')
const SECTION = readFileSync(join(SETTINGS, 'ModulesSection.tsx'), 'utf8')

function row(over: Partial<ModuleRow> = {}): ModuleRow {
  return {
    dailyCap: 50,
    description: 'Says hello.',
    dev: false,
    enabled: true,
    granted: ['notify'],
    id: 'hello',
    jobsToday: 3,
    model: 'sonnet',
    name: 'Hello',
    offReason: null,
    panels: [{ entry: 'panels/main.html', icon: 'star', id: 'main', title: 'Hello board' }],
    pendingUpdate: null,
    requested: [
      { id: 'notify', reason: 'To tell you when it is done.' },
      { id: 'claude-jobs-auto', reason: 'To check the list each hour.' },
    ],
    source: '~/Developer/hello',
    sourceKind: 'folder',
    tier: 'standard',
    version: '1.2.0',
    waitingJobs: 0,
    ...over,
  }
}

const noop = (): void => {}

function rowHtml(over: Partial<ModuleRowViewProps> = {}): string {
  const props: ModuleRowViewProps = {
    onCap: async () => true,
    onEnabled: noop,
    onModel: noop,
    onPermission: noop,
    onRemove: noop,
    onReviewUpdate: noop,
    onToggle: noop,
    open: false,
    row: row(),
    ...over,
  }
  return renderToStaticMarkup(createElement(ModuleRowView, props))
}

describe('the texts', () => {
  it('has the labels of the buttons', () => {
    expect(MODULES_ROWS).toEqual({
      checkUpdates: 'Check for updates',
      installDev: 'Load from folder (developer)',
      installFolder: 'Install from a folder',
      installGit: 'Install from a git repo',
    })
    expect(MODULES_EMPTY).toBe("You haven't installed any modules yet.")
  })

  it('has a friendly label for each permission, with the name "module jobs"', () => {
    expect(Object.keys(PERMISSION_LABELS).sort()).toEqual([...PERMISSION_IDS].sort())
    expect(PERMISSION_LABELS['claude-jobs-auto']).toBe('Run module jobs automatically')
    expect(PERMISSION_LABELS['claude-jobs']).toBe(
      'Run module jobs (short Claude runs with no tools)',
    )
    expect(PERMISSION_LABELS.notify).toBe('Show notifications')
    for (const label of Object.values(PERMISSION_LABELS)) {
      expect(label).not.toMatch(/Claude job/)
    }
  })

  it('says how many new permissions a waiting update needs', () => {
    const one = row({
      pendingUpdate: { added: [{ id: 'read-usage', reason: 'x' }], version: '1.3.0' },
    })
    expect(pendingUpdateLine(one)).toBe(
      "v1.3.0 needs one new permission. You'll keep using v1.2.0 until you allow it.",
    )
    const two = row({
      pendingUpdate: {
        added: [
          { id: 'read-usage', reason: 'x' },
          { id: 'discuss', reason: 'y' },
        ],
        version: '2.0.0',
      },
    })
    expect(pendingUpdateLine(two)).toBe(
      "v2.0.0 needs two new permissions. You'll keep using v1.2.0 until you allow it.",
    )
    expect(pendingUpdateLine(row())).toBeNull()
  })

  it('says it another way for a dev module, whose new code already runs in place', () => {
    const dev = (n: number) =>
      row({
        dev: true,
        pendingUpdate: {
          added: Array.from({ length: n }, () => ({ id: 'read-usage' as const, reason: 'x' })),
          version: '1.3.0',
        },
        sourceKind: 'dev',
      })
    expect(pendingUpdateLine(dev(1))).toBe(
      "This module's new version asks for one more permission. Allow it to keep using the module.",
    )
    expect(pendingUpdateLine(dev(2))).toBe(
      "This module's new version asks for two more permissions. Allow it to keep using the module.",
    )
  })

  it('writes small counts as words', () => {
    expect([1, 2, 3, 7, 12].map(countWord)).toEqual(['one', 'two', 'three', 'seven', '12'])
  })

  it('gives the module jobs of today', () => {
    expect(jobsTodayText(0)).toBe('0 module jobs today')
    expect(jobsTodayText(1)).toBe('1 module job today')
    expect(jobsTodayText(3)).toBe('3 module jobs today')
  })

  it('gives each line of Check for updates its own key', () => {
    const notes = checkUpdateNotes([
      { id: 'a', name: 'Same name', outcome: 'failed', reason: 'No.' },
      { id: 'b', name: 'Same name', outcome: 'failed', reason: 'No.' },
      { id: 'c', name: 'C', outcome: 'same', version: '1.0.0' },
    ])
    expect(notes).toEqual([
      { key: 'a', text: "Bifrost couldn't check Same name. No." },
      { key: 'b', text: "Bifrost couldn't check Same name. No." },
    ])
    expect(checkUpdateNotes([])).toEqual([{ key: 'none', text: 'You have no modules to check.' }])
    expect(SECTION).not.toContain('key={line}')
    expect(SECTION).toContain('key={note.key}')
  })

  it('gives the lines of Check for updates', () => {
    expect(checkUpdateLines([])).toEqual(['You have no modules to check.'])
    expect(checkUpdateLines([{ id: 'a', name: 'A', outcome: 'same', version: '1.0.0' }])).toEqual([
      'All your modules are up to date.',
    ])
    expect(
      checkUpdateLines([
        { id: 'a', name: 'A', outcome: 'same', version: '1.0.0' },
        { id: 'b', name: 'B', outcome: 'updated', version: '1.1.0' },
        { id: 'c', name: 'C', outcome: 'waiting', version: '2.0.0' },
        { id: 'd', name: 'D', outcome: 'failed', reason: 'The module has no files.' },
      ]),
    ).toEqual([
      'B is now on v1.1.0.',
      'C v2.0.0 needs your OK before it runs.',
      "Bifrost couldn't check D. The module has no files.",
    ])
  })
})

describe('a module row', () => {
  it('shows the name, the version, the source, the tier badge, Permissions and the switch', () => {
    const html = rowHtml()
    expect(html).toContain('Hello')
    expect(html).toContain('v1.2.0')
    expect(html).toContain('~/Developer/hello')
    expect(html).toContain('Says hello.')
    expect(html).toContain('data-module-tier-badge="standard"')
    expect(html).toContain('>Standard<')
    expect(html).toContain('>Permissions<')
    expect(html).toContain('data-module-switch="hello"')
    expect(html).toMatch(/aria-checked="true"/)
    expect(html).toContain('>On<')
  })

  it('gives the tier badge more padding than a plain label', () => {
    const tag = /<span[^>]*data-module-tier-badge[^>]*>/.exec(rowHtml())?.[0] ?? ''
    expect(tag).toMatch(/\bpx-2\.5\b/)
    expect(tag).toMatch(/\bpy-0\.5\b/)
    expect(tag).toMatch(/\bborder\b/)
  })

  it('shows Off for a module that is off, and the reason when Bifrost keeps it off', () => {
    expect(rowHtml({ row: row({ enabled: false }) })).toContain('>Off<')
    const dev = rowHtml({
      row: row({
        dev: true,
        enabled: false,
        offReason: 'This developer module runs only in a development build of Bifrost.',
        sourceKind: 'dev',
      }),
    })
    expect(dev).toContain('This developer module runs only in a development build of Bifrost.')
  })

  it('shows the waiting update and its Check update button', () => {
    const html = rowHtml({
      row: row({
        pendingUpdate: { added: [{ id: 'read-usage', reason: 'x' }], version: '1.3.0' },
      }),
    })
    expect(html).toContain(
      'v1.3.0 needs one new permission. You&#x27;ll keep using v1.2.0 until you allow it.',
    )
    expect(html).toContain('data-module-review-update="hello"')
    expect(html).toContain('>Check update<')
  })

  it('hides the Permissions view until the user opens it', () => {
    const html = rowHtml()
    expect(html).not.toContain('data-module-permissions')
    expect(html).toContain('aria-expanded="false"')
  })

  it('shows each permission with its reason, a switch, the model, the cap and jobs today', () => {
    const html = rowHtml({ open: true })
    expect(html).toContain('data-module-permissions="hello"')
    expect(html).toContain('aria-expanded="true"')
    expect(html).toContain('Show notifications')
    expect(html).toContain('To tell you when it is done.')
    expect(html).toContain('Run module jobs automatically')
    expect(html).toContain('To check the list each hour.')
    // notify is granted, claude-jobs-auto is not.
    expect(html).toMatch(/data-module-permission="notify"[\s\S]*?aria-checked="true"/)
    expect(html).toMatch(/data-module-permission="claude-jobs-auto"[\s\S]*?aria-checked="false"/)
    expect(html).toContain('Model for module jobs')
    expect(html).toContain('<option value="sonnet" selected="">Sonnet</option>')
    expect(html).toContain('Claude Code default')
    expect(html).toContain('Daily cap of module jobs')
    expect(html).toContain('value="50"')
    expect(html).toContain('3 module jobs today')
    expect(html).toContain('>Remove<')
  })

  it('says so when the module asks for no permission', () => {
    const html = rowHtml({ open: true, row: row({ granted: [], requested: [] }) })
    expect(html).toContain('This module doesn&#x27;t ask for any permissions.')
  })
})

describe('the install buttons', () => {
  const html = (packaged: boolean): string =>
    renderToStaticMarkup(
      createElement(ModulesActionsView, {
        busy: false,
        onCheck: noop,
        onDev: noop,
        onFolder: noop,
        onGit: async () => true,
        packaged,
      }),
    )

  it('shows the folder, git and check buttons in each build', () => {
    for (const packaged of [true, false]) {
      expect(html(packaged)).toContain('>Install from a folder<')
      expect(html(packaged)).toContain('>Install from a git repo<')
      expect(html(packaged)).toContain('>Check for updates<')
    }
  })

  it('shows Load from folder (developer) only when the app is not packaged', () => {
    expect(html(false)).toContain('>Load from folder (developer)<')
    expect(html(true)).not.toContain('Load from folder')
  })
})

describe('the wiring of the section', () => {
  it('adds Modules in the five places of a Settings section', () => {
    expect(NAV).toMatch(/\| 'modules'/)
    expect(PANEL).toMatch(/const TABS: SettingsSection\[\] = \[[^\]]*'modules',/)
    expect(PANEL).toContain("hit.id === 'modules' && <ModulesSection />")
    expect(PANEL).toContain("section === 'modules' && <ModulesSection />")
    expect(SEARCH).toContain("modules: 'Modules'")
  })

  it('calls the modules API of the preload, and opens Heimdall for an approval', () => {
    for (const call of [
      'installFolder()',
      'installGit(',
      'installDev()',
      'checkUpdates()',
      'reviewUpdate(',
      'setEnabled(',
      'revoke(',
      'grant(',
      'setModel(',
      'setCap(',
      'remove(',
    ]) {
      expect(SECTION, call).toContain(call)
    }
    expect(SECTION).toContain('showApproval(')
    expect(SECTION).toContain('useModules()')
  })

  it('asks before it removes a module', () => {
    expect(SECTION).toContain('useConfirm()')
  })
})
