// The icon of an app bundle as a data URL (D7, M4 Task 16).
// The path is the .app bundle, not a file inside it. The first try is the file icon of the
// system at the normal size (32 px). The small size (16 px) gave a generic square for Warp
// and Terminal in the app check (Task 10 bug 5). If that fails or gives an empty image, the
// second try is a thumbnail of the bundle.

// The side of the thumbnail in px.
export const APP_ICON_SIZE = 32

// The part of an Electron NativeImage that this file uses.
export interface IconImage {
  isEmpty(): boolean
  toDataURL(): string
}

export interface IconDeps {
  fileIcon(path: string, size: 'normal'): Promise<IconImage>
  thumbnail(path: string, width: number, height: number): Promise<IconImage>
}

export async function appIcon(path: string, deps: IconDeps): Promise<string | null> {
  try {
    const image = await deps.fileIcon(path, 'normal')
    if (!image.isEmpty()) return image.toDataURL()
  } catch {
    // The thumbnail is the second try.
  }
  try {
    const image = await deps.thumbnail(path, APP_ICON_SIZE, APP_ICON_SIZE)
    return image.isEmpty() ? null : image.toDataURL()
  } catch {
    return null
  }
}
