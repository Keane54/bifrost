// Heimdall's panel and its approval view (plan Task 9, Modules design 7 and 8.4). The view is
// Bifrost's own UI in the purple Heimdall frame. Only the approved texts of the manifest show, as
// plain text, with an icon of the fixed set.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  ApprovalView,
  approvalButtons,
  approvalIntro,
  approvalTitle,
  NEVER_ITEMS,
} from '../../../src/renderer/src/modules/HeimdallPanel'
import {
  getHeimdallRequest,
  setHeimdallRequest,
} from '../../../src/renderer/src/modules/heimdall-key'
import type { ModuleApproval } from '../../../src/shared/modules'

const SRC = join(__dirname, '../../../src/renderer/src')
const PANEL = readFileSync(join(SRC, 'modules/HeimdallPanel.tsx'), 'utf8')
const PANELS = readFileSync(join(SRC, 'panels/panels.tsx'), 'utf8')
const FRAME = readFileSync(join(SRC, 'wm/Frame.tsx'), 'utf8')
const CSS = readFileSync(join(SRC, 'styles/app.css'), 'utf8')

function approval(over: Partial<ModuleApproval> = {}): ModuleApproval {
  return {
    description: 'Says hello.',
    fromVersion: null,
    icon: 'star',
    kind: 'install',
    moduleId: 'hello',
    name: 'Hello',
    permissions: [
      { added: false, id: 'notify', reason: 'To tell you when it is done.' },
      { added: false, id: 'claude-jobs', reason: 'To sum up the list.' },
    ],
    requestId: 'r1',
    source: '/Users/someone/hello',
    sourceKind: 'folder',
    tier: 'standard',
    version: '1.0.0',
    ...over,
  }
}

const UPDATE = approval({
  fromVersion: '1.2.0',
  kind: 'update',
  permissions: [
    { added: false, id: 'notify', reason: 'To tell you when it is done.' },
    { added: true, id: 'read-usage', reason: 'To show your plan usage.' },
  ],
  version: '1.3.0',
})

const noop = (): void => {}

function html(a: ModuleApproval, error: string | null = null): string {
  return renderToStaticMarkup(
    createElement(ApprovalView, {
      approval: a,
      busy: false,
      error,
      onAllow: noop,
      onCancel: noop,
      onCloseError: noop,
    }),
  )
}

describe('the texts of an approval', () => {
  it('gives the title with the version, and the versions of an update', () => {
    expect(approvalTitle(approval())).toBe('Hello v1.0.0')
    expect(approvalTitle(UPDATE)).toBe('Hello v1.2.0 → v1.3.0')
  })

  it('gives the intro of an install and of an update', () => {
    expect(approvalIntro(approval())).toBe(
      'Check what this module asks for. It runs only after you allow it.',
    )
    expect(approvalIntro(UPDATE)).toBe(
      'This update asks for one new permission. Everything else stays the same.',
    )
    const two = {
      ...UPDATE,
      permissions: [
        { added: true, id: 'read-usage' as const, reason: 'x' },
        { added: true, id: 'discuss' as const, reason: 'y' },
      ],
    }
    expect(approvalIntro(two)).toBe(
      'This update asks for two new permissions. Everything else stays the same.',
    )
  })

  it('gives the buttons of an install and of an update', () => {
    expect(approvalButtons(approval())).toEqual({ allow: 'Allow', cancel: 'Cancel' })
    expect(approvalButtons(UPDATE)).toEqual({ allow: 'Allow and update', cancel: 'Stay on v1.2.0' })
  })

  it('has the fixed list of what a module can never do', () => {
    expect(NEVER_ITEMS).toEqual([
      'See your tokens, keys or logins',
      'Read files on your Mac (it sees only a file that you pick or drop on it)',
      'Type into a Claude session',
      'Change Bifrost',
    ])
  })
})

