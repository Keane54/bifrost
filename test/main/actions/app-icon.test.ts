import { describe, expect, it, vi } from 'vitest'
import { APP_ICON_SIZE, appIcon, type IconImage } from '../../../src/main/actions/app-icon'

const image = (url: string | null): IconImage => ({
  isEmpty: () => url === null,
  toDataURL: () => url ?? '',
})

describe('appIcon', () => {
  it('asks for the thumbnail of the bundle first', async () => {
    const fileIcon = vi.fn(async () => image('data:file'))
    const thumbnail = vi.fn(async () => image('data:thumb'))
    expect(await appIcon('/Applications/Warp.app', { fileIcon, thumbnail })).toBe('data:thumb')
    expect(thumbnail).toHaveBeenCalledWith('/Applications/Warp.app', APP_ICON_SIZE, APP_ICON_SIZE)
    expect(fileIcon).not.toHaveBeenCalled()
  })

  it('falls back to getFileIcon (normal size) when the thumbnail is empty or fails', async () => {
    const fileIcon = vi.fn(async () => image('data:file'))
    const empty = await appIcon('/a.app', { fileIcon, thumbnail: async () => image(null) })
    expect(empty).toBe('data:file')
    expect(fileIcon).toHaveBeenCalledWith('/a.app', 'normal')
    const failed = await appIcon('/a.app', {
      fileIcon,
      thumbnail: async () => {
        throw new Error('no thumbnail')
      },
    })
    expect(failed).toBe('data:file')
  })

  it('gives null when both methods give nothing', async () => {
    const fail = async (): Promise<IconImage> => {
      throw new Error('no')
    }
    expect(await appIcon('/a.app', { fileIcon: fail, thumbnail: async () => image(null) })).toBe(
      null,
    )
    expect(await appIcon('/a.app', { fileIcon: async () => image(null), thumbnail: fail })).toBe(
      null,
    )
  })
})
