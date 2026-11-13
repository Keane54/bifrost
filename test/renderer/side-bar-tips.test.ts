// Each side bar button shows a short tooltip with its name (user decision, 2026-11-09). The tooltip is the
// Bifrost tooltip (Tip), not the slow native title tooltip of the browser.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const SRC = join(__dirname, '../../src/renderer/src')

function source(name: string): string {
  return readFileSync(join(SRC, name), 'utf8')
}

describe('side bar tooltips', () => {
  it('the side bar buttons use Tip at the right, with no native title', () => {
    const text = source('wm/SideBar.tsx')
    expect(text).not.toMatch(/\btitle=/)
    expect(text).toMatch(/<Tip label=\{props\.dot \?\? props\.label\} side='right'>/)
    expect(text).toMatch(/<Tip key=\{frame\.id\} label=\{title\} side='right'>/)
  })

  it('the Layouts button uses Tip at the right, with no native title', () => {
    const text = source('wm/LayoutMenu.tsx')
    expect(text).toMatch(/<Tip label='Layouts' side='right'>/)
    expect(text).not.toMatch(/title='Layouts'/)
  })

  it('a minimised frame shows an icon button, with the title in the tooltip', () => {
    const text = source('wm/SideBar.tsx')
    expect(text).not.toMatch(/\[writing-mode:vertical-rl\]/)
    expect(text).toMatch(/aria-label=\{`Restore \$\{title\}`\}/)
    expect(text).toMatch(/PANEL_ICONS/)
    expect(text).toMatch(/<SessionIcon /)
  })

  it('the minimised icon leaves out the native title and ignores the pointer', () => {
    const text = source('wm/SideBar.tsx')
    expect(text).toMatch(/<SessionIcon [^>]*noTitle=\{true\}/)
    expect(text).toMatch(/pointer-events-none/)
    expect(source('overview/SessionIcon.tsx')).toMatch(/noTitle/)
  })
})