describe('the approval view', () => {
  it('shows the tier, each permission with its reason, and what it can never do', () => {
    const out = html(approval())
    expect(out).toContain('data-heimdall-approval="r1"')
    expect(out).toContain('data-module-tier-badge="standard"')
    expect(out).toContain('>Standard<')
    expect(out).toContain('Says hello.')
    expect(out).toContain('What it can do')
    expect(out).toContain('Show notifications')
    expect(out).toContain('To tell you when it is done.')
    expect(out).toContain('Run module jobs (short Claude runs with no tools)')
    expect(out).toContain('To sum up the list.')
    expect(out).toContain('What it can never do')
    for (const item of NEVER_ITEMS) expect(out).toContain(item)
    expect(out).toContain('>Cancel<')
    expect(out).toContain('>Allow<')
    expect(out).toContain('From the folder /Users/someone/hello')
  })

  it('marks the new permissions of an update', () => {
    const out = html(UPDATE)
    const tag = (id: string): string =>
      new RegExp(`<li[^>]*data-approval-permission="${id}"[^>]*>`).exec(out)?.[0] ?? ''
    expect(tag('read-usage')).toContain('data-approval-new="true"')
    expect(tag('notify')).toContain('data-approval-new="false"')
    expect(out).toContain('New:')
    expect(out).toContain('>Stay on v1.2.0<')
    expect(out).toContain('>Allow and update<')
  })

  it('shows its own panels and storage when the module asks for nothing more', () => {
    const out = html(approval({ permissions: [] }))
    expect(out).toContain('Show its own panels and keep a little data of its own')
    expect(out).not.toContain('data-approval-permission=')
  })

  it('names the source of a git and a developer module', () => {
    expect(html(approval({ source: 'https://github.com/a/b', sourceKind: 'git' }))).toContain(
      'From https://github.com/a/b',
    )
    expect(html(approval({ sourceKind: 'dev' }))).toContain(
      'Developer folder /Users/someone/hello. Bifrost uses it in place.',
    )
  })

  it('shows the module texts as plain text only', () => {
    const out = html(approval({ description: '<img src=x onerror=alert(1)>', name: '<b>x</b>' }))
    expect(out).not.toContain('<img')
    expect(out).not.toContain('<b>x</b>')
    expect(out).toContain('&lt;img')
    expect(PANEL).not.toContain('dangerouslySetInnerHTML')
  })

  it('shows an error line', () => {
    expect(html(approval(), 'That request isn’t open any more.')).toContain('data-error-line')
  })
})

describe('the Heimdall request store', () => {
  it('keeps one request, and null clears it', () => {
    setHeimdallRequest({ approval: approval(), kind: 'approval' })
    expect(getHeimdallRequest()?.kind).toBe('approval')
    setHeimdallRequest(null)
    expect(getHeimdallRequest()).toBeNull()
  })
})

describe('the Heimdall frame', () => {
  it('replaces the placeholder with the Heimdall panel', () => {
    expect(PANELS).toContain("case 'heimdall':\n      return <HeimdallPanel />")
    expect(PANELS).not.toContain('HeimdallPlaceholder')
  })

  it('gives the frame of the Heimdall panel the purple border and title bar', () => {
    expect(CSS).toMatch(/--color-heimdall: #[0-9a-f]{6};/)
    expect(CSS).toMatch(/--color-heimdall-title: #[0-9a-f]{6};/)
    expect(FRAME).toContain("panelKind(frame.active) === 'heimdall'")
    expect(FRAME).toContain('border-heimdall')
    expect(FRAME).toContain('bg-heimdall-title')
  })

  it('opens the panel for an approval and clears the request when it closes', () => {
    expect(PANEL).toContain("dispatch({ panelId: 'heimdall', type: 'open' })")
    expect(PANEL).toContain('useEffect(() => () => setHeimdallRequest(null), [])')
    expect(PANEL).toContain('approve(')
    expect(PANEL).toContain('decline(')
  })
})
