// Show the main window. A normal start shows the window as before, and a click on a notification
// or a second start also focuses it. In a test home, the window shows without focus and never
// takes it. A key that the user types in another app during a smoke test must not reach Bifrost:
// a Return or a Space on the setup dialog pressed Skip, and a smoke test failed.
//
// A headless test home (BIFROST_TEST_HEADLESS=1) shows no window at all (user decision,
// 2026-11-13). The smoke tests then show nothing on the screen and in the Dock, and the app never
// takes the focus from the real Bifrost of the user.
export interface ShownWindow {
  show(): void
  showInactive(): void
  focus(): void
}

export function showMainWindow(
  win: ShownWindow,
  o: { focus: boolean; headless?: boolean; testHome: boolean },
): void {
  if (o.testHome) {
    if (o.headless !== true) win.showInactive()
    return
  }
  win.show()
  if (o.focus) win.focus()
}

// The part of the Electron app that hideFromDock uses.
export interface DockApp {
  setActivationPolicy(policy: 'accessory'): void
}

// In a headless test home on macOS, the app has no Dock icon and no menu bar. macOS then does not
// make the app active when it starts. Call this function before the app is ready.
export function hideFromDock(
  app: DockApp,
  o: { headless: boolean; platform: NodeJS.Platform },
): void {
  if (o.headless && o.platform === 'darwin') app.setActivationPolicy('accessory')
}

// A headless test window never shows and never gets the focus. The main process then uses it as
// a shown window with the focus, as in a smoke test with a shown window. So the sessions poll at
// the normal interval, and no alert notification starts.
export function seenVisible(visible: boolean, headless: boolean): boolean {
  return headless || visible
}

export function seenFocused(focused: boolean, headless: boolean): boolean {
  return headless || focused
}
