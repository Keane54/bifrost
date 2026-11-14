// The view ID of the chat window of a session: "chat:" and the session ID (8-4-4-4-12 hex digits).
// The main process and the renderer use this one pattern.
export const CHAT_VIEW = /^chat:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// The panel ID of the Show Info panel of a session: "show-info:" and the session ID.
export const SHOW_INFO_PANEL =
  /^show-info:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// The panel ID of a panel of a module: "module:", the module id and the panel id of the manifest
// (plan Task 6). The two parts have the patterns of the manifest. The renderer drops an ID that
// does not match, also from a saved layout.
export const MODULE_PANEL = /^module:([a-z][a-z0-9-]{1,39}):([a-z][a-z0-9-]{0,29})$/

export function modulePanelId(moduleId: string, panelId: string): string {
  return `module:${moduleId}:${panelId}`
}
