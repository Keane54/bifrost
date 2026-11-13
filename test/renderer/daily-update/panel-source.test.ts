// The Daily update panel, its side bar button and the route of a reminder (Daily update design,
// section 6.2). The repository has no DOM test, so this test reads the source text of the files.
// panel-model.test.ts tests the texts and the rules that these files use.
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const SRC = join(__dirname, '../../../src/renderer/src')
const read = (name: string): string => readFileSync(join(SRC, name), 'utf8')

const PANEL = read('daily-update/DailyUpdatePanel.tsx')
const DRAFT = read('daily-update/DraftView.tsx')
const SIDE_BAR = read('wm/SideBar.tsx')
const PANELS = read('panels/panels.tsx')
const ACTIONS = read('actions/actions-context.tsx')

// The source text from the first match of start to the first match of end after it.
function slice(text: string, start: string, end: string): string {
  const from = text.indexOf(start)
  expect(from).toBeGreaterThan(-1)
  const to = text.indexOf(end, from + start.length)
  expect(to).toBeGreaterThan(from)
  return text.slice(from, to)
}

describe('the draft', () => {
  it('no file of the panel puts text into the page as HTML', () => {
    for (const name of readdirSync(join(SRC, 'daily-update'))) {
      const text = read(`daily-update/${name}`)
      expect(text).not.toContain('dangerouslySetInnerHTML')
      expect(text).not.toContain('innerHTML')
    }
  })

  it('renders the parts of draftParts, and a bold part as strong', () => {
    expect(DRAFT).toContain("import { draftParts } from '../../../shared/daily-markup'")
    expect(DRAFT).toMatch(/draftParts\(draft\)\.map\(/)
    expect(DRAFT).toMatch(/part\.bold \? \([\s\S]{0,120}?<strong[^>]*>\s*\{part\.text\}/)
    expect(DRAFT).toMatch(/\{part\.text\}\s*<\/strong>/)
    expect(DRAFT).toMatch(/<span key=\{j\}>\{part\.text\}<\/span>/)
  })

  it('shows the Markdown in a text box after Edit, and Done saves a change', () => {
    expect(PANEL).toMatch(/<textarea[\s\S]*?value=\{text\}/)
    const done = slice(PANEL, 'function finishEdit', '\n  }\n')
    expect(done).toMatch(/dailyUpdate\.editDraft\(id, text\)/)
    expect(PANEL).toMatch(/editing \? 'Done' : 'Edit'/)
  })

  it('offers a new draft with Use new draft and Keep mine', () => {
    expect(PANEL).toMatch(/view\.pending !== undefined && \(/)
    expect(PANEL).toContain('{NEW_DRAFT}')
    expect(PANEL).toContain("label='Use new draft' onClick={onUseNew}")
    expect(slice(PANEL, 'function onUseNew', '\n  }\n')).toMatch(/dailyUpdate\.usePending\(id\)/)
    expect(PANEL).toMatch(/label='Keep mine'[\s\S]{0,200}dailyUpdate\.keepMine\(id\)/)
  })

  it('shows the text for an area with no draft', () => {
    expect(PANEL).toContain('{NO_DRAFT}')
  })
})

describe('the buttons of a tab', () => {
  it('Copy calls copy and shows Copied for COPIED_MS', () => {
    expect(PANEL).toMatch(/dailyUpdate\.copy\(id\)/)
    expect(PANEL).toMatch(/copied \? 'Copied' : 'Copy'/)
    expect(PANEL).toMatch(/setTimeout\(\(\) => setCopied\(false\), COPIED_MS\)/)
  })

  it('Mark as sent calls markSent, then the tab shows the send time and Undo', () => {
    expect(PANEL).toMatch(/label='Mark as sent'[\s\S]{0,200}dailyUpdate\.markSent\(id\)/)
    expect(PANEL).toContain('sentText(snap, id)')
    expect(PANEL).toMatch(
      /\{sentAt\}[\s\S]{0,400}label='Undo'[\s\S]{0,200}dailyUpdate\.undoSent\(id\)/,
    )
  })

  it('Redo draft asks first for a changed draft, with Replace and Cancel', () => {
    const redo = slice(PANEL, 'function onRedo', '\n  }\n')
    expect(redo).toContain('redoNeedsConfirm(view)')
    expect(redo).toContain('setConfirming(true)')
    expect(PANEL).toContain('{REDO_CONFIRM}')
    expect(PANEL).toMatch(/label='Replace'[\s\S]{0,200}runRedo\(\)/)
    expect(PANEL).toMatch(/label='Cancel'[\s\S]{0,200}setConfirming\(false\)/)
    expect(PANEL).toMatch(/dailyUpdate\.redo\(id\)/)
  })

  it('Send is off and its tip says why', () => {
    expect(PANEL).toMatch(/disabled=\{true\}[\s\S]{0,200}label=\{sendText\(area\.channel\)\}/)
    expect(PANEL).toContain('tip={SEND_TIP}')
  })

  it('a click on an item with a link opens it', () => {
    expect(PANEL).toMatch(/item\.url === undefined/)
    expect(PANEL).toMatch(/dailyUpdate\.openItem\(areaId, item\.id\)/)
    expect(PANEL).toContain('movedHeader(areaSince(snap, id), Date.now())')
    expect(PANEL).toContain('{NOTHING_MOVED}')
  })
})

describe('the panel', () => {
  it('runs a refresh with the open trigger when it opens', () => {
    expect(PANEL).toMatch(
      /useEffect\(\(\) => \{\s*void act\(\(\) => window\.bifrost\.dailyUpdate\.refresh\('open'\)\)/,
    )
  })

  it('shows the set-up text and Open settings when no area is on', () => {
    expect(PANEL).toContain("body === 'empty'")
    expect(PANEL).toContain('{SET_UP}')
    expect(PANEL).toMatch(/settingsNav\.open\('daily-update'\)[\s\S]{0,200}Open settings/)
  })

  it('shows the status line with Refresh, Skip today and Undo', () => {
    expect(PANEL).toContain('statusText(snap, Date.now())')
    expect(PANEL).toContain('dueText(snap)')
    expect(PANEL).toContain('refreshText(snap, Date.now())')
    expect(PANEL).toMatch(/label='Refresh'[\s\S]{0,200}dailyUpdate\.refresh\('button'\)/)
    expect(PANEL).toMatch(/label='Skip today'[\s\S]{0,200}dailyUpdate\.setSkipped\(true\)/)
    expect(PANEL).toMatch(/label='Undo'[\s\S]{0,200}dailyUpdate\.setSkipped\(false\)/)
  })

  it('shows the items that fit no area after a click on their count', () => {
    expect(PANEL).toContain('unplacedText(snap.state.unplaced.length)')
    expect(PANEL).toMatch(/<ItemList act=\{act\} areaId='' items=\{snap\.state\.unplaced\}/)
  })

  it('shows the failure of the last run above the tabs', () => {
    expect(PANEL).toContain('failureLine(snap, settings.dailyUpdate.source.server)')
    expect(PANEL.indexOf('data-daily-failure')).toBeGreaterThan(-1)
    expect(PANEL.indexOf('data-daily-failure')).toBeLessThan(PANEL.indexOf("role='tablist'"))
  })

  it('shows one tab for each area of the snapshot, with a marker', () => {
    expect(PANEL).toMatch(/snap\.areas\.map\(area => \(/)
    expect(PANEL).toContain('data-daily-tab={area.id}')
    expect(PANEL).toContain('tabMarker(snap, area.id)')
    expect(PANEL).toContain('setDailyTab(area.id)')
    expect(PANEL).toContain('shownTab(snap, chosen)')
  })
})

describe('the side bar button', () => {
  it('opens the panel with the MessageSquareText icon', () => {
    expect(SIDE_BAR).toMatch(/import \{[^}]*\bMessageSquareText\b[^}]*\} from 'lucide-react'/)
    expect(SIDE_BAR).toMatch(
      /icon=\{MessageSquareText\}\s+label='Daily update'\s+onClick=\{\(\) => open\('daily-update'/,
    )
  })

  it('shows the dot of the other buttons while the marker is on', () => {
    expect(SIDE_BAR).toContain('const dailyMarker = useDailyMarker()')
    expect(SIDE_BAR).toMatch(/dot=\{dailyMarker \? DAILY_ATTENTION : undefined\}/)
    expect(SIDE_BAR).toContain("const DAILY_ATTENTION = 'Daily update - Not sent yet'")
  })
})

describe('the panel list and the reminder route', () => {
  it('gives the panel its title and its content', () => {
    expect(PANELS).toMatch(/case 'daily-update':\s+return 'Daily update'/)
    expect(PANELS).toMatch(/case 'daily-update':\s+return <DailyUpdatePanel \/>/)
  })

  it('a click on a reminder opens the panel at its tab', () => {
    expect(ACTIONS).toMatch(
      /window\.bifrost\.dailyUpdate\.onOpen\(areaId => openDaily\(areaId, dispatch\)\)/,
    )
  })
})
