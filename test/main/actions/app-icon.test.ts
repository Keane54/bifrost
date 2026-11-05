import { describe, expect, it, vi } from 'vitest'
import { APP_ICON_SIZE, appIcon, type IconImage } from '../../../src/main/actions/app-icon'

const image = (url: string | null): IconImage => ({
  isEmpty: () => url === null,
  toDataURL: () => url ?? '',
})

describe('appIcon', () => {
  it('asks getFileIcon with the normal size first', async () => {
    const fileIcon = vi.fn(async () => image('data:file'))
    const thumbnail = vi.fn(async () => image('data:thumb'))
    expect(await appIcon('/Applications/Warp.app', { fileIcon, thumbnail })).toBe('data:file')
    expect(fileIcon).toHaveBeenCalledWith('/Applications/Warp.app', 'normal')
    expect(thumbnail).not.toHaveBeenCalled()
  })

  it('falls back to the thumbnail when getFileIcon gives an empty image or fails', async () => {
    const thumbnail = vi.fn(async () => image('data:thumb'))
    const empty = await appIcon('/a.app', { fileIcon: async () => image(null), thumbnail })
    expect(empty).toBe('data:thumb')
    expect(thumbnail).toHaveBeenCalledWith('/a.app', APP_ICON_SIZE, APP_ICON_SIZE)
    const failed = await appIcon('/a.app', {
      fileIcon: async () => {
        throw new Error('no icon')
      },
      thumbnail,
    })
    expect(failed).toBe('data:thumb')
  })

  it('gives null when both methods give nothing', async () => {
    const fail = async (): Promise<IconImage> => {
      throw new Error('no')
    }
    expect(await appIcon('/a.app', { fileIcon: async () => image(null), thumbnail: fail })).toBe(
      null,
    )
  })
})
