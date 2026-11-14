// The Discuss view of Heimdall's panel (plan Task 10, Modules design 8.4). It is Bifrost's own UI
// in the purple Heimdall frame. The cards of the module show as plain text with Copy buttons, and
// the main process does the copy. The prompt box starts empty, and a paste into it loses its
// invisible characters. The user picks the folder. The session uses the normal Claude setup.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it } from 'vitest'
import {
  canStartDiscuss,
  closeDiscussView,
  DISCUSS_SETUP,
  DiscussView,
  type DiscussViewProps,
  heimdallTitle,
  initialDiscussForm,
  pastePrompt,
  showDiscuss,
} from '../../../src/renderer/src/modules/HeimdallPanel'
import {
  getHeimdallRequest,
  setHeimdallRequest,
} from '../../../src/renderer/src/modules/heimdall-key'
import type { WmAction } from '../../../src/renderer/src/wm/state'
import type { ModuleApproval, ModuleDiscuss } from '../../../src/shared/modules'

// The source of the panel with each run of white space as one space.
const PANEL = readFileSync(
  join(__dirname, '../../../src/renderer/src/modules/HeimdallPanel.tsx'),
  'utf8',
).replace(/\s+/g, ' ')

const DISCUSS: ModuleDiscuss = {
  cards: [
    { label: 'Notes', text: 'Line one\n<b>not bold</b>' },
    { label: 'Links', text: 'https://example.com/a' },
  ],
  moduleId: 'demo',
  moduleName: 'Demo',
  requestId: 'req-1',
  title: 'Plan the week',
}

const APPROVAL: ModuleApproval = {
  description: 'Says hello.',
  fromVersion: null,
  icon: 'star',
  kind: 'install',
  moduleId: 'hello',
  name: 'Hello',
  permissions: [],
  requestId: 'a1',
  source: '/Users/someone/hello',
  sourceKind: 'folder',
  tier: 'standard',
  version: '1.0.0',
}

const noop = (): void => {}

function html(over: Partial<DiscussViewProps> = {}): string {
  return renderToStaticMarkup(
    createElement(DiscussView, {
      busy: false,
      copied: null,
      dirs: [],
      discuss: DISCUSS,
      error: null,
      form: initialDiscussForm(),
      onCancel: noop,
      onChoose: noop,
      onCloseError: noop,
      onCopy: noop,
      onCwd: noop,
      onPrompt: noop,
      onStart: noop,
      ...over,
    }),
  )
}

afterEach(() => setHeimdallRequest(null))

describe('the Discuss view', () => {
  it('shows the title, the module and each card as plain text with a Copy button', () => {
    const out = html()
    expect(out).toContain('data-heimdall-discuss="req-1"')
    expect(out).toContain('Plan the week')
    expect(out).toContain('Demo')
    expect(out).toContain('Notes')
    expect(out).toContain('Line one\n&lt;b&gt;not bold&lt;/b&gt;')
    expect(out).not.toContain('<b>not bold')
    expect(out).toContain('https://example.com/a')
    expect(out).not.toContain('<a ')
    expect(out).toContain('data-discuss-copy="0"')
    expect(out).toContain('data-discuss-copy="1"')
    expect(out.match(/>Copy</g)).toHaveLength(2)
  })

  it('shows Copied on the card that the user copied', () => {
    const out = html({ copied: 1 })
    expect(out.match(/>Copy</g)).toHaveLength(1)
    expect(out.match(/>Copied</g)).toHaveLength(1)
  })

  it('starts with an empty prompt box and no folder', () => {
    expect(initialDiscussForm()).toEqual({ cwd: '', prompt: '' })
    const out = html()
    expect(out).toMatch(/<textarea[^>]*data-discuss-prompt="true"[^>]*><\/textarea>/)
    expect(out).not.toMatch(/<textarea[^>]*placeholder/)
    expect(out).toMatch(/<input[^>]*data-discuss-folder="true"[^>]*value=""/)
  })

  it('has the folder picker, the normal setup line, Cancel and Start session', () => {
    const out = html({ dirs: ['/Users/someone/project'] })
    expect(out).toContain('>Choose...<')
    expect(out).toContain('<option value="/Users/someone/project">')
    expect(DISCUSS_SETUP).toBe('Your normal Claude setup')
    expect(out).toContain(DISCUSS_SETUP)
    expect(out).toContain('>Cancel<')
    expect(out).toContain('>Start session<')
  })

  it('turns Start session on only with a prompt and a folder', () => {
    const start = (out: string): string =>
      /<button[^>]*data-discuss-start="true"[^>]*>/.exec(out)?.[0] ?? ''
    // The class list holds "disabled:opacity-40", so the test looks for the attribute.
    expect(start(html())).toContain('disabled=""')
    const ready = { cwd: '/Users/someone/project', prompt: 'Help me plan.' }
    expect(start(html({ form: ready }))).not.toContain('disabled=""')
    expect(start(html({ busy: true, form: ready }))).toContain('disabled=""')
    expect(canStartDiscuss({ cwd: '', prompt: 'x' })).toBe(false)
    expect(canStartDiscuss({ cwd: '/p', prompt: '  \n' })).toBe(false)
    expect(canStartDiscuss({ cwd: '/p', prompt: 'x' })).toBe(true)
  })

  it('shows the text that the user typed', () => {
    const out = html({ form: { cwd: '/Users/someone/project', prompt: 'My words' } })
    expect(out).toMatch(/<textarea[^>]*>My words<\/textarea>/)
    expect(out).toContain('value="/Users/someone/project"')
  })

  it('shows an error line', () => {
    expect(html({ error: 'Choose a project folder.' })).toContain('Choose a project folder.')
  })
})

