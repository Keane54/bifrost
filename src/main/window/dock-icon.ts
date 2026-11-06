// The Dock icon of a dev start (`pnpm dev`). A packaged app gets its icon from build/icon.icns. A
// dev start runs inside the Electron binary, so macOS shows the Electron icon. Bifrost then sets
// the Dock icon from resources/icon.png, which `pnpm icon` draws with the app icon.
// Return the icon path to set, or null to keep the icon as it is.
export function devDockIcon(
  platform: NodeJS.Platform,
  packaged: boolean,
  icon: string,
): string | null {
  return platform === 'darwin' && !packaged ? icon : null
}
