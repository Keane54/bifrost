// The icon of an app bundle as a data URL (D7, M4 Task 16).
// The path is the .app bundle, not a file inside it. The first try is a thumbnail of the
// bundle (32 px). In the app check, getFileIcon gave the same generic square for Warp and
// Terminal (Task 10 bug 5). That image is not empty, so a fallback after it never runs.
// So the thumbnail goes first. If it fails or is empty, the second try is the file icon of
// the system at the normal size.

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
    const image = await deps.thumbnail(path, APP_ICON_SIZE, APP_ICON_SIZE)
    if (!image.isEmpty()) return image.toDataURL()
  } catch {
    // The file icon is the second try.
  }
  try {
    const image = await deps.fileIcon(path, 'normal')
    return image.isEmpty() ? null : image.toDataURL()
  } catch {
    return null
  }
}