describe('a paste into the prompt box', () => {
  it('removes invisible characters and puts the caret after the paste', () => {
    expect(pastePrompt('Help  plan', 5, 5, 'me\u200B\u202E')).toEqual({
      caret: 7,
      value: 'Help me plan',
    })
    expect(pastePrompt('abc', 0, 3, 'x\uFEFFy\nz')).toEqual({ caret: 4, value: 'xy\nz' })
    const tags = String.fromCodePoint(0xe0041, 0xe0042)
    expect(pastePrompt('', 0, 0, `Hi${tags}`)).toEqual({ caret: 2, value: 'Hi' })
  })

  it('also strips each typed or dropped change, and reads the paste as plain text', () => {
    expect(PANEL).toContain('onPrompt(stripInvisible(e.target.value))')
    expect(PANEL).toContain("e.clipboardData.getData('text/plain')")
  })
})

describe('the page and the clipboard', () => {
  it('copies through the main process, and never writes markup from a module', () => {
    expect(PANEL).toContain('window.bifrost.modules.discussCopy(discuss.requestId, index)')
    expect(PANEL).not.toContain('navigator.clipboard')
    expect(PANEL).not.toContain('execCommand')
    expect(PANEL).not.toContain('dangerouslySetInnerHTML')
  })

  it('sends only the prompt and the folder at the start', () => {
    expect(PANEL).toContain('const input = { cwd: form.cwd.trim(), prompt: form.prompt }')
    expect(PANEL).toContain('window.bifrost.modules.discussStart(discuss.requestId, input)')
  })

  it('cancels the request when the view closes before a start', () => {
    expect(PANEL).toMatch(/if \(!done\.current\) cancelDiscuss\(discuss\.requestId\)/)
  })
})

describe('a new request', () => {
  it('gets a new key, so the prompt box starts empty after a cancel and a second request', () => {
    expect(PANEL).toContain(
      '<DiscussPanel discuss={request.discuss} key={request.discuss.requestId} />',
    )
    expect(PANEL).toContain('const [form, setForm] = useState(initialDiscussForm)')
  })
})

describe('closeDiscussView', () => {
  it('closes Heimdall only while it shows this request', () => {
    const actions: WmAction[] = []
    const dispatch = (a: WmAction): void => {
      actions.push(a)
    }
    // An approval opened during the start stays.
    setHeimdallRequest({ approval: APPROVAL, kind: 'approval' })
    closeDiscussView('req-1', dispatch)
    expect(getHeimdallRequest()).toEqual({ approval: APPROVAL, kind: 'approval' })
    // Another request stays.
    setHeimdallRequest({ discuss: { ...DISCUSS, requestId: 'req-2' }, kind: 'discuss' })
    closeDiscussView('req-1', dispatch)
    expect(getHeimdallRequest()?.kind).toBe('discuss')
    expect(actions).toEqual([])
    // This request closes.
    setHeimdallRequest({ discuss: DISCUSS, kind: 'discuss' })
    closeDiscussView('req-1', dispatch)
    expect(getHeimdallRequest()).toBeNull()
    expect(actions).toEqual([{ panelId: 'heimdall', type: 'close' }])
  })

  it('is the close of the start and of Cancel', () => {
    expect(PANEL).toContain(
      'const close = (): void => closeDiscussView(discuss.requestId, dispatch)',
    )
    expect(PANEL).not.toMatch(
      /function DiscussPanel[\s\S]*setHeimdallRequest\(null\)[\s\S]*function HeimdallPanel/,
    )
  })
})

describe('showDiscuss', () => {
  function fakes(): { actions: WmAction[]; cancelled: string[]; cancel(id: string): void } {
    const actions: WmAction[] = []
    const cancelled: string[] = []
    return { actions, cancel: id => cancelled.push(id), cancelled }
  }

  it('shows the request in Heimdall and opens its panel', () => {
    const f = fakes()
    showDiscuss(DISCUSS, a => f.actions.push(a), f.cancel)
    expect(getHeimdallRequest()).toEqual({ discuss: DISCUSS, kind: 'discuss' })
    expect(f.actions).toEqual([{ panelId: 'heimdall', type: 'open' }])
    expect(f.cancelled).toEqual([])
  })

  it('cancels the request and keeps an approval that shows', () => {
    const f = fakes()
    setHeimdallRequest({ approval: APPROVAL, kind: 'approval' })
    showDiscuss(DISCUSS, a => f.actions.push(a), f.cancel)
    expect(getHeimdallRequest()).toEqual({ approval: APPROVAL, kind: 'approval' })
    expect(f.actions).toEqual([])
    expect(f.cancelled).toEqual(['req-1'])
  })
})

describe('the title of Heimdall', () => {
  it('names the approval, or Discuss with Claude and the module', () => {
    expect(heimdallTitle({ approval: APPROVAL, kind: 'approval' })).toBe('Hello v1.0.0')
    expect(heimdallTitle({ discuss: DISCUSS, kind: 'discuss' })).toBe('Discuss with Claude · Demo')
  })
})
