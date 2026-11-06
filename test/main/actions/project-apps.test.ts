import { describe, expect, it } from 'vitest'
import { findProjectApps, findTerminalApps } from '../../../src/main/actions/project-apps'

const have =
  (...paths: string[]) =>
  async (p: string) =>
    paths.includes(p)

describe('findProjectApps', () => {
  it('lists Finder, VS Code and Zed, then the first terminal app', async () => {
    const apps = await findProjectApps(
      '/home/u',
      have(
        '/System/Library/CoreServices/Finder.app',
        '/Applications/Visual Studio Code.app',
        '/Applications/Zed.app',
        '/Applications/Ghostty.app',
        '/Applications/iTerm.app',
      ),
    )
    expect(apps.map(a => a.id)).toEqual(['finder', 'vscode', 'zed', 'ghostty'])
  })

  it('finds an app in ~/Applications', async () => {
    const apps = await findProjectApps('/home/u', have('/home/u/Applications/Zed.app'))
    expect(apps.find(a => a.id === 'zed')?.path).toBe('/home/u/Applications/Zed.app')
  })

  it('falls back to Terminal', async () => {
    const apps = await findProjectApps(
      '/home/u',
      have(
        '/System/Library/CoreServices/Finder.app',
        '/System/Applications/Utilities/Terminal.app',
      ),
    )
    expect(apps.map(a => a.id)).toEqual(['finder', 'terminal'])
  })

  it('uses the chosen terminal app when it is installed', async () => {
    const exists = have(
      '/System/Library/CoreServices/Finder.app',
      '/Applications/Warp.app',
      '/System/Applications/Utilities/Terminal.app',
    )
    const chosen = await findProjectApps('/home/u', exists, 'terminal')
    expect(chosen.map(a => a.id)).toEqual(['finder', 'terminal'])
    const missing = await findProjectApps('/home/u', exists, 'ghostty')
    expect(missing.map(a => a.id)).toEqual(['finder', 'warp'])
  })
})

describe('findTerminalApps', () => {
  it('lists each installed terminal app in the spec order', async () => {
    const apps = await findTerminalApps(
      '/home/u',
      have(
        '/System/Applications/Utilities/Terminal.app',
        '/Applications/Warp.app',
        '/Applications/Zed.app',
      ),
    )
    expect(apps.map(a => a.id)).toEqual(['warp', 'terminal'])
  })

  it('follows the order that it gets, not the order of the candidates', async () => {
    // The candidates list Warp before Terminal. This order puts Terminal first.
    const apps = await findTerminalApps(
      '/home/u',
      have('/System/Applications/Utilities/Terminal.app', '/Applications/Warp.app'),
      ['terminal', 'iterm2', 'ghostty', 'warp'],
    )
    expect(apps.map(a => a.id)).toEqual(['terminal', 'warp'])
  })
})
