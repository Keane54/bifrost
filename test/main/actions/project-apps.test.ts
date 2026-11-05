import { describe, expect, it } from 'vitest'
import { findProjectApps } from '../../../src/main/actions/project-apps'

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
})
